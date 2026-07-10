local util = require("herdr-context.providers.util")
local bundle = require("herdr-context.bundle")

local function item_path(item, request)
  local path = item.filename
  if (not path or path == "") and item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
    path = vim.api.nvim_buf_get_name(item.bufnr)
  end
  return util.relative_path(path, request)
end

local function normalize_items(source, request)
  local items, invalid = {}, 0
  for _, item in ipairs(source or {}) do
    local path = item_path(item, request)
    local line = tonumber(item.lnum) or 0
    if item.valid == 0 or not path or line <= 0 then
      invalid = invalid + 1
    else
      local normalized = {
        path = path,
        line = line,
        column = math.max(tonumber(item.col) or 0, 0),
        type = item.type and item.type ~= "" and item.type or nil,
        message = util.clean_message(item.text),
      }
      normalized.fingerprint = bundle.item_fingerprint(normalized)
      items[#items + 1] = normalized
    end
  end
  return items, invalid
end

local function summary(items, invalid)
  local text = ("%d item%s"):format(#items, #items == 1 and "" or "s")
  if invalid > 0 then
    text = text .. (", %d invalid"):format(invalid)
  end
  return text
end

local function provider(spec)
  return {
    id = spec.id,
    name = spec.name,
    priority = spec.priority,
    collect = function(request, callback)
      local ok, list = pcall(spec.get, request)
      if not ok then
        callback(nil, "Could not read " .. spec.name:lower() .. ": " .. tostring(list))
        return
      end
      local items, invalid = normalize_items(list.items, request)
      if #items == 0 and invalid == 0 then
        callback(nil, { kind = "unavailable", message = spec.name .. " is empty" })
        return
      end
      local fingerprints = vim.tbl_map(function(item)
        return item.fingerprint
      end, items)
      callback({
        id = spec.id,
        title = (list.title and list.title ~= "") and list.title or spec.name,
        summary = summary(items, invalid),
        priority = spec.priority,
        format = "list",
        content = "",
        items = items,
        invalid_count = invalid,
        fingerprint = spec.id .. ":" .. table.concat(fingerprints, "|"),
      })
    end,
  }
end

local quickfix = provider({
  id = "quickfix",
  name = "Quickfix list",
  priority = 40,
  get = function()
    return vim.fn.getqflist({ all = true })
  end,
})

local location_list = provider({
  id = "location_list",
  name = "Location list",
  priority = 50,
  get = function(request)
    local winid = vim.api.nvim_win_is_valid(request.winid) and request.winid or 0
    return vim.fn.getloclist(winid, { all = true })
  end,
})

return {
  providers = { quickfix, location_list },
  normalize_items = normalize_items,
}
