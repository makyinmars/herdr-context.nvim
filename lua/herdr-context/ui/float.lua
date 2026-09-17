local M = {}

function M.valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

function M.valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

function M.format_bytes(bytes)
  bytes = bytes or 0
  if bytes < 1024 then
    return ("%d B"):format(bytes)
  end
  return ("%.1f KiB"):format(bytes / 1024)
end

function M.dimension(value, total, minimum)
  if value <= 1 then
    value = math.floor(total * value)
  end
  return math.min(math.max(minimum, math.floor(value)), math.max(1, total - 2))
end

function M.configure_buffer(bufnr, opts)
  opts = opts or {}
  vim.bo[bufnr].buftype = opts.buftype or "nofile"
  vim.bo[bufnr].bufhidden = opts.bufhidden or "wipe"
  vim.bo[bufnr].swapfile = false
  if opts.filetype then
    vim.bo[bufnr].filetype = opts.filetype
  end
  if opts.modifiable ~= nil then
    vim.bo[bufnr].modifiable = opts.modifiable
  end
end

function M.configure_window(winid, opts)
  opts = opts or {}
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].wrap = opts.wrap == true
  vim.wo[winid].linebreak = opts.wrap == true
  vim.wo[winid].cursorline = opts.cursorline == true
  if opts.winhighlight ~= false then
    vim.wo[winid].winhighlight = opts.winhighlight
      or "Normal:NormalFloat,FloatBorder:Comment,FloatTitle:Title,FloatFooter:Comment,CursorLine:Visual"
  end
end

function M.set_lines(bufnr, lines, opts)
  opts = opts or {}
  if not M.valid_buffer(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if opts.namespace then
    vim.api.nvim_buf_clear_namespace(bufnr, opts.namespace, 0, -1)
    for _, mark in ipairs(opts.marks or {}) do
      vim.api.nvim_buf_set_extmark(bufnr, opts.namespace, mark.line, mark.start_col, {
        end_col = mark.end_col,
        hl_group = mark.hl,
      })
    end
  end
  if opts.modifiable == false then
    vim.bo[bufnr].modifiable = false
  end
end

function M.open(opts)
  local bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
  local win_opts = {
    relative = "editor",
    style = "minimal",
    border = opts.border or "rounded",
    width = opts.width,
    height = opts.height,
    row = opts.row,
    col = opts.col,
  }
  if opts.title then
    win_opts.title = opts.title
    win_opts.title_pos = opts.title_pos or "center"
  end
  if opts.footer then
    win_opts.footer = opts.footer
    win_opts.footer_pos = opts.footer_pos or "center"
  end
  if opts.zindex then
    win_opts.zindex = opts.zindex
  end
  local winid = vim.api.nvim_open_win(bufnr, opts.enter == true, win_opts)
  M.configure_buffer(bufnr, {
    filetype = opts.filetype,
    modifiable = opts.modifiable,
  })
  M.configure_window(winid, {
    cursorline = opts.cursorline,
    wrap = opts.wrap,
    winhighlight = opts.winhighlight,
  })
  return bufnr, winid
end

function M.reposition(winid, opts)
  if not M.valid_window(winid) then
    return
  end
  local win_opts = {}
  for key, value in pairs(opts) do
    if value ~= nil then
      win_opts[key] = value
    end
  end
  if win_opts.footer and not win_opts.footer_pos then
    win_opts.footer_pos = "center"
  end
  if win_opts.title and not win_opts.title_pos then
    win_opts.title_pos = "center"
  end
  pcall(vim.api.nvim_win_set_config, winid, win_opts)
end

return M
