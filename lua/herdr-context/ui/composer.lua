local M = {}

local config = require("herdr-context.config")

local namespace = vim.api.nvim_create_namespace("herdr-context-composer")
local active

local status_highlights = {
  ["x"] = "DiagnosticOk",
  [" "] = "Comment",
  ["…"] = "DiagnosticInfo",
  ["-"] = "Comment",
  ["!"] = "DiagnosticError",
  [">"] = "DiagnosticWarn",
}

local function format_bytes(bytes)
  bytes = bytes or 0
  if bytes < 1024 then
    return ("%d B"):format(bytes)
  end
  return ("%.1f KiB"):format(bytes / 1024)
end

local function dimension(value, total, minimum)
  if value <= 1 then
    value = math.floor(total * value)
  end
  return math.min(math.max(minimum, math.floor(value)), math.max(1, total - 2))
end

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid(ui)
  return ui
    and valid_buffer(ui.list_bufnr)
    and valid_window(ui.list_winid)
    and valid_buffer(ui.preview_bufnr)
    and valid_window(ui.preview_winid)
end

local function target_label(target)
  if not target then
    return "no target"
  end
  return ("%s %s"):format(target.agent or "agent", target.pane_id or "?")
end

local function entry_status(session, entry)
  if entry.status == "collecting" then
    return "…"
  elseif entry.status == "unavailable" then
    return "-"
  elseif entry.status == "failed" or entry.excluded then
    return "!"
  elseif entry.oversized then
    return ">"
  elseif session.selected[entry.id] then
    return "x"
  end
  return " "
end

