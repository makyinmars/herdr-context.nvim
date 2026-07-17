local M = {}

local config = require("herdr-context.config")
local herdr = require("herdr-context.herdr")

local active
local generation = 0

local function valid(preview)
  return preview and vim.api.nvim_buf_is_valid(preview.bufnr) and vim.api.nvim_win_is_valid(preview.winid)
end

local function render(preview, lines)
  if not valid(preview) then
    return
  end
  vim.bo[preview.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(preview.bufnr, 0, -1, false, lines)
  vim.bo[preview.bufnr].modifiable = false
end

local function cleanup(preview)
  if active ~= preview then
    return
  end
  active = nil
  generation = generation + 1
  if preview.process and preview.process.kill then
    pcall(preview.process.kill, preview.process, 15)
  end
end

function M.close()
  local preview = active
  if not preview then
    return
  end
  if vim.api.nvim_win_is_valid(preview.winid) then
    vim.api.nvim_win_close(preview.winid, true)
  elseif vim.api.nvim_buf_is_valid(preview.bufnr) then
    vim.api.nvim_buf_delete(preview.bufnr, { force = true })
  else
    cleanup(preview)
  end
  local source_winid = preview.opts and preview.opts.source_winid
  if source_winid and vim.api.nvim_win_is_valid(source_winid) then
    vim.api.nvim_set_current_win(source_winid)
  end
end

function M.open(agent, opts)
  opts = opts or {}
  M.close()
  generation = generation + 1
  local request_generation = generation
  local bufnr = vim.api.nvim_create_buf(false, true)
  local label = agent.display_agent or agent.agent or "agent"
  local winid
  if opts.side and opts.source_winid and vim.api.nvim_win_is_valid(opts.source_winid) then
    vim.api.nvim_set_current_win(opts.source_winid)
    vim.cmd(opts.position == "left" and "rightbelow vsplit" or "leftabove vsplit")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_width(winid, config.get().agents_view.preview_width)
    vim.wo[winid].winbar = ("%%#Title# %s · recent output "):format(label)
  else
    local max_width = math.max(1, vim.o.columns - 4)
    local max_height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
    local width = math.min(math.max(40, math.floor(vim.o.columns * 0.75)), max_width)
    local height = math.min(math.max(8, math.floor((vim.o.lines - vim.o.cmdheight) * 0.7)), max_height)
    winid = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = width,
      height = height,
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      title = (" %s · recent output "):format(label),
      title_pos = "center",
    })
  end
  local preview = { bufnr = bufnr, winid = winid, pane_id = agent.pane_id, agent = agent, opts = opts }
  active = preview

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "herdr-context-output"
  vim.bo[bufnr].modifiable = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].wrap = false

  local function close()
    M.close()
  end
  for _, key in ipairs({ "q", "<Esc>", "p" }) do
    vim.keymap.set("n", key, close, { buffer = bufnr, silent = true, nowait = true, desc = "Close Herdr output" })
  end
  vim.keymap.set("n", "r", function()
    M.open(agent, opts)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Refresh Herdr output" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      cleanup(preview)
    end,
  })

  render(preview, { "Loading recent agent output…" })
  preview.process = herdr.read_agent(config.get(), agent.pane_id, {
    source = "recent-unwrapped",
    lines = config.get().agents_view.preview_lines,
  }, function(output, err)
    if active ~= preview or generation ~= request_generation then
      return
    end
    if err then
      render(preview, { "Could not read agent output:", "", err })
      return
    end
    output = (output or ""):gsub("\r\n", "\n"):gsub("\n$", "")
    if output == "" then
      render(preview, { "No recent agent output." })
      return
    end
    render(preview, vim.split(output, "\n", { plain = true }))
  end)
  return bufnr
end

function M._active()
  return active
end

return M
