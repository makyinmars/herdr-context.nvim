local M = {}

local formats = {
  code = true,
  diff = true,
  diagnostics = true,
  list = true,
  text = true,
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

function M.render_section(section)
  local lines = { "## " .. section.title, "" }
  if section.reference and section.reference ~= "" then
    local reference = section.reference
    if section.modified then
      reference = reference .. " (unsaved changes)"
    end
    lines[#lines + 1] = reference
    lines[#lines + 1] = ""
  end

  if section.format == "code" or section.format == "diff" then
    local fence = fence_for(section.content)
    local language = section.format == "diff" and "diff" or language_for(section.language)
    lines[#lines + 1] = fence .. language
    lines[#lines + 1] = section.content
    lines[#lines + 1] = fence
  elseif section.format == "diagnostics" then
    vim.list_extend(lines, diagnostic_lines(section))
  elseif section.format == "list" then
    vim.list_extend(lines, list_lines(section))
  else
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

function M.build(sections, max_bytes)
  vim.validate({ sections = { sections, "table" }, max_bytes = { max_bytes, "number" } })
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
    section.rendered = M.render_section(section)
    section.bytes = #section.rendered
    rendered[#rendered + 1] = section.rendered
  end
  local payload = "Context bundle"
  if #rendered > 0 then
    payload = payload .. "\n\n" .. table.concat(rendered, "\n\n")
  end
  local bytes = #payload
  local oversized = bytes > max_bytes
  return {
    sections = normalized,
    payload = payload,
    bytes = bytes,
    max_bytes = max_bytes,
    oversized = oversized,
    error = oversized and ("Payload is %d bytes; the configured maximum is %d bytes"):format(bytes, max_bytes) or nil,
  }
end

M.item_fingerprint = item_fingerprint

return M
