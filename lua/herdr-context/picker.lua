local M = {}

local status_icons = {
  idle = "●",
  working = "◉",
  blocked = "!",
  done = "✓",
  unknown = "○",
}

local function shorten(path)
  if not path or path == "" then
    return "?"
  end
  return vim.fn.fnamemodify(path, ":~")
end

function M.format_item(target)
  local status = target.agent_status or "unknown"
  local status_label = type(target.state_labels) == "table" and target.state_labels[status] or nil
  return ("%s %-8s %-8s %s / %s   %s   %s"):format(
    status_icons[status] or "○",
    status_label or status,
    target.display_agent or target.agent or "agent",
    target.workspace_label or target.workspace_id or "?",
    target.tab_label or target.tab_id or "?",
    shorten(target.foreground_cwd or target.cwd),
    target.pane_id
  )
end

function M.select(candidates, callback)
  vim.ui.select(candidates, {
    prompt = "Herdr target agent",
    format_item = M.format_item,
  }, callback)
end

return M
