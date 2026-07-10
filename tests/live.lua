if vim.env.HERDR_LIVE_TEST ~= "1" then
  error("Set HERDR_LIVE_TEST=1 to run the read-only Herdr integration test")
end

local config = require("herdr-context.config").setup({ target_scope = "session" })
local herdr = require("herdr-context.herdr")
local targets = require("herdr-context.targets")

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

print(("live Herdr %s protocol %s: %d target(s)"):format(snapshot.version or "?", snapshot.protocol, #candidates))
vim.cmd("qa!")
