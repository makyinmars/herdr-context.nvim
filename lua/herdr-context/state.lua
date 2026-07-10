local M = {}

local events = require("herdr-context.events")

local uv = vim.uv or vim.loop

local snapshot = {
  connected = false,
  stale = false,
  mode = "disconnected",
  version = nil,
  protocol = nil,
  updated_at = nil,
  focused_workspace_id = nil,
  focused_tab_id = nil,
  focused_pane_id = nil,
  workspaces = {},
  tabs = {},
  agents = {},
  agents_by_pane = {},
  target_pane_id = nil,
}

local enabled = true
local subscribers = {}
local refresher
local refreshing = false
local refresh_callbacks = {}

local function now()
  return uv.now and uv.now() or math.floor(os.time() * 1000)
end

local function notify()
  local public = vim.deepcopy(snapshot)
  for callback in pairs(subscribers) do
    local ok, err = pcall(callback, vim.deepcopy(public))
    if not ok then
      vim.schedule(function()
        vim.notify("herdr-context state subscriber failed: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
  events.emit("HerdrContextUpdated", public)
  events.redraw_statusline()
end

local function labels_by_id(records, key)
  local labels = {}
  for _, item in ipairs(records or {}) do
    if item[key] then
      labels[item[key]] = item.label
    end
  end
  return labels
end

local function normalize(raw, meta)
  raw = raw or {}
  meta = meta or {}
  local workspaces = vim.deepcopy(raw.workspaces or {})
  local tabs = vim.deepcopy(raw.tabs or {})
  local workspace_labels = labels_by_id(workspaces, "workspace_id")
  local tab_labels = labels_by_id(tabs, "tab_id")
  local agents = {}
  local agents_by_pane = {}

  for _, source in ipairs(raw.agents or {}) do
    if source.pane_id then
      local agent = vim.deepcopy(source)
      agent.agent_status = agent.agent_status or "unknown"
      agent.workspace_label = workspace_labels[agent.workspace_id] or agent.workspace_id
      agent.tab_label = tab_labels[agent.tab_id] or agent.tab_id
      agents[#agents + 1] = agent
      agents_by_pane[agent.pane_id] = agent
    end
  end

  table.sort(agents, function(a, b)
    return a.pane_id < b.pane_id
  end)

  return {
    connected = meta.connected == nil and snapshot.connected or meta.connected,
    stale = meta.stale == nil and snapshot.stale or meta.stale,
    mode = meta.mode or snapshot.mode,
    version = raw.version or snapshot.version,
    protocol = raw.protocol or snapshot.protocol,
    updated_at = now(),
    focused_workspace_id = raw.focused_workspace_id,
    focused_tab_id = raw.focused_tab_id,
    focused_pane_id = raw.focused_pane_id,
    workspaces = workspaces,
    tabs = tabs,
    agents = agents,
    agents_by_pane = agents_by_pane,
    target_pane_id = snapshot.target_pane_id,
  }
end

local function comparable(value)
  local copy = vim.deepcopy(value)
  copy.updated_at = nil
  return copy
end

local function emit_transitions(previous, current)
  if previous.connected ~= current.connected then
    events.emit(current.connected and "HerdrContextConnected" or "HerdrContextDisconnected", {
      mode = current.mode,
      stale = current.stale,
    })
  end

  for pane_id, agent in pairs(current.agents_by_pane) do
    local old = previous.agents_by_pane[pane_id]
    if old and old.agent_status ~= agent.agent_status then
      events.emit("HerdrContextAgentStatusChanged", {
        pane_id = pane_id,
        previous_status = old.agent_status,
        status = agent.agent_status,
      })
    end
  end
end

function M.get()
  return vim.deepcopy(snapshot)
end

function M.agents(opts)
  opts = opts or {}
  local scope = opts.scope or "session"
  local workspace_id = opts.workspace_id or vim.env.HERDR_WORKSPACE_ID or snapshot.focused_workspace_id
  local tab_id = opts.tab_id or vim.env.HERDR_TAB_ID or snapshot.focused_tab_id
  local pane_id = opts.pane_id or vim.env.HERDR_PANE_ID
  local result = {}

  for _, agent in ipairs(snapshot.agents) do
    local allowed = not opts.exclude_current or not pane_id or agent.pane_id ~= pane_id
    if scope == "workspace" then
      allowed = allowed and workspace_id ~= nil and agent.workspace_id == workspace_id
    elseif scope == "tab" then
      allowed = allowed and tab_id ~= nil and agent.tab_id == tab_id
    end
    if allowed then
      result[#result + 1] = vim.deepcopy(agent)
    end
  end

  return result
end

function M.subscribe(callback)
  vim.validate({ callback = { callback, "function" } })
  subscribers[callback] = true
  return callback
end

function M.unsubscribe(callback)
  subscribers[callback] = nil
end

function M.refresh(opts, callback)
  opts = opts or {}
  callback = callback or function() end
  if not refresher then
    vim.schedule(function()
      callback(nil, "Herdr presence is not running")
    end)
    return nil
  end

  refresh_callbacks[#refresh_callbacks + 1] = callback
  if refreshing then
    return nil
  end

  refreshing = true
  return refresher(opts, function(value, err)
    refreshing = false
    local callbacks = refresh_callbacks
    refresh_callbacks = {}
    for _, pending in ipairs(callbacks) do
      pending(value, err)
    end
  end)
end

function M.set_target(pane_id)
  if snapshot.target_pane_id == pane_id then
    return false
  end
  local previous = snapshot.target_pane_id
  snapshot.target_pane_id = pane_id
  events.emit("HerdrContextTargetChanged", {
    pane_id = pane_id,
    previous_pane_id = previous,
  })
  notify()
  return true
end

function M.enabled()
  return enabled
end

function M._set_enabled(value)
  enabled = value
end

function M._set_refresher(callback)
  refresher = callback
  if not callback then
    refreshing = false
    refresh_callbacks = {}
  end
end

function M._replace(raw, meta)
  local previous = snapshot
  local next_snapshot = normalize(raw, meta)
  local changed = not vim.deep_equal(comparable(previous), comparable(next_snapshot))
  snapshot = next_snapshot
  if changed then
    emit_transitions(previous, snapshot)
    notify()
  end
  return changed, M.get()
end

function M._set_connection(values)
  values = values or {}
  local previous = snapshot
  local next_snapshot = vim.deepcopy(snapshot)
  for _, key in ipairs({ "connected", "stale", "mode" }) do
    if values[key] ~= nil then
      next_snapshot[key] = values[key]
    end
  end
  next_snapshot.updated_at = now()
  local changed = not vim.deep_equal(comparable(previous), comparable(next_snapshot))
  snapshot = next_snapshot
  if changed then
    emit_transitions(previous, snapshot)
    notify()
  end
  return changed
end

function M._reset()
  snapshot = {
    connected = false,
    stale = false,
    mode = "disconnected",
    version = nil,
    protocol = nil,
    updated_at = nil,
    focused_workspace_id = nil,
    focused_tab_id = nil,
    focused_pane_id = nil,
    workspaces = {},
    tabs = {},
    agents = {},
    agents_by_pane = {},
    target_pane_id = nil,
  }
  refresher = nil
  refreshing = false
  refresh_callbacks = {}
  subscribers = {}
  enabled = true
end

return M
