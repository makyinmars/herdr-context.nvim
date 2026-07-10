local bundle = require("herdr-context.bundle")
local config = require("herdr-context.config")
local util = require("herdr-context.providers.util")

local M = {
  id = "trouble",
  name = "Trouble view",
  priority = 60,
}

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

local function trouble_module()
  return package.loaded.trouble or package.loaded["trouble"]
end

local function open_modes(trouble)
  local modes = {}
  for _, mode in ipairs(config.get().providers.trouble.modes) do
    local ok, open = pcall(trouble.is_open, mode)
    if ok and open then
      modes[#modes + 1] = mode
    end
  end
  return modes
end

function M.available()
  if not config.get().providers.trouble.enabled then
    return false, "Disabled by providers.trouble.enabled"
  end
  local trouble = trouble_module()
  if type(trouble) ~= "table" or type(trouble.get_items) ~= "function" then
    return false, "Trouble is not loaded"
  end
  if #open_modes(trouble) == 0 then
    return false, "No matching Trouble view is open"
  end
  return true
end

function M.collect(request, callback)
  local trouble = trouble_module()
  local items, seen = {}, {}
  local modes = open_modes(trouble)
  for _, mode in ipairs(modes) do
    local ok, source = pcall(trouble.get_items, mode)
    if not ok then
      callback(nil, "Could not read Trouble " .. mode .. " view: " .. tostring(source))
      return
    end
    for _, item in ipairs(source or {}) do
      local position = item.pos or {}
      local path = util.relative_path(item.filename, request)
      local line = tonumber(position[1] or item.lnum) or 0
      if path and line > 0 then
        local normalized = {
          path = path,
          line = line,
          column = math.max(tonumber(position[2] or item.col) or 0, 0),
          severity = severity_names[item.severity] or item.type,
          message = util.clean_message(item.message or item.text or (item.item and item.item.text)),
        }
        normalized.fingerprint = bundle.item_fingerprint(normalized)
        if not seen[normalized.fingerprint] then
          seen[normalized.fingerprint] = true
          items[#items + 1] = normalized
        end
      end
    end
  end
  if #items == 0 then
    callback(nil, { kind = "unavailable", message = "Matching Trouble views contain no valid items" })
    return
  end
  callback({
    id = "trouble",
    title = "Trouble view",
    summary = ("%d item%s"):format(#items, #items == 1 and "" or "s"),
    priority = 60,
    format = "list",
    content = "",
    items = items,
    fingerprint = "trouble:" .. table.concat(
      vim.tbl_map(function(item)
        return item.fingerprint
      end, items),
      "|"
    ),
  })
end

return M
