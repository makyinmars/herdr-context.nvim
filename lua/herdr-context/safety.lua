local M = {}

local config = require("herdr-context.config")

local function reference_path(reference)
  if not reference then
    return nil
  end
  return reference:match("^@([^#]+)")
end

local function glob_matches(path, pattern)
  if not path or path == "" then
    return false
  end
  local expression = vim.fn.glob2regpat(pattern)
  return vim.fn.match(path, expression) >= 0 or vim.fn.match(vim.fn.fnamemodify(path, ":t"), expression) >= 0
end

function M.excluded_path(path, options)
  options = options or config.get().safety
  if not options.enabled then
    return false
  end
  for _, pattern in ipairs(options.exclude_patterns) do
    if glob_matches(path, pattern) then
      return true, pattern
    end
  end
  return false
end

function M.sanitize(section, request, options)
  options = options or config.get().safety
  if not options.enabled then
    return vim.deepcopy(section)
  end
  local path = reference_path(section.reference)
  if not path and vim.tbl_contains({ "selection", "symbol", "hunk", "diagnostics" }, section.id) then
    path = request and request.relative_path
  end
  local excluded, pattern = M.excluded_path(path, options)
  if excluded then
    return nil, ("Excluded %s by safety pattern %q"):format(path, pattern)
  end

  local copy = vim.deepcopy(section)
  if copy.items then
    local kept = {}
    local removed = 0
    for _, item in ipairs(copy.items) do
      if M.excluded_path(item.path, options) then
        removed = removed + 1
      else
        kept[#kept + 1] = item
      end
    end
    copy.items = kept
    if removed > 0 then
      copy.summary = (copy.summary or copy.title)
        .. (" · %d sensitive path%s excluded"):format(removed, removed == 1 and "" or "s")
      copy.fingerprint = copy.fingerprint .. ":safe"
    end
    if #kept == 0 and removed > 0 then
      return nil, ("All %d item%s matched safety exclusions"):format(removed, removed == 1 and "" or "s")
    end
  end
  return copy
end

local function section_text(section)
  local parts = { section.content or "" }
  for _, item in ipairs(section.items or {}) do
    parts[#parts + 1] = item.message or item.text or ""
  end
  return table.concat(parts, "\n")
end

function M.scan(sections, options)
  options = options or config.get().safety
  if not options.enabled then
    return {}
  end
  local warnings = {}
  for _, section in ipairs(sections) do
    local text = section_text(section)
    local lower = text:lower()
    for index, pattern in ipairs(options.secret_patterns) do
      local ok, found = pcall(string.find, text, pattern)
      if ok and not found then
        ok, found = pcall(string.find, lower, pattern:lower())
      end
      if ok and found then
        warnings[#warnings + 1] = ("%s may contain a secret (pattern %d)"):format(section.title, index)
        break
      end
    end
  end
  return warnings
end

function M.confirm(warnings, callback)
  local options = config.get().safety
  if #warnings == 0 or not options.confirm_warnings then
    callback(true)
    return
  end
  vim.ui.select({ "Cancel", "Stage anyway" }, {
    prompt = "Potential sensitive content detected: " .. table.concat(warnings, "; "),
  }, function(choice)
    callback(choice == "Stage anyway")
  end)
end

return M