local function setup_highlights()
  for name, link in pairs({
    HerdrContextComposerHeader = "Title",
    HerdrContextComposerStale = "DiagnosticWarn",
    HerdrContextComposerError = "DiagnosticError",
    HerdrContextComposerSize = "Comment",
    HerdrContextComposerFooter = "Comment",
    HerdrContextComposerInstruction = "Special",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

local function set_lines(bufnr, lines, marks)
  if not valid_buffer(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for _, mark in ipairs(marks or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, mark.line, mark.start_col, {
      end_col = mark.end_col,
      hl_group = mark.hl,
    })
  end
  vim.bo[bufnr].modifiable = false
end

local function render_list(ui)
  local session = ui.session
  local cfg = config.get()
  session:is_stale()
  local built = session.bundle
  local bytes = built and built.bytes or 0
  local lines = {
    "Herdr Context",
    ("Target: %s"):format(target_label(session.target)),
    ("Budget: %s / %s"):format(format_bytes(bytes), format_bytes(cfg.max_payload_bytes)),
    ("Preset: %s"):format(session.preset or "custom"),
    ("Instruction: %s"):format(session.instruction ~= "" and session.instruction:gsub("\n", " ") or "none (press i)"),
  }
  local marks = {
    { line = 0, start_col = 0, end_col = #lines[1], hl = "HerdrContextComposerHeader" },
    { line = 4, start_col = 0, end_col = #lines[5], hl = "HerdrContextComposerInstruction" },
  }
  ui.line_to_id = {}

  if session.stale then
    lines[#lines + 1] = "STALE — source changed; press r"
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 0,
      end_col = #lines[#lines],
      hl = "HerdrContextComposerStale",
    }
  elseif session.collecting then
    lines[#lines + 1] = "Collecting providers…"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Providers"

  for _, entry in ipairs(session.entries) do
    local status = entry_status(session, entry)
    local summary = entry.excluded or (entry.section and entry.section.summary) or entry.error or ""
    local size = entry.bytes and entry.bytes > 0 and format_bytes(entry.bytes) or ""
    local line = ("[%s] %s"):format(status, entry.name)
    if size ~= "" then
      line = line .. " · " .. size
    end
    lines[#lines + 1] = line
    ui.line_to_id[#lines] = entry.id
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 0,
      end_col = 3,
      hl = status_highlights[status],
    }
    if summary ~= "" then
      lines[#lines + 1] = "    " .. summary
      marks[#marks + 1] = {
        line = #lines - 1,
        start_col = 4,
        end_col = #lines[#lines],
        hl = entry.excluded and "HerdrContextComposerError" or "Comment",
      }
    end
  end

  if built and built.oversized then
    lines[#lines + 1] = ""
    lines[#lines + 1] = built.error
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 0,
      end_col = #lines[#lines],
      hl = "HerdrContextComposerError",
    }
  elseif session.bundle_error then
    lines[#lines + 1] = session.bundle_error
  end

  if #session.safety_warnings > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = session.safety_confirmed and "Sensitive-content warning confirmed"
      or "Sensitive-content warning"
    for _, warning in ipairs(session.safety_warnings) do
      lines[#lines + 1] = "! " .. warning
      marks[#marks + 1] = {
        line = #lines - 1,
        start_col = 0,
        end_col = #lines[#lines],
        hl = "HerdrContextComposerError",
      }
    end
  end

  lines[#lines + 1] = ""
  local action = cfg.submit and "stage + submit" or "stage"
  lines[#lines + 1] = ("Space toggle · s %s · i instruct"):format(action)
  lines[#lines + 1] = "P preset · t target · r refresh"
  lines[#lines + 1] = "p preview · h history · ? help · q close"
  for index = #lines - 2, #lines do
    marks[#marks + 1] = { line = index - 1, start_col = 0, end_col = #lines[index], hl = "HerdrContextComposerFooter" }
  end

  local cursor = vim.api.nvim_win_get_cursor(ui.list_winid)
  local cursor_id = ui.line_to_id[cursor[1]]
  set_lines(ui.list_bufnr, lines, marks)
  if cursor_id then
    for line, id in pairs(ui.line_to_id) do
      if id == cursor_id then
        vim.api.nvim_win_set_cursor(ui.list_winid, { line, 0 })
        return
      end
    end
  end
  vim.api.nvim_win_set_cursor(ui.list_winid, { math.min(cursor[1], #lines), 0 })
end

local function render_preview(ui)
  local session = ui.session
  local lines
  if session.preview then
    lines = vim.split(session.bundle and session.bundle.payload or "Context bundle", "\n", { plain = true })
  else
    lines = { "Payload preview hidden.", "", "Press p to show it." }
  end
  set_lines(ui.preview_bufnr, lines)
end

local function render(ui)
  if not valid(ui) then
    return
  end
  render_list(ui)
  render_preview(ui)
end

local function cleanup(ui)
  if ui.cleaned then
    return
  end
  ui.cleaned = true
  if active == ui then
    active = nil
  end
  if ui.stale_autocmd then
    pcall(vim.api.nvim_del_autocmd, ui.stale_autocmd)
    ui.stale_autocmd = nil
  end
  ui.session.ui_close = nil
  require("herdr-context.ui.instruction").close(ui.session)
  for _, winid in ipairs({ ui.preview_winid, ui.list_winid }) do
    if valid_window(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
  if not ui.session.closed then
    ui.session.closed = true
    if ui.session.cancel_collection then
      ui.session.cancel_collection()
      ui.session.cancel_collection = nil
    end
  end
end

local function close_ui(ui)
  cleanup(ui)
end

local function edit_instruction(ui)
  require("herdr-context.ui.instruction").open(ui.session)
end

local function choose_preset(ui)
  local names = vim.tbl_keys(config.get().composer.presets)
  table.sort(names)
  vim.ui.select(names, { prompt = "Herdr context preset:" }, function(name)
    if name and not ui.session.closed then
      ui.session:apply_preset(name)
    end
  end)
end

local function show_help()
  vim.notify(
    table.concat({
      "Space  toggle provider",
      "i      edit instruction",
      "P      choose preset",
      "t      choose target",
      "r      recapture source",
      "s      stage bundle",
      "p      toggle payload preview",
      "h      open send history",
      "Tab    switch composer panes",
      "q/Esc  cancel",
    }, "\n"),
    vim.log.levels.INFO,
    { title = "Herdr Context keys" }
  )
end

local function configure_buffer(bufnr, filetype)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype
  vim.bo[bufnr].modifiable = false
end

local function configure_window(winid, cursorline)
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = cursorline
end

function M.open(session)
  if active then
    active.session:close()
  end
  setup_highlights()
  local options = config.get().composer
  local total_width = dimension(options.width, vim.o.columns, 70)
  local height = dimension(options.height, vim.o.lines - vim.o.cmdheight, 12)
  local gap = 2
  local list_width = math.max(28, math.floor((total_width - gap) * options.checklist_width))
  local preview_width = total_width - gap - list_width
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  local list_bufnr = vim.api.nvim_create_buf(false, true)
  local preview_bufnr = vim.api.nvim_create_buf(false, true)
  local list_winid = vim.api.nvim_open_win(list_bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = list_width,
    height = height,
    row = row,
    col = col,
    title = " Context ",
    title_pos = "center",
  })
  local preview_winid = vim.api.nvim_open_win(preview_bufnr, false, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = preview_width,
    height = height,
    row = row,
    col = col + list_width + gap,
    title = " Exact payload ",
    title_pos = "center",
  })
  local ui = {
    session = session,
    list_bufnr = list_bufnr,
    list_winid = list_winid,
    preview_bufnr = preview_bufnr,
    preview_winid = preview_winid,
    line_to_id = {},
  }
  active = ui
  session.on_update = function()
    vim.schedule(function()
      render(ui)
    end)
  end
  session.ui_close = function()
    close_ui(ui)
  end

  configure_buffer(list_bufnr, "herdr-context-composer")
  configure_buffer(preview_bufnr, "herdr-context-preview")
  configure_window(list_winid, true)
  configure_window(preview_winid, false)

  local function map(bufnr, lhs, callback, description)
    vim.keymap.set("n", lhs, callback, { buffer = bufnr, silent = true, nowait = true, desc = description })
  end
  for _, bufnr in ipairs({ list_bufnr, preview_bufnr }) do
    map(bufnr, "q", function()
      session:close()
    end, "Cancel Herdr context composer")
    map(bufnr, "<Esc>", function()
      session:close()
    end, "Cancel Herdr context composer")
    map(bufnr, "s", function()
      session:stage()
    end, "Stage Herdr context bundle")
    map(bufnr, "t", function()
      session:change_target()
    end, "Change Herdr target")
    map(bufnr, "r", function()
      session:refresh()
    end, "Refresh Herdr context")
    map(bufnr, "p", function()
      session:toggle_preview()
    end, "Toggle Herdr payload preview")
    map(bufnr, "i", function()
      edit_instruction(ui)
    end, "Edit Herdr instruction")
    map(bufnr, "P", function()
      choose_preset(ui)
    end, "Choose Herdr context preset")
    map(bufnr, "h", function()
      require("herdr-context.ui.history").open()
    end, "Open Herdr history")
    map(bufnr, "?", show_help, "Show Herdr composer help")
  end
  map(list_bufnr, " ", function()
    local id = ui.line_to_id[vim.api.nvim_win_get_cursor(list_winid)[1]]
    if id then
      session:toggle(id)
    end
  end, "Toggle Herdr context provider")
  map(list_bufnr, "<Tab>", function()
    vim.api.nvim_set_current_win(preview_winid)
  end, "Focus Herdr payload preview")
  map(preview_bufnr, "<Tab>", function()
    vim.api.nvim_set_current_win(list_winid)
  end, "Focus Herdr provider list")

  for _, bufnr in ipairs({ list_bufnr, preview_bufnr }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        cleanup(ui)
      end,
    })
  end
  ui.stale_autocmd = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = session.request.bufnr,
    callback = function()
      if not session.closed then
        session.stale = true
        render(ui)
      end
    end,
  })
  render(ui)
  return list_bufnr
end

function M._active()
  return active
end

M.format_bytes = format_bytes

return M
