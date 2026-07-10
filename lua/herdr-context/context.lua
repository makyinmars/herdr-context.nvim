local M = {}

local uv = vim.uv or vim.loop

local function normalize_path(path)
  if path == "" then
    return path
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function is_directory(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory"
end

function M.find_git_root(path)
  if not path or path == "" then
    return nil
  end

  local current = normalize_path(path)
  if not is_directory(current) then
    current = vim.fs.dirname(current)
  end

  while current and current ~= "" do
    if uv.fs_stat(current .. "/.git") then
      return current
    end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      break
    end
    current = parent
  end
end

local function relative_path(root, path)
  root = normalize_path(root):gsub("/+$", "")
  path = normalize_path(path)
  if path == root then
    return vim.fs.basename(path)
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end

  local root_parts = vim.split(root, "/", { plain = true, trimempty = true })
  local path_parts = vim.split(path, "/", { plain = true, trimempty = true })
  local common = 0
  while root_parts[common + 1] and root_parts[common + 1] == path_parts[common + 1] do
    common = common + 1
  end
  if common == 0 then
    return path
  end

  local relative = {}
  for _ = common + 1, #root_parts do
    relative[#relative + 1] = ".."
  end
  for index = common + 1, #path_parts do
    relative[#relative + 1] = path_parts[index]
  end
  return table.concat(relative, "/")
end

function M.resolve_path(path, cwd)
  if not path or path == "" then
    return nil, nil
  end

  path = normalize_path(path)
  cwd = normalize_path(cwd or uv.cwd() or vim.fn.getcwd())
  local root = M.find_git_root(path) or cwd
  return relative_path(root, path), root
end

local function normalize_position(first, last)
  if first[1] > last[1] or (first[1] == last[1] and first[2] > last[2]) then
    return last, first
  end
  return first, last
end

local function visual_selection(bufnr)
  local mode = vim.fn.mode(1)
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end

  local first = vim.fn.getpos("v")
  local last = vim.fn.getpos(".")
  return {
    mode = mode,
    start = { first[2], math.max(first[3], 1) },
    finish = { last[2], math.max(last[3], 1) },
  }
end

local function selection_text(bufnr, selection)
  local first, last = normalize_position(selection.start, selection.finish)
  local mode = selection.mode

  if mode == "V" or mode == "line" then
    local lines = vim.api.nvim_buf_get_lines(bufnr, first[1] - 1, last[1], false)
    return lines, table.concat(lines, "\n"), first[1], last[1]
  end

  if mode == "\22" or mode == "block" then
    local lines = {}
    local start_col = math.min(first[2], last[2]) - 1
    local end_col = math.max(first[2], last[2])
    for line = first[1], last[1] do
      local source = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
      local line_start = math.min(start_col, #source)
      local line_end = math.min(math.max(end_col, line_start), #source)
      local part = vim.api.nvim_buf_get_text(bufnr, line - 1, line_start, line - 1, line_end, {})
      lines[#lines + 1] = part[1] or ""
    end
    return lines, table.concat(lines, "\n"), first[1], last[1]
  end

  local end_col = last[2]
  if vim.o.selection == "exclusive" and end_col > 0 then
    end_col = end_col - 1
  end
  local lines = vim.api.nvim_buf_get_text(bufnr, first[1] - 1, first[2] - 1, last[1] - 1, end_col, {})
  return lines, table.concat(lines, "\n"), first[1], last[1]
end

local function line_selection(bufnr, start_line, end_line)
  start_line = math.max(1, start_line)
  end_line = math.max(1, end_line)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  return lines, table.concat(lines, "\n"), start_line, end_line
end

function M.capture(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("herdr-context: the buffer is no longer valid")
  end

  local lines, text, start_line, end_line
  local selection = opts.selection or visual_selection(bufnr)
  if selection then
    lines, text, start_line, end_line = selection_text(bufnr, selection)
  elseif opts.line1 and opts.line2 then
    lines, text, start_line, end_line = line_selection(bufnr, opts.line1, opts.line2)
  else
    local cursor_line = opts.line or vim.api.nvim_win_get_cursor(0)[1]
    lines, text, start_line, end_line = line_selection(bufnr, cursor_line, cursor_line)
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local relative, root = M.resolve_path(name, opts.cwd)
  local modified = vim.bo[bufnr].modified

  return {
    bufnr = bufnr,
    path = name ~= "" and normalize_path(name) or nil,
    relative_path = relative,
    root = root,
    unnamed = name == "",
    modified = modified,
    filetype = vim.bo[bufnr].filetype,
    lines = lines,
    text = text,
    start_line = start_line,
    end_line = end_line,
    selection_mode = selection and selection.mode or "line",
  }
end

local function overlaps(diagnostic, first_line, last_line)
  local start_line = (diagnostic.lnum or 0) + 1
  local end_line = (diagnostic.end_lnum or diagnostic.lnum or 0) + 1
  return end_line >= first_line and start_line <= last_line
end

function M.diagnostics(context)
  local items = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(context.bufnr)) do
    if overlaps(diagnostic, context.start_line, context.end_line) then
      items[#items + 1] = diagnostic
    end
  end

  table.sort(items, function(a, b)
    local a_line, b_line = a.lnum or 0, b.lnum or 0
    if a_line ~= b_line then
      return a_line < b_line
    end
    local a_severity = a.severity or vim.diagnostic.severity.ERROR
    local b_severity = b.severity or vim.diagnostic.severity.ERROR
    if a_severity ~= b_severity then
      return a_severity < b_severity
    end
    return (a.message or "") < (b.message or "")
  end)

  return items
end

return M
