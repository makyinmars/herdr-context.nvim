local M = {}

local bundle = require("herdr-context.bundle")
local config = require("herdr-context.config")
local context = require("herdr-context.context")
local picker = require("herdr-context.picker")
local providers = require("herdr-context.providers")
local safety = require("herdr-context.safety")
local targets = require("herdr-context.targets")
local transport = require("herdr-context.transport")

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "herdr-context.nvim" })
end

local function current_cursor(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_get_cursor(winid)
  end
  return vim.api.nvim_win_get_cursor(0)
end

function M.capture_request(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local winid = opts.winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("herdr-context: the source buffer is no longer valid")
  end

  local cursor = opts.cursor or current_cursor(winid)
  if opts.line then
    cursor = { opts.line, cursor[2] }
  end
  local selection = opts.selection
  if not selection and opts.line1 and opts.line2 then
    selection = { mode = "line", start = { opts.line1, 1 }, finish = { opts.line2, 1 } }
  elseif not selection and bufnr == vim.api.nvim_get_current_buf() then
    selection = context.visual_selection(bufnr)
  end

  local cwd = opts.cwd or (vim.uv or vim.loop).cwd() or vim.fn.getcwd()
  local captured = context.capture({
    bufnr = bufnr,
    selection = selection,
    line = cursor[1],
    cwd = cwd,
  })
  return {
    bufnr = bufnr,
    winid = winid,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    cursor = { cursor[1], cursor[2] },
    mode = selection and selection.mode or "n",
    selection = selection and vim.deepcopy(selection) or nil,
    capture = captured,
    path = captured.path,
    relative_path = captured.relative_path,
    git_root = captured.path and context.find_git_root(captured.path) or context.find_git_root(cwd),
    cwd = cwd,
    filetype = captured.filetype,
    modified = captured.modified,
  }
end

local function entry_by_id(session, id)
  for _, entry in ipairs(session.entries) do
    if entry.id == id then
      return entry
    end
  end
end

local function available(session, id)
  local entry = entry_by_id(session, id)
  return entry and entry.status == "available" and entry.section ~= nil
end

local function update(session)
  if session.on_update and not session.closed then
    session.on_update(session)
  end
end

local function selected_ids(session)
  local ids = {}
  for id, selected in pairs(session.selected) do
    if selected then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

local function rescope_diagnostics(session)
  local diagnostic = entry_by_id(session, "diagnostics")
  if not diagnostic or diagnostic.status ~= "available" then
    return
  end
  local range
  if session.request.selection then
    range = session.request.capture
  else
    for _, id in ipairs({ "symbol", "hunk", "selection" }) do
      local entry = entry_by_id(session, id)
      if session.selected[id] and entry and entry.section and entry.section.range then
        range = entry.section.range
        break
      end
    end
  end
  range = range or { start_line = session.request.cursor[1], end_line = session.request.cursor[1] }
  diagnostic.section = require("herdr-context.providers.diagnostics").section_for_range(session.request, range)
end

local function apply_defaults(session)
  local preset = session.preset and config.get().composer.presets[session.preset]
  if preset then
    local selected = {}
    for _, id in ipairs(preset) do
      selected[id] = available(session, id)
    end
    session.selected = selected
    return
  end
  local defaults = config.get().composer.defaults
  local selected = {}
  if session.request.selection then
    selected.selection = defaults.selection and available(session, "selection")
    selected.diagnostics = defaults.diagnostics and available(session, "diagnostics")
  else
    selected.symbol = defaults.symbol and available(session, "symbol")
    selected.hunk = defaults.hunk and available(session, "hunk")
    if not selected.symbol and not selected.hunk then
      selected.selection = defaults.selection and available(session, "selection")
    end
    selected.diagnostics = defaults.diagnostics and available(session, "diagnostics")
  end
  for _, id in ipairs({ "quickfix", "location_list", "trouble" }) do
    selected[id] = defaults[id] and available(session, id)
  end
  session.selected = selected
end

local function rebuild(session)
  local cfg = config.get()
  local sections = {}
  for _, entry in ipairs(session.entries) do
    entry.safe_section, entry.excluded = nil, nil
    if entry.section then
      entry.safe_section, entry.excluded = safety.sanitize(entry.section, session.request, cfg.safety)
      local single = entry.safe_section and bundle.build({ entry.safe_section }, cfg.max_payload_bytes)
      if single then
        entry.bytes = single.sections[1] and single.sections[1].bytes or 0
        entry.oversized = single.oversized
      else
        entry.bytes = 0
        entry.oversized = false
      end
    end
    if session.selected[entry.id] and entry.status == "available" and entry.safe_section then
      sections[#sections + 1] = entry.safe_section
    end
  end
  if session.instruction and session.instruction ~= "" then
    sections[#sections + 1] = {
      id = "instructions",
      title = "Instructions",
      priority = 0,
      format = "text",
      content = session.instruction,
      fingerprint = "instructions:" .. session.instruction,
    }
  end
  local built, err = bundle.build(sections, cfg.max_payload_bytes)
  session.bundle = built
  session.bundle_error = err
  session.safety_warnings = built and safety.scan(built.sections, cfg.safety) or {}
  local warning_signature = #session.safety_warnings > 0
      and (table.concat(session.safety_warnings, "\n") .. "\0" .. (built and built.payload or ""))
    or ""
  if warning_signature ~= session.warning_signature then
    session.warning_signature = warning_signature
    session.safety_confirmed = false
  end
end

local function collect(session)
  if session.cancel_collection then
    session.cancel_collection()
  end
  session.collecting = true
  session.entries = {}
  session.selected = {}
  session.bundle = nil
  local cfg = config.get()
  session.cancel_collection = providers.collect(session.request, {
    timeout_ms = cfg.composer.provider_timeout_ms,
    on_update = function(_, entries)
      session.entries = entries
      rebuild(session)
      update(session)
    end,
  }, function(entries)
    session.entries = entries
    session.collecting = false
    apply_defaults(session)
    rescope_diagnostics(session)
    rebuild(session)
    update(session)
  end)
end

local function fresh_request(session)
  local request = session.request
  local cursor = current_cursor(request.winid)
  return M.capture_request({
    bufnr = request.bufnr,
    winid = request.winid,
    cursor = cursor,
    selection = request.selection,
    cwd = request.cwd,
  })
end

local function create_session(request, opts)
  opts = opts or {}
  local session = {
    request = request,
    entries = {},
    selected = {},
    target = targets.selected(),
    preview = config.get().composer.preview,
    collecting = false,
    stale = false,
    closed = false,
    instruction = opts.instruction or "",
    preset = opts.preset,
    safety_warnings = {},
    safety_confirmed = false,
  }

  function session:is_stale()
    if self.stale then
      return true
    end
    if not vim.api.nvim_buf_is_valid(self.request.bufnr) then
      self.stale = true
    elseif vim.api.nvim_buf_get_changedtick(self.request.bufnr) ~= self.request.changedtick then
      self.stale = true
    end
    return self.stale
  end

  function session:toggle(id)
    if not available(self, id) then
      return
    end
    self.selected[id] = not self.selected[id]
    rescope_diagnostics(self)
    rebuild(self)
    update(self)
  end

  function session:toggle_preview()
    self.preview = not self.preview
    update(self)
  end

  function session:set_instruction(value)
    self.instruction = tostring(value or ""):match("^%s*(.-)%s*$")
    rebuild(self)
    update(self)
  end

  function session:apply_preset(name)
    local preset = config.get().composer.presets[name]
    if not preset then
      notify("Unknown composer preset: " .. tostring(name), vim.log.levels.ERROR)
      return false
    end
    self.preset = name
    local selected = {}
    for _, id in ipairs(preset) do
      selected[id] = available(self, id)
    end
    self.selected = selected
    rescope_diagnostics(self)
    rebuild(self)
    update(self)
    return true
  end

  function session:refresh()
    local ok, request_or_err = pcall(fresh_request, self)
    if not ok then
      notify(request_or_err, vim.log.levels.ERROR)
      return
    end
    self.request = request_or_err
    self.stale = false
    collect(self)
  end

  function session:change_target()
    targets.resolve(config.get(), picker, { force = true }, function(target, err)
      if not target then
        if err ~= "Target selection cancelled" then
          notify(err, vim.log.levels.ERROR)
        end
        return
      end
      self.target = target
      update(self)
    end)
  end

  function session:stage()
    if self.collecting then
      notify("Context providers are still collecting", vim.log.levels.WARN)
      return
    end
    if self:is_stale() then
      update(self)
      notify("The context preview is stale; press r to refresh it", vim.log.levels.WARN)
      return
    end
    if not self.bundle or #self.bundle.sections == 0 then
      notify("Select at least one available context provider", vim.log.levels.WARN)
      return
    end
    if self.bundle.oversized then
      notify(self.bundle.error, vim.log.levels.ERROR)
      return
    end
    if #self.safety_warnings > 0 and config.get().safety.confirm_warnings and not self.safety_confirmed then
      self.safety_confirmed = true
      update(self)
      notify(
        "Potential sensitive content detected; review the warnings and press s again to stage",
        vim.log.levels.WARN
      )
      return
    end

    targets.resolve(config.get(), picker, {}, function(target, target_err)
      if not target then
        if target_err ~= "Target selection cancelled" then
          notify(target_err, vim.log.levels.ERROR)
        end
        return
      end
      self.target = target
      transport.stage(config.get(), target, self.bundle.payload, function(ok, err, result)
        if not ok then
          notify(err, vim.log.levels.ERROR)
          return
        end
        local suffix = result.mode == "context_file" and " via a temporary context file" or ""
        require("herdr-context.history").record({
          kind = "composer",
          target = target,
          payload = self.bundle.payload,
          bytes = self.bundle.bytes,
          providers = selected_ids(self),
          instruction = self.instruction,
          preset = self.preset,
          mode = result.mode,
        })
        notify(("Staged context for %s (%s)%s"):format(target.agent or "agent", target.pane_id, suffix))
        self:close()
      end)
    end)
  end

  function session:close()
    if self.closed then
      return
    end
    self.closed = true
    if self.cancel_collection then
      self.cancel_collection()
      self.cancel_collection = nil
    end
    if self.ui_close then
      self.ui_close()
    end
  end

  return session
end

function M.open(opts)
  opts = opts or {}
  if opts.preset and not config.get().composer.presets[opts.preset] then
    notify("Unknown composer preset: " .. tostring(opts.preset), vim.log.levels.ERROR)
    return
  end
  local ok, request = pcall(M.capture_request, opts)
  if not ok then
    notify(request, vim.log.levels.ERROR)
    return
  end
  local session = create_session(request, opts)
  require("herdr-context.ui.composer").open(session)
  collect(session)
  return session
end

function M.stage_provider(id, opts)
  local ok, request = pcall(M.capture_request, opts)
  if not ok then
    notify(request, vim.log.levels.ERROR)
    return
  end
  local cfg = config.get()
  return providers.collect(request, {
    ids = { id },
    timeout_ms = cfg.composer.provider_timeout_ms,
  }, function(entries)
    local entry = entries[1]
    if not entry or entry.status ~= "available" or not entry.section then
      notify((entry and entry.error) or ("Provider %s is unavailable"):format(id), vim.log.levels.ERROR)
      return
    end
    if
      not vim.api.nvim_buf_is_valid(request.bufnr)
      or vim.api.nvim_buf_get_changedtick(request.bufnr) ~= request.changedtick
    then
      notify("The source buffer changed while context was collected; try again", vim.log.levels.WARN)
      return
    end
    local safe_section, excluded = safety.sanitize(entry.section, request, cfg.safety)
    if not safe_section then
      notify(excluded, vim.log.levels.ERROR)
      return
    end
    local built, build_err = bundle.build({ safe_section }, cfg.max_payload_bytes)
    if not built then
      notify(build_err, vim.log.levels.ERROR)
      return
    end
    if built.oversized then
      notify(built.error, vim.log.levels.ERROR)
      return
    end
    safety.confirm(safety.scan(built.sections, cfg.safety), function(confirmed)
      if not confirmed then
        return
      end
      targets.resolve(cfg, picker, {}, function(target, target_err)
        if not target then
          if target_err ~= "Target selection cancelled" then
            notify(target_err, vim.log.levels.ERROR)
          end
          return
        end
        transport.stage(cfg, target, built.payload, function(staged, stage_err, result)
          if not staged then
            notify(stage_err, vim.log.levels.ERROR)
            return
          end
          local suffix = result.mode == "context_file" and " via a temporary context file" or ""
          require("herdr-context.history").record({
            kind = id,
            target = target,
            payload = built.payload,
            bytes = built.bytes,
            providers = { id },
            mode = result.mode,
          })
          notify(
            ("Staged %s for %s (%s)%s"):format(entry.name:lower(), target.agent or "agent", target.pane_id, suffix)
          )
        end)
      end)
    end)
  end)
end

M._create_session = create_session
M._collect = collect
M._rebuild = rebuild
M._apply_defaults = apply_defaults
M._rescope_diagnostics = rescope_diagnostics

return M
