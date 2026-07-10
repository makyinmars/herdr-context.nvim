if vim.env.HERDR_LIVE_TEST ~= "1" then
  error("Set HERDR_LIVE_TEST=1 to run the read-only Herdr integration test")
end

local plugin = require("herdr-context")
local config = plugin.setup({ target_scope = "session" })
local herdr = require("herdr-context.herdr")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")

assert(
  vim.wait(5000, function()
    local current = state.get()
    local has_socket = vim.env.HERDR_SOCKET_PATH and vim.env.HERDR_SOCKET_PATH ~= ""
    local expected_mode = has_socket and "socket" or "polling"
    return current.connected and not current.stale and current.mode == expected_mode
  end),
  "presence watcher did not produce a fresh connected snapshot: " .. vim.inspect(state.get())
)

local snapshot, err = herdr.snapshot(config)
assert(snapshot, err)
assert(type(snapshot.protocol) == "number", "snapshot is missing a protocol number")
assert(type(snapshot.agents) == "table", "snapshot is missing agents")

local candidates = targets.candidates(snapshot, { scope = "session" })
if candidates[1] then
  local agent, get_err = herdr.get_agent(config, candidates[1].pane_id)
  assert(agent, get_err)
  assert(agent.pane_id == candidates[1].pane_id, "agent.get returned a different pane")
end

print(
  ("live Herdr %s protocol %s via %s: %d target(s)"):format(
    snapshot.version or "?",
    snapshot.protocol,
    state.get().mode,
    #candidates
  )
)
require("herdr-context.watch").stop({ silent = true })
vim.cmd("qa!")
