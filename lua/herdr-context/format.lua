local M = {}

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

local function line_suffix(context)
  if context.start_line == context.end_line then
    return "#L" .. context.start_line
  end
  return ("#L%d-L%d"):format(context.start_line, context.end_line)
end

local function size_error(payload, max_bytes)
  if #payload <= max_bytes then
    return nil
  end
  return ("Payload is %d bytes; the configured maximum is %d bytes"):format(#payload, max_bytes)
end

function M.validate(payload, max_bytes)
  if type(payload) ~= "string" then
    return nil, "Payload must be a string"
  end
  local err = size_error(payload, max_bytes)
  if err then
    return nil, err
  end
  return payload
end

function M.reference(context)
  if context.unnamed or not context.relative_path then
    return nil, "Reference-only mode requires a named buffer with a stable path"
  end
  return "@" .. context.relative_path .. line_suffix(context)
end

local function source_label(context)
  local reference = M.reference(context)
  if not reference then
    return ("Unnamed buffer lines L%d-L%d"):format(context.start_line, context.end_line)
  end
  return reference
end

local function longest_backtick_run(text)
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  return longest
end

local function fence_for(text)
  return string.rep("`", math.max(3, longest_backtick_run(text) + 1))
end

local function language_for(filetype)
  filetype = (filetype or ""):match("^[%w_+.-]+") or ""
  return filetype
end

function M.content(context)
  local label = source_label(context)
  if context.modified then
    label = label .. " (unsaved changes)"
  end

  local fence = fence_for(context.text)
  return table.concat({
    label,
    "",
    fence .. language_for(context.filetype),
    context.text,
    fence,
  }, "\n")
end

local function diagnostic_identity(diagnostic)
  local source = diagnostic.source and tostring(diagnostic.source) or nil
  local code = diagnostic.code ~= nil and tostring(diagnostic.code) or nil
  if source and code then
    return (" [%s:%s]"):format(source, code)
  elseif source then
    return (" [%s]"):format(source)
  elseif code then
    return (" [%s]"):format(code)
  end
  return ""
end

local function clean_message(message)
  return tostring(message or ""):gsub("[%s\r\n]+", " "):match("^%s*(.-)%s*$")
end

function M.diagnostics(context, diagnostics)
  local label = source_label(context)
  if context.modified then
    label = label .. " (unsaved changes)"
  end

  local lines = { "Diagnostics for " .. label .. ":", "" }
  if #diagnostics == 0 then
    lines[#lines + 1] = "- No diagnostics in this range."
  else
    for _, diagnostic in ipairs(diagnostics) do
      local severity = severity_names[diagnostic.severity] or "ERROR"
      local line = (diagnostic.lnum or 0) + 1
      lines[#lines + 1] = ("- %s%s L%d: %s"):format(
        severity,
        diagnostic_identity(diagnostic),
        line,
        clean_message(diagnostic.message)
      )
    end
  end
  return table.concat(lines, "\n")
end

return M
