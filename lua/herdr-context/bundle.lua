local M = {}

local formats = {
  code = true,
  diff = true,
  diagnostics = true,
  list = true,
  text = true,
  reference = true,
}

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

local function clean(value)
  return tostring(value or ""):gsub("[%s\r\n]+", " "):match("^%s*(.-)%s*$")
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

local function language_for(language)
  return (language or ""):match("^[%w_+.-]+") or ""
end

local function diagnostic_identity(item)
  local source = item.source and tostring(item.source) or nil
  local code = item.code ~= nil and tostring(item.code) or nil
  if source and code then
    return (" [%s:%s]"):format(source, code)
  elseif source then
    return (" [%s]"):format(source)
  elseif code then
    return (" [%s]"):format(code)
  end
  return ""
end

local function item_fingerprint(item)
  return item.fingerprint
    or table.concat({
      item.path or "",
      tostring(item.line or item.lnum or ""),
      tostring(item.column or item.col or ""),
      clean(item.message or item.text),
    }, ":")
end

local function diagnostic_lines(section)
  if section.items then
    local lines = {}
    for _, item in ipairs(section.items) do
      local severity = severity_names[item.severity] or clean(item.severity or item.type):upper()
      if severity == "" then
        severity = "ERROR"
      end
      local line = item.line or ((item.lnum or 0) + 1)
      lines[#lines + 1] = ("- %s%s L%d: %s"):format(
        severity,
        diagnostic_identity(item),
        line,
        clean(item.message or item.text)
      )
    end
    if #lines == 0 then
      lines[1] = "- No diagnostics in this range."
    end
    return lines
  end
  return vim.split(section.content, "\n", { plain = true })
end

