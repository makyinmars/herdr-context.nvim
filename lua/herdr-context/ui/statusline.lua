local M = {}

local config = require("herdr-context.config")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")

local cached = ""
local subscriber

function M.render(cfg, current)
  if not cfg.presence.enabled then
    return ""
  end

  local options = cfg.statusline
  local icons = options.icons
  local agents = targets.candidates(current, { scope = cfg.target_scope })
  local count = #agents
  local parts = {}
  if not options.compact and icons.herdr ~= "" then
    parts[#parts + 1] = icons.herdr
  end

  if options.show_connection and not current.connected then
    parts[#parts + 1] = icons.disconnected
    if not current.stale or #current.agents == 0 then
      if not options.compact then
        parts[#parts + 1] = "disconnected"
      end
      return table.concat(parts, " ")
    end
  end

  local target
  for _, agent in ipairs(agents) do
    if agent.pane_id == current.target_pane_id then
      target = agent
      break
    end
  end
  local target_rendered = false
  if options.show_target and target then
    target_rendered = true
    local status = target.agent_status or "unknown"
    if status == "blocked" then
      parts[#parts + 1] = icons.blocked
      if not options.compact then
        parts[#parts + 1] = "blocked"
      end
    else
      parts[#parts + 1] = icons.target
      parts[#parts + 1] = icons[status] or icons.unknown
      parts[#parts + 1] = target.display_agent or target.agent or "agent"
    end
  elseif count == 0 or options.show_target then
    parts[#parts + 1] = icons.unknown
  end

  if options.show_agent_count then
    if target_rendered then
      parts[#parts + 1] = icons.separator
    end
    parts[#parts + 1] = tostring(count)
  end

  return table.concat(parts, " ")
end

local function refresh(current)
  cached = M.render(config.get(), current or state.get())
end

function M.setup()
  if subscriber then
    state.unsubscribe(subscriber)
  end
  subscriber = function(current)
    refresh(current)
  end
  state.subscribe(subscriber)
  refresh()
end

function M.get()
  if not subscriber then
    M.setup()
  end
  return cached
end

return M
