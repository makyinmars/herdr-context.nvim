local M = {}

local config = require("herdr-context.config")
local history = require("herdr-context.history")
local picker = require("herdr-context.picker")
local targets = require("herdr-context.targets")
local transport = require("herdr-context.transport")

local active

local function valid(ui)
  return ui and vim.api.nvim_buf_is_valid(ui.bufnr) and vim.api.nvim_win_is_valid(ui.winid)
end

local function selected(ui)
  if not valid(ui) then
    return nil
  end
  return ui.line_to_entry[vim.api.nvim_win_get_cursor(ui.winid)[1]]
end

local function render(ui, detail)
  if not valid(ui) then
    return
  end
  local entries = history.get()
  local lines = { "Herdr Context History", "" }
  ui.line_to_entry = {}
  if #entries == 0 then
    lines[#lines + 1] = "No staged context in this session."
  else
    for _, entry in ipairs(entries) do
      local target = entry.target or {}
      local time = os.date("%H:%M:%S", entry.timestamp)
      local line = ("#%-3d %s  %-12s → %-8s %-12s %d B"):format(
        entry.id,
        time,
        entry.kind or "context",
        target.agent or "agent",
        target.pane_id or "?",
        entry.bytes or #(entry.payload or "")
      )
      lines[#lines + 1] = line
      ui.line_to_entry[#lines] = entry
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<CR>/p inspect   s restage   c clear   q close"
  if detail then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.rep("─", 58)
    vim.list_extend(lines, vim.split(detail.payload or "", "\n", { plain = true }))
  end
  vim.bo[ui.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(ui.bufnr, 0, -1, false, lines)
  vim.bo[ui.bufnr].modifiable = false
end

local function close()
  if not active then
    return
  end
  local ui = active
  active = nil
  if vim.api.nvim_win_is_valid(ui.winid) then
    vim.api.nvim_win_close(ui.winid, true)
  elseif vim.api.nvim_buf_is_valid(ui.bufnr) then
    vim.api.nvim_buf_delete(ui.bufnr, { force = true })
  end
end

function M.open()
  if valid(active) then
    vim.api.nvim_set_current_win(active.winid)
    return active.bufnr
  end
  local width = math.min(math.max(60, math.floor(vim.o.columns * 0.8)), math.max(1, vim.o.columns - 4))
  local height = math.min(math.max(12, math.floor(vim.o.lines * 0.7)), math.max(1, vim.o.lines - 4))
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = " Herdr Context History ",
    title_pos = "center",
  })
  local ui = { bufnr = bufnr, winid = winid, line_to_entry = {} }
  active = ui
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "herdr-context-history"
  vim.bo[bufnr].modifiable = false
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = true

  local function map(lhs, callback, desc)
    vim.keymap.set("n", lhs, callback, { buffer = bufnr, silent = true, nowait = true, desc = desc })
  end
  map("q", close, "Close Herdr history")
  map("<Esc>", close, "Close Herdr history")
  local function inspect()
    local entry = selected(ui)
    if entry then
      render(ui, entry)
    end
  end
  map("<CR>", inspect, "Inspect staged context")
  map("p", inspect, "Inspect staged context")
  map("c", function()
    history.clear()
    render(ui)
  end, "Clear Herdr history")
  map("s", function()
    local entry = selected(ui)
    if not entry then
      return
    end
    if entry.target then
      targets.remember(config.get(), entry.target)
    end
    targets.resolve(config.get(), picker, {}, function(target, err)
      if not target then
        if err ~= "Target selection cancelled" then
          vim.notify(err, vim.log.levels.ERROR, { title = "herdr-context.nvim" })
        end
        return
      end
      transport.stage(config.get(), target, entry.payload, function(ok, stage_err, result)
        if not ok then
          vim.notify(stage_err, vim.log.levels.ERROR, { title = "herdr-context.nvim" })
          return
        end
        local repeated = vim.deepcopy(entry)
        repeated.id = nil
        repeated.timestamp = os.time()
        repeated.target = target
        repeated.kind = "history"
        repeated.mode = result.mode
        history.record(repeated)
        render(ui)
        vim.notify(("Restaged context for %s (%s)"):format(target.agent or "agent", target.pane_id), nil, {
          title = "herdr-context.nvim",
        })
      end)
    end)
  end, "Restage Herdr context")
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if active == ui then
        active = nil
      end
    end,
  })
  render(ui)
  return bufnr
end

function M.toggle()
  if valid(active) then
    close()
  else
    return M.open()
  end
end

function M._active()
  return active
end

return M