local function list_lines(section)
  if not section.items then
    return vim.split(section.content, "\n", { plain = true })
  end

  local lines = {}
  for _, item in ipairs(section.items) do
    local location = item.path or "[no file]"
    if item.line then
      location = location .. ":" .. tostring(item.line)
      if item.column and item.column > 0 then
        location = location .. ":" .. tostring(item.column)
      end
    end
    local kind = clean(item.severity or item.type):upper()
    if kind ~= "" then
      kind = kind .. " "
    end
    lines[#lines + 1] = ("- %s%s: %s"):format(kind, location, clean(item.message or item.text))
  end
  if #lines == 0 then
    lines[1] = "- No unique valid items."
  end
  if (section.invalid_count or 0) > 0 then
    lines[#lines + 1] = ("- Ignored %d invalid item%s."):format(
      section.invalid_count,
      section.invalid_count == 1 and "" or "s"
    )
  end
  return lines
end

function M.file_reference_string(path, start_line, end_line)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if start_line == nil or end_line == nil then
    return "@" .. path
  end
  if start_line == end_line then
    return ("@%s#L%d"):format(path, start_line)
  end
  return ("@%s#L%d-L%d"):format(path, start_line, end_line)
end

local function unnamed_label(captured)
  return ("Unnamed buffer lines L%d-L%d"):format(captured.start_line, captured.end_line)
end

function M.section_from_capture(kind, captured, opts)
  opts = opts or {}
  local named = not captured.unnamed and type(captured.relative_path) == "string" and captured.relative_path ~= ""
  local reference = named and M.file_reference_string(captured.relative_path, captured.start_line, captured.end_line)
    or unnamed_label(captured)

  if kind == "reference" then
    if not named then
      return nil, "Reference-only mode requires a named buffer with a stable path"
    end
    return {
      id = "selection",
      title = "Reference",
      priority = 10,
      format = "reference",
      reference = reference,
      content = "",
      language = captured.filetype,
      fingerprint = "reference:" .. reference,
    }
  end

  if kind == "content" then
    return {
      id = "selection",
      title = "Selection",
      priority = 10,
      format = "code",
      reference = reference,
      content = captured.text or "",
      language = captured.filetype,
      modified = captured.modified,
      embed = true,
      fingerprint = "content:" .. reference,
    }
  end

  if kind == "diagnostics" then
    return {
      id = "diagnostics",
      title = "Diagnostics",
      priority = 30,
      format = "diagnostics",
      reference = named and reference or nil,
      content = "",
      items = opts.diagnostics or opts.items or {},
      modified = captured.modified,
      fingerprint = "diagnostics:" .. (named and reference or "unnamed"),
    }
  end

  return nil, "Unknown context operation: " .. tostring(kind)
end

function M.build_capture(kind, captured, opts)
  opts = opts or {}
  local section, err = M.section_from_capture(kind, captured, opts)
  if not section then
    return nil, err
  end
  local include = kind == "content" and "content" or "reference"
  local built, build_err = M.build({ section }, opts.max_bytes or 64 * 1024, { include = include })
  if not built then
    return nil, build_err
  end
  if built.oversized then
    return nil, built.error, built
  end
  return built
end

local function file_reference(section)
  local reference = section.reference
  if type(reference) ~= "string" or reference == "" then
    return nil
  end
  if section.modified then
    return reference .. " (unsaved changes)"
  end
  return reference
end

local function has_file_reference(section)
  return type(section.reference) == "string" and section.reference:match("^@") ~= nil
end

local function should_embed(section, include)
  if section.embed then
    return true
  end
  if include == "content" then
    return true
  end
  if section.format == "reference" then
    return false
  end
  return not has_file_reference(section)
end

function M.normalize(section, provider)
  if type(section) ~= "table" then
    return nil, "Provider returned a non-table section"
  end
  local normalized = vim.deepcopy(section)
  normalized.id = normalized.id or (provider and provider.id)
  normalized.title = normalized.title or (provider and provider.name) or normalized.id
  normalized.priority = normalized.priority or (provider and provider.priority) or 100
  normalized.format = normalized.format or "text"
  normalized.content = normalized.content or ""

  if type(normalized.id) ~= "string" or normalized.id == "" then
    return nil, "Section id must be a non-empty string"
  end
  if type(normalized.title) ~= "string" or normalized.title == "" then
    return nil, ("Section %s has no title"):format(normalized.id)
  end
  if type(normalized.priority) ~= "number" then
    return nil, ("Section %s priority must be a number"):format(normalized.id)
  end
  if not formats[normalized.format] then
    return nil, ("Section %s has unsupported format %q"):format(normalized.id, tostring(normalized.format))
  end
  if type(normalized.content) ~= "string" then
    return nil, ("Section %s content must be a string"):format(normalized.id)
  end
  if normalized.items ~= nil and type(normalized.items) ~= "table" then
    return nil, ("Section %s items must be a table"):format(normalized.id)
  end
  normalized.fingerprint = tostring(normalized.fingerprint or normalized.id)
  return normalized
end

function M.render_section(section, opts)
  opts = opts or {}
  local include = opts.include or "reference"

  if section.id == "instructions" then
    return section.content
  end

  if section.format == "diagnostics" then
    return table.concat(diagnostic_lines(section), "\n")
  end

  if section.format == "list" then
    local lines = { section.title, "" }
    vim.list_extend(lines, list_lines(section))
    return table.concat(lines, "\n")
  end

  if section.format == "text" then
    return section.content
  end

  local lines = {}
  local reference = file_reference(section)
  if reference then
    lines[#lines + 1] = reference
  end

  if should_embed(section, include) then
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    local fence = fence_for(section.content)
    local language = section.format == "diff" and "diff" or language_for(section.language)
    lines[#lines + 1] = fence .. language
    lines[#lines + 1] = section.content
    lines[#lines + 1] = fence
  elseif #lines == 0 then
    lines[#lines + 1] = section.content
  end

  return table.concat(lines, "\n")
end

local function ordered(sections)
  table.sort(sections, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    if a.id ~= b.id then
      return a.id < b.id
    end
    return a.fingerprint < b.fingerprint
  end)
  return sections
end

function M.build(sections, max_bytes, opts)
  vim.validate({ sections = { sections, "table" }, max_bytes = { max_bytes, "number" } })
  opts = opts or {}
  local include = opts.include or "reference"
  if include ~= "reference" and include ~= "content" then
    include = "reference"
  end

  local normalized = {}
  local fingerprints = {}
  local list_items = {}

  for _, source in ipairs(sections) do
    local section, err = M.normalize(source)
    if not section then
      return nil, err
    end
    if not fingerprints[section.fingerprint] then
      fingerprints[section.fingerprint] = true
      if section.format == "list" and section.items then
        local unique = {}
        for _, item in ipairs(section.items) do
          local fingerprint = item_fingerprint(item)
          if not list_items[fingerprint] then
            list_items[fingerprint] = true
            unique[#unique + 1] = item
          end
        end
        section.items = unique
      end
      normalized[#normalized + 1] = section
    end
  end

  ordered(normalized)
  local rendered = {}
  for _, section in ipairs(normalized) do
    section.rendered = M.render_section(section, { include = include })
    section.bytes = #section.rendered
    if section.rendered ~= "" then
      rendered[#rendered + 1] = section.rendered
    end
  end
  local payload = table.concat(rendered, "\n\n")
  local bytes = #payload
  local oversized = bytes > max_bytes
  return {
    sections = normalized,
    payload = payload,
    bytes = bytes,
    max_bytes = max_bytes,
    include = include,
    oversized = oversized,
    error = oversized and ("Payload is %d bytes; the configured maximum is %d bytes"):format(bytes, max_bytes) or nil,
  }
end

M.item_fingerprint = item_fingerprint
M.has_file_reference = has_file_reference

return M
