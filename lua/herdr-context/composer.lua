local M = {}

local bundle = require("herdr-context.bundle")
local config = require("herdr-context.config")
local context = require("herdr-context.context")
local picker = require("herdr-context.picker")
local providers = require("herdr-context.providers")
local safety = require("herdr-context.safety")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")
local transport = require("herdr-context.transport")

local PRIMARY_IDS = {
  selection = true,
  symbol = true,
  hunk = true,
}

local LIST_IDS = {
  quickfix = true,
  location_list = true,
  trouble = true,
}

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

local function has_items(entry)
  return entry and entry.section and entry.section.items and #entry.section.items > 0
end

local function attachable(session, id)
  local entry = entry_by_id(session, id)
  if not entry or entry.status ~= "available" or not entry.section then
    return false
  end
  if id == "diagnostics" or entry.section.format == "diagnostics" then
    return config.get().composer.attach_empty_diagnostics or has_items(entry)
  end
  if LIST_IDS[id] or entry.section.format == "list" then
    return has_items(entry)
  end
  return true
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
      selected[id] = attachable(session, id)
    end
    session.selected = selected
    return
  end
  local defaults = config.get().composer.defaults
  local selected = {}
  if session.request.selection then
    selected.selection = defaults.selection and attachable(session, "selection")
    selected.diagnostics = defaults.diagnostics and attachable(session, "diagnostics")
  else
    selected.symbol = defaults.symbol and attachable(session, "symbol")
    selected.hunk = defaults.hunk and attachable(session, "hunk")
    if not selected.symbol and not selected.hunk then
      selected.selection = defaults.selection and attachable(session, "selection")
    end
    selected.diagnostics = defaults.diagnostics and attachable(session, "diagnostics")
  end
  for _, id in ipairs({ "quickfix", "location_list", "trouble" }) do
    selected[id] = defaults[id] and attachable(session, id)
  end
  session.selected = selected
end

local function should_embed(session, entry)
  local section = entry.safe_section or entry.section
  if not section then
    return false
  end
  if session.include == "content" then
    return section.format == "code" or section.format == "diff" or section.format == "reference"
  end
  if session.embed[entry.id] then
    return true
  end
  if section.format ~= "code" and section.format ~= "diff" and section.format ~= "reference" then
    return false
  end
  if not bundle.has_file_reference(section) then
    return true
  end
  return section.modified and config.get().composer.embed_unsaved == "always"
end

local function prepared_section(session, entry)
  local section = vim.deepcopy(entry.safe_section)
  if should_embed(session, entry) then
    section.embed = true
  end
  return section
end

