local M = {}

function M.reference(request, start_line, end_line, path)
  path = path or request.relative_path
  if not path or path == "" then
    return ("Unnamed buffer L%d-L%d"):format(start_line, end_line)
  end
  if start_line == end_line then
    return ("@%s#L%d"):format(path, start_line)
  end
  return ("@%s#L%d-L%d"):format(path, start_line, end_line)
end

function M.range_content(bufnr, start_line, end_line)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  start_line = math.max(1, math.min(start_line, line_count))
  end_line = math.max(start_line, math.min(end_line, line_count))
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false), "\n")
end

function M.range_summary(name, start_line, end_line)
  local suffix = start_line == end_line and ("L%d"):format(start_line) or ("L%d-L%d"):format(start_line, end_line)
  if name and name ~= "" then
    return name .. " " .. suffix
  end
  return suffix
end

function M.relative_path(path, request)
  if not path or path == "" then
    return nil
  end
  local relative = require("herdr-context.context").resolve_path(path, request.cwd)
  return relative
end

function M.clean_message(message)
  return tostring(message or ""):gsub("[%s\r\n]+", " "):match("^%s*(.-)%s*$")
end

return M
