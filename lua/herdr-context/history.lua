local M = {}

local config = require("herdr-context.config")

local entries = {}
local next_id = 1

function M.record(item)
  if not config.get().history.enabled then
    return nil
  end
  local entry = vim.deepcopy(item)
  entry.id = next_id
  entry.timestamp = entry.timestamp or os.time()
  next_id = next_id + 1
  table.insert(entries, 1, entry)
  while #entries > config.get().history.max_entries do
    table.remove(entries)
  end
  return vim.deepcopy(entry)
end

function M.get()
  return vim.deepcopy(entries)
end

function M.clear()
  entries = {}
end

function M._reset()
  entries = {}
  next_id = 1
end

return M