local function rebuild(session)
  local cfg = config.get()
  session.include = session.include or cfg.composer.include
  local sections = {}
  for _, entry in ipairs(session.entries) do
    entry.safe_section, entry.excluded = nil, nil
    entry.embed = false
    if entry.section then
      entry.safe_section, entry.excluded = safety.sanitize(entry.section, session.request, cfg.safety)
      if entry.safe_section then
        local prepared = prepared_section(session, entry)
        entry.embed = prepared.embed == true
        local single = bundle.build({ prepared }, cfg.max_payload_bytes, { include = session.include })
        if single then
          entry.bytes = single.sections[1] and single.sections[1].bytes or 0
          entry.oversized = single.oversized
        else
          entry.bytes = 0
          entry.oversized = false
        end
      else
        entry.bytes = 0
        entry.oversized = false
      end
    end
    if session.selected[entry.id] and entry.status == "available" and entry.safe_section then
      sections[#sections + 1] = prepared_section(session, entry)
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
  local built, err = bundle.build(sections, cfg.max_payload_bytes, { include = session.include })
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

local function unsaved_unembedded(session)
  if session.include == "content" or config.get().composer.embed_unsaved ~= "ask" then
    return false
  end
  for _, entry in ipairs(session.entries) do
    local section = entry.safe_section
    if
      session.selected[entry.id]
      and section
      and section.modified
      and not entry.embed
      and bundle.has_file_reference(section)
    then
      return true
    end
  end
  return false
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
    local pending_stage = session.pending_stage
    session.pending_stage = nil
    if pending_stage then
      vim.schedule(function()
        if not session.closed then
          session:stage(pending_stage)
        end
      end)
    end
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

local function send_bundle(session, target, stage_opts)
  session.target = target
  if session.track then
    notify(("Submitting context to %s (%s) and tracking its state…"):format(target.agent or "agent", target.pane_id))
  end
  transport.stage(config.get(), target, session.bundle.payload, function(ok, err, result)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
    local suffix = result.mode == "context_file" and " via a temporary context file" or ""
    require("herdr-context.history").record({
      kind = "composer",
      target = target,
      payload = session.bundle.payload,
      bytes = session.bundle.bytes,
      providers = selected_ids(session),
      instruction = session.instruction,
      preset = session.preset,
      mode = result.mode,
      submitted = result.submitted,
      tracked = result.tracked,
      status = result.status,
    })
    local preview_result = result.tracked and (result.status == "blocked" or session.preview_result)
    if result.tracking_error then
      notify(result.tracking_message, vim.log.levels.WARN)
    elseif result.tracked and result.status == "blocked" then
      notify(
        ("Herdr %s (%s) is blocked and needs input"):format(target.agent or "agent", target.pane_id),
        vim.log.levels.WARN
      )
    elseif result.tracked then
      notify(
        ("Herdr %s (%s) reached %s"):format(target.agent or "agent", target.pane_id, result.status or "a settled state")
      )
    else
      local action = result.submitted and "Sent" or "Staged"
      notify(("%s context for %s (%s)%s"):format(action, target.agent or "agent", target.pane_id, suffix))
    end
    session:close()
    if preview_result then
      vim.schedule(function()
        require("herdr-context.ui.preview").open(result.agent or target)
      end)
    end
  end, {
    submit = stage_opts.submit,
    wait = session.track,
    timeout_ms = session.tracking_timeout_ms,
  })
end

local function create_session(request, opts)
  opts = opts or {}
  local cfg = config.get()
  local session = {
    request = request,
    entries = {},
    selected = {},
    embed = {},
    include = cfg.composer.include,
    lists_expanded = false,
    unsaved_confirmed = false,
    candidates = {},
    target = targets.selected(),
    target_label = opts.target_label,
    preview = cfg.composer.preview,
    collecting = false,
    stale = false,
    closed = false,
    instruction = opts.instruction or "",
    preset = opts.preset,
    track = opts.wait == true,
    tracking_timeout_ms = opts.timeout_ms,
    preview_result = opts.preview_result == true,
    stage_handler = opts.stage_handler,
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

  function session:visible_entry(entry)
    local options = config.get().composer
    if self.selected[entry.id] or PRIMARY_IDS[entry.id] then
      return true
    end
    if not options.hide_empty then
      return true
    end
    if entry.id == "diagnostics" then
      return has_items(entry) or options.attach_empty_diagnostics
    end
    if LIST_IDS[entry.id] then
      return self.lists_expanded or has_items(entry)
    end
    return entry.status == "available"
  end

  function session:hidden_list_count()
    local count = 0
    for _, entry in ipairs(self.entries) do
      if LIST_IDS[entry.id] and not self:visible_entry(entry) then
        count = count + 1
      end
    end
    return count
  end

  function session:toggle(id)
    if not available(self, id) then
      return
    end
    self.selected[id] = not self.selected[id]
    self.unsaved_confirmed = false
    rescope_diagnostics(self)
    rebuild(self)
    update(self)
  end

  function session:toggle_embed(id)
    if not available(self, id) then
      return
    end
    self.embed[id] = not self.embed[id]
    self.unsaved_confirmed = false
    rebuild(self)
    update(self)
  end

  function session:toggle_lists()
    self.lists_expanded = not self.lists_expanded
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
      selected[id] = attachable(self, id)
    end
    self.selected = selected
    self.unsaved_confirmed = false
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
    self.unsaved_confirmed = false
    collect(self)
  end

  function session:refresh_candidates()
    if self.stage_handler then
      self.candidates = {}
      return
    end
    local options = config.get()
    local snapshot = state.get()
    self.candidates = targets.candidates(snapshot, {
      scope = options.target_scope,
      cwd = self.request.cwd,
      git_root = self.request.git_root,
    })
    if self.target then
      local live = targets.find(self.candidates, self.target.pane_id)
      if live then
        self.target = live
      elseif #self.candidates > 0 then
        self.target = nil
      end
    end
    if not self.target then
      local remembered = targets.selected()
      local live = remembered and targets.find(self.candidates, remembered.pane_id)
      if live then
        self.target = live
      elseif #self.candidates == 1 then
        targets.remember(options, self.candidates[1])
        self.target = self.candidates[1]
      end
    end
  end

  function session:set_target(agent)
    if not agent or not agent.pane_id then
      return
    end
    local ok, err = targets.remember(config.get(), agent)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
    self.target = agent
    update(self)
  end

  function session:change_target()
    if self.stage_handler then
      notify("Delegation creates a new target; no existing target is needed")
      return
    end
    local options = config.get()
    if options.composer.agent_picker == "inline" then
      self:refresh_candidates()
      update(self)
      if self.focus_agents then
        self.focus_agents()
      end
      return
    end
    targets.resolve(options, picker, { force = true }, function(target, err)
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

  function session:stage(stage_opts)
    stage_opts = stage_opts or {}
    if self.collecting then
      if stage_opts.wait then
        self.pending_stage = vim.deepcopy(stage_opts)
        notify("Context is still collecting; it will send when ready")
      else
        notify("Context providers are still collecting", vim.log.levels.WARN)
      end
      return
    end
    if self:is_stale() then
      update(self)
      notify("The context preview is stale; press r to refresh it", vim.log.levels.WARN)
      return
    end
    if not self.bundle or #self.bundle.sections == 0 then
      notify("Write a message or attach a reference", vim.log.levels.WARN)
      return
    end
    if self.bundle.oversized then
      notify(self.bundle.error, vim.log.levels.ERROR)
      return
    end
    if unsaved_unembedded(self) and not self.unsaved_confirmed then
      self.unsaved_confirmed = true
      update(self)
      notify("Unsaved buffer; press e to embed the snippet, or s again to send the disk reference", vim.log.levels.WARN)
      return
    end
    local options = config.get()
    if #self.safety_warnings > 0 and options.safety.confirm_warnings and not self.safety_confirmed then
      self.safety_confirmed = true
      update(self)
      notify(
        "Potential sensitive content detected; review the warnings and press s again to stage",
        vim.log.levels.WARN
      )
      return
    end

    if self.stage_handler then
      self.stage_handler(self, stage_opts)
      return
    end

    if options.composer.agent_picker == "inline" then
      self:refresh_candidates()
      if self.target then
        send_bundle(self, self.target, stage_opts)
        return
      end
      if #self.candidates == 1 then
        self:set_target(self.candidates[1])
        send_bundle(self, self.candidates[1], stage_opts)
        return
      end
      if #self.candidates == 0 then
        notify(("No live Herdr agents found in target scope %q"):format(options.target_scope), vim.log.levels.ERROR)
        return
      end
      notify("Select an agent in the composer", vim.log.levels.WARN)
      update(self)
      if self.focus_agents then
        self.focus_agents()
      end
      return
    end

    targets.resolve(options, picker, {}, function(target, target_err)
      if not target then
        if target_err ~= "Target selection cancelled" then
          notify(target_err, vim.log.levels.ERROR)
        end
        return
      end
      send_bundle(self, target, stage_opts)
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

  function session:selected_ids()
    return selected_ids(self)
  end

  session:refresh_candidates()
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
  if opts.edit_instruction then
    vim.schedule(function()
      if not session.closed then
        require("herdr-context.ui.composer").edit_message(session)
      end
    end)
  end
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
    local built, build_err = bundle.build({ safe_section }, cfg.max_payload_bytes, { include = cfg.composer.include })
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
M._attachable = attachable

return M
