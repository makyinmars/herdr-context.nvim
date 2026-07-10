local M = {}

local redraw_pending = false

local function valid()
  return vim.v.exiting == vim.NIL or vim.v.exiting == 0
end

function M.emit(pattern, data)
  if not valid() then
    return
  end
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    data = data or {},
  })
end

function M.redraw_statusline()
  if redraw_pending or not valid() then
    return
  end
  redraw_pending = true
  vim.schedule(function()
    redraw_pending = false
    if valid() then
      pcall(vim.cmd, "redrawstatus")
    end
  end)
end

return M
