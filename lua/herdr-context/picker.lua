local M = {}

local display = require("herdr-context.agent_display")

function M.format_item(target)
  return display.picker_item(target)
end

function M.select(candidates, callback)
  vim.ui.select(candidates, {
    prompt = "Herdr target agent",
    format_item = M.format_item,
  }, callback)
end

return M
