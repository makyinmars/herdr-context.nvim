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
  return math.max(minimum, math.min(math.floor(value), total - 2))
end

local function valid(ui)
  return ui and vim.api.nvim_buf_is_valid(ui.bufnr) and vim.api.nvim_win_is_valid(ui.winid)
end

local function target_label(target)
  if not target then
    return "no target selected"
  end
  return ("%s %s"):format(target.agent or "agent", target.pane_id or "?")
end

local function entry_status(session, entry)
  if entry.status == "collecting" then
    return "…"
  elseif entry.status == "unavailable" then
    return "-"
  elseif entry.status == "failed" then
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
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

local function render(ui)
  if not valid(ui) then
    return
  end
  local session = ui.session
  local cfg = config.get()
  session:is_stale()
  local built = session.bundle
  local bytes = built and built.bytes or 0
  local lines = {
    ("Herdr Context → %-24s %s / %s"):format(
      target_label(session.target),
      format_bytes(bytes),
      format_bytes(cfg.max_payload_bytes)
    ),
  }
  local marks = { { line = 0, start_col = 0, end_col = #lines[1], hl = "HerdrContextComposerHeader" } }
  ui.line_to_id = {}

  if session.stale then
    lines[#lines + 1] = "STALE — the source buffer changed; press r to refresh"
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 0,
      end_col = #lines[#lines],
      hl = "HerdrContextComposerStale",
    }
  elseif session.collecting then
    lines[#lines + 1] = "Collecting context providers…"
  end
  lines[#lines + 1] = ""

  for _, entry in ipairs(session.entries) do
    local status = entry_status(session, entry)
    local summary = entry.section and entry.section.summary or entry.error or ""
    local size = entry.bytes and format_bytes(entry.bytes) or ""
    local line = ("[%s] %-20s %-38s %9s"):format(status, entry.name, summary, size)
    lines[#lines + 1] = line
    ui.line_to_id[#lines] = entry.id
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 0,
      end_col = 3,
      hl = status_highlights[status],
    }
    if size ~= "" then
      marks[#marks + 1] = {
        line = #lines - 1,
        start_col = #line - #size,
        end_col = #line,
        hl = "HerdrContextComposerSize",
      }
    end
    if entry.error and (entry.status == "failed" or entry.status == "unavailable") then
      lines[#lines + 1] = "    " .. entry.error
      marks[#marks + 1] = {
        line = #lines - 1,
        start_col = 4,
        end_col = #lines[#lines],
        hl = entry.status == "failed" and "HerdrContextComposerError" or "Comment",
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

  local separator = string.rep("─", 58)
  lines[#lines + 1] = ""
  lines[#lines + 1] = separator
  if session.preview then
    local payload = built and built.payload or "Context bundle"
    vim.list_extend(lines, vim.split(payload, "\n", { plain = true }))
  else
    lines[#lines + 1] = "Payload preview hidden (press p to show it)"
  end
  lines[#lines + 1] = separator
  lines[#lines + 1] = ""
  local action = cfg.submit and "stage + submit" or "stage"
  lines[#lines + 1] = ("<Space> toggle   t target   r refresh   s %s   p preview   q cancel"):format(action)
  marks[#marks + 1] = {
    line = #lines - 1,
    start_col = 0,
    end_col = #lines[#lines],
    hl = "HerdrContextComposerFooter",
  }

  local cursor = vim.api.nvim_win_get_cursor(ui.winid)
  local cursor_id = ui.line_to_id[cursor[1]]
  vim.bo[ui.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(ui.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(ui.bufnr, namespace, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(ui.bufnr, namespace, mark.line, mark.start_col, {
      end_col = mark.end_col,
      hl_group = mark.hl,
    })
  end
  vim.bo[ui.bufnr].modifiable = false

  if cursor_id then
    for line, id in pairs(ui.line_to_id) do
      if id == cursor_id then
        vim.api.nvim_win_set_cursor(ui.winid, { line, 0 })
        return
      end
    end
  end
  vim.api.nvim_win_set_cursor(ui.winid, { math.min(cursor[1], #lines), 0 })
end

local function cleanup(ui)
  if active == ui then
    active = nil
  end
  local session = ui.session
  if ui.stale_autocmd then
    pcall(vim.api.nvim_del_autocmd, ui.stale_autocmd)
    ui.stale_autocmd = nil
  end
  session.ui_close = nil
  if not session.closed then
    session.closed = true
    if session.cancel_collection then
      session.cancel_collection()
      session.cancel_collection = nil
    end
  end
end

local function close_ui(ui)
  if vim.api.nvim_win_is_valid(ui.winid) then
    vim.api.nvim_win_close(ui.winid, true)
  elseif vim.api.nvim_buf_is_valid(ui.bufnr) then
    vim.api.nvim_buf_delete(ui.bufnr, { force = true })
  else
    cleanup(ui)
  end
end

function M.open(session)
  if active then
    active.session:close()
  end
  setup_highlights()
  local options = config.get().composer
  local width = dimension(options.width, vim.o.columns, 50)
  local height = dimension(options.height, vim.o.lines - vim.o.cmdheight, 12)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = " Herdr Context Composer ",
    title_pos = "center",
  })
  local ui = { session = session, bufnr = bufnr, winid = winid, line_to_id = {} }
  active = ui
  session.on_update = function()
    vim.schedule(function()
      render(ui)
    end)
  end
  session.ui_close = function()
    close_ui(ui)
  end

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "herdr-context-composer"
  vim.bo[bufnr].modifiable = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = true

  local function map(lhs, callback, description)
    vim.keymap.set("n", lhs, callback, { buffer = bufnr, silent = true, nowait = true, desc = description })
  end
  map("q", function()
    session:close()
  end, "Cancel Herdr context composer")
  map("<Esc>", function()
    session:close()
  end, "Cancel Herdr context composer")
  map(" ", function()
    local id = ui.line_to_id[vim.api.nvim_win_get_cursor(winid)[1]]
    if id then
      session:toggle(id)
    end
  end, "Toggle Herdr context provider")
  map("s", function()
    session:stage()
  end, "Stage Herdr context bundle")
  map("t", function()
    session:change_target()
  end, "Change Herdr target")
  map("r", function()
    session:refresh()
  end, "Refresh Herdr context")
  map("p", function()
    session:toggle_preview()
  end, "Toggle Herdr payload preview")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      cleanup(ui)
    end,
  })
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
  return bufnr
end

function M._active()
  return active
end

M.format_bytes = format_bytes

return M
