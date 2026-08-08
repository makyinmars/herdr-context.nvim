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
  panes = {},
  layouts = {},
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
  local panes = vim.deepcopy(raw.panes or {})
  local layouts = vim.deepcopy(raw.layouts or {})
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
    panes = panes,
    layouts = layouts,
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

local function find_index(records, key, value)
  for index, record in ipairs(records or {}) do
    if record[key] == value then
      return index
    end
  end
end

local function find_record(records, key, value)
  local index = find_index(records, key, value)
  return index and records[index] or nil
end

local function upsert(records, key, record)
  local index = find_index(records, key, record[key])
  if index then
    records[index] = vim.deepcopy(record)
  else
    records[#records + 1] = vim.deepcopy(record)
  end
end

local function remove(records, key, value)
  local index = find_index(records, key, value)
  if index then
    table.remove(records, index)
    return true
  end
  return false
end

local function remove_where(records, predicate)
  local removed = false
  for index = #records, 1, -1 do
    if predicate(records[index]) then
      table.remove(records, index)
      removed = true
    end
  end
  return removed
end

local function agent_for_pane(raw, pane, previous_pane_id)
  local previous = find_record(raw.agents, "pane_id", previous_pane_id or pane.pane_id)
  if not previous and pane.terminal_id then
    previous = find_record(raw.agents, "terminal_id", pane.terminal_id)
  end
  remove(raw.agents, "pane_id", previous_pane_id or pane.pane_id)
  if previous and previous.pane_id ~= pane.pane_id then
    remove(raw.agents, "pane_id", previous.pane_id)
  end
  if not pane.agent then
    return
  end
  local agent = {}
  for _, field in ipairs({
    "name",
    "screen_detection_skipped",
    "launch_pending",
    "interactive_ready",
    "state_change_seq",
  }) do
    if previous and previous[field] ~= nil then
      agent[field] = vim.deepcopy(previous[field])
    end
  end
  for field, value in pairs(pane) do
    agent[field] = vim.deepcopy(value)
  end
  agent.state_labels = vim.deepcopy(pane.state_labels or {})
  agent.tokens = vim.deepcopy(pane.tokens or {})
  upsert(raw.agents, "pane_id", agent)
end

local function upsert_pane(raw, pane, previous_pane_id)
  if type(pane) ~= "table" or not pane.pane_id then
    return nil, "pane event did not contain a complete pane"
  end
  local previous = find_record(raw.panes, "pane_id", previous_pane_id or pane.pane_id)
  if
    previous
    and previous.terminal_id
    and pane.terminal_id == previous.terminal_id
    and type(previous.revision) == "number"
    and type(pane.revision) == "number"
    and pane.revision < previous.revision
  then
    return nil, "pane revision moved backwards"
  end
  if previous_pane_id then
    remove(raw.panes, "pane_id", previous_pane_id)
  end
  upsert(raw.panes, "pane_id", pane)
  agent_for_pane(raw, pane, previous_pane_id)
  return true
end

local function patch_record(records, key, value, patch)
  local record = find_record(records, key, value)
  if not record then
    return nil
  end
  for field, updated in pairs(patch) do
    if updated ~= nil then
      record[field] = vim.deepcopy(updated)
    end
  end
  return record
end

local function remove_pane(raw, pane_id, remove_resource)
  if remove_resource then
    remove(raw.panes, "pane_id", pane_id)
  end
  remove(raw.agents, "pane_id", pane_id)
end

local function remove_tab(raw, tab_id)
  local removed_tab = find_record(raw.tabs, "tab_id", tab_id)
  local workspace_tabs = {}
  local removed_position
  if removed_tab then
    for _, tab in ipairs(raw.tabs) do
      if tab.workspace_id == removed_tab.workspace_id then
        workspace_tabs[#workspace_tabs + 1] = tab
        if tab.tab_id == tab_id then
          removed_position = #workspace_tabs
        end
      end
    end
  end
  remove(raw.tabs, "tab_id", tab_id)
  remove_where(raw.panes, function(pane)
    return pane.tab_id == tab_id
  end)
  remove_where(raw.agents, function(agent)
    return agent.tab_id == tab_id
  end)
  remove_where(raw.layouts, function(layout)
    return layout.tab_id == tab_id
  end)
  local workspace = removed_tab and find_record(raw.workspaces, "workspace_id", removed_tab.workspace_id) or nil
  if workspace and workspace.active_tab_id == tab_id then
    table.remove(workspace_tabs, removed_position)
    local replacement = workspace_tabs[math.min(removed_position, #workspace_tabs)]
    workspace.active_tab_id = replacement and replacement.tab_id or nil
  end
end

local function remove_workspace(raw, workspace_id)
  remove(raw.workspaces, "workspace_id", workspace_id)
  remove_where(raw.tabs, function(tab)
    return tab.workspace_id == workspace_id
  end)
  remove_where(raw.panes, function(pane)
    return pane.workspace_id == workspace_id
  end)
  remove_where(raw.agents, function(agent)
    return agent.workspace_id == workspace_id
  end)
  remove_where(raw.layouts, function(layout)
    return layout.workspace_id == workspace_id
  end)
end

local wire_event_names = {
  pane_created = "pane.created",
  pane_updated = "pane.updated",
  pane_closed = "pane.closed",
  pane_exited = "pane.exited",
  pane_moved = "pane.moved",
  pane_focused = "pane.focused",
  pane_agent_detected = "pane.agent_detected",
  pane_agent_status_changed = "pane.agent_status_changed",
  workspace_created = "workspace.created",
  workspace_updated = "workspace.updated",
  workspace_metadata_updated = "workspace.metadata_updated",
  workspace_renamed = "workspace.renamed",
  workspace_moved = "workspace.moved",
  workspace_reordered = "workspace.reordered",
  workspace_closed = "workspace.closed",
  workspace_focused = "workspace.focused",
  tab_created = "tab.created",
  tab_renamed = "tab.renamed",
  tab_moved = "tab.moved",
  tab_closed = "tab.closed",
  tab_focused = "tab.focused",
  layout_updated = "layout.updated",
}

local status_priority = {
  blocked = 1,
  done = 2,
  working = 3,
  idle = 4,
  unknown = 5,
}

local function aggregate_status(agents)
  local status = "unknown"
  for _, agent in ipairs(agents) do
    local candidate = agent.agent_status or "unknown"
    if (status_priority[candidate] or 99) < (status_priority[status] or 99) then
      status = candidate
    end
  end
  return status
end

local function reconcile_resources(raw)
  raw.focused_workspace_id = nil
  raw.focused_tab_id = nil
  raw.focused_pane_id = nil
  local panes_by_tab = {}
  local agents_by_tab = {}
  local agents_by_workspace = {}
  for _, pane in ipairs(raw.panes) do
    if pane.tab_id then
      panes_by_tab[pane.tab_id] = (panes_by_tab[pane.tab_id] or 0) + 1
    end
  end
  for _, agent in ipairs(raw.agents) do
    if agent.tab_id then
      agents_by_tab[agent.tab_id] = agents_by_tab[agent.tab_id] or {}
      agents_by_tab[agent.tab_id][#agents_by_tab[agent.tab_id] + 1] = agent
    end
    if agent.workspace_id then
      agents_by_workspace[agent.workspace_id] = agents_by_workspace[agent.workspace_id] or {}
      agents_by_workspace[agent.workspace_id][#agents_by_workspace[agent.workspace_id] + 1] = agent
    end
  end

  local tabs_by_workspace = {}
  for _, tab in ipairs(raw.tabs) do
    tab.pane_count = panes_by_tab[tab.tab_id] or 0
    tab.agent_status = aggregate_status(agents_by_tab[tab.tab_id] or {})
    tabs_by_workspace[tab.workspace_id] = tabs_by_workspace[tab.workspace_id] or {}
    tabs_by_workspace[tab.workspace_id][#tabs_by_workspace[tab.workspace_id] + 1] = tab
    if tab.focused then
      raw.focused_tab_id = tab.tab_id
    end
  end

  for _, workspace in ipairs(raw.workspaces) do
    local workspace_tabs = tabs_by_workspace[workspace.workspace_id] or {}
    workspace.tab_count = #workspace_tabs
    workspace.pane_count = 0
    workspace.agent_status = aggregate_status(agents_by_workspace[workspace.workspace_id] or {})
    for _, tab in ipairs(workspace_tabs) do
      workspace.pane_count = workspace.pane_count + tab.pane_count
      if tab.focused then
        workspace.active_tab_id = tab.tab_id
      end
    end
    if workspace.focused then
      raw.focused_workspace_id = workspace.workspace_id
    end
  end

  for _, pane in ipairs(raw.panes) do
    if pane.focused then
      raw.focused_pane_id = pane.pane_id
    end
  end
end

function M._apply_event(message, meta)
  local event = message and message.event
  local data = message and message.data or {}
  if type(event) ~= "string" or type(data) ~= "table" then
    return nil, "Herdr event did not contain event and data fields"
  end
  event = wire_event_names[event] or event

  local raw = M.get()
  raw.agents_by_pane = nil
  local known = true
  local ok, err = true, nil

  if event == "pane.created" or event == "pane.updated" then
    ok, err = upsert_pane(raw, data.pane)
  elseif event == "pane.closed" then
    if not data.pane_id then
      return nil, "pane.closed did not contain pane_id"
    end
    remove_pane(raw, data.pane_id, true)
  elseif event == "pane.exited" then
    if not data.pane_id then
      return nil, "pane.exited did not contain pane_id"
    end
    remove_pane(raw, data.pane_id, true)
  elseif event == "pane.moved" then
    if not data.previous_pane_id then
      return nil, "pane.moved did not contain previous_pane_id"
    end
    ok, err = upsert_pane(raw, data.pane, data.previous_pane_id)
    if not ok then
      return nil, err
    end
    if data.created_workspace then
      upsert(raw.workspaces, "workspace_id", data.created_workspace)
    end
    if data.created_tab then
      upsert(raw.tabs, "tab_id", data.created_tab)
    end
    if data.closed_tab_id then
      remove_tab(raw, data.closed_tab_id)
    end
    if data.closed_workspace_id then
      remove_workspace(raw, data.closed_workspace_id)
    end
  elseif event == "pane.focused" then
    local pane = data.pane_id and find_record(raw.panes, "pane_id", data.pane_id) or nil
    if not pane then
      return nil, "pane.focused referenced an unknown pane"
    end
    raw.focused_pane_id = pane.pane_id
    raw.focused_tab_id = pane.tab_id
    raw.focused_workspace_id = pane.workspace_id
    for _, candidate in ipairs(raw.panes) do
      candidate.focused = candidate.pane_id == pane.pane_id
    end
    for _, tab in ipairs(raw.tabs) do
      tab.focused = tab.tab_id == pane.tab_id
    end
    for _, workspace in ipairs(raw.workspaces) do
      workspace.focused = workspace.workspace_id == pane.workspace_id
      if workspace.focused then
        workspace.active_tab_id = pane.tab_id
      end
    end
  elseif event == "pane.agent_status_changed" then
    local agent = data.pane_id and find_record(raw.agents, "pane_id", data.pane_id) or nil
    if not agent then
      return nil, "agent status event referenced an unknown pane"
    end
    if not data.agent_status then
      return nil, "agent status event did not contain agent_status"
    end
    agent.agent_status = data.agent_status
    agent.agent = data.agent
    agent.title = data.title
    agent.display_agent = data.display_agent
    agent.state_labels = vim.deepcopy(data.state_labels or {})
    local pane = find_record(raw.panes, "pane_id", data.pane_id)
    if pane then
      pane.agent_status = data.agent_status
      pane.agent = data.agent
      pane.title = data.title
      pane.display_agent = data.display_agent
      pane.state_labels = vim.deepcopy(data.state_labels or {})
    end
  elseif event == "pane.agent_detected" then
    if data.released then
      remove(raw.agents, "pane_id", data.pane_id)
      local pane = data.pane_id and find_record(raw.panes, "pane_id", data.pane_id) or nil
      if pane then
        pane.agent = nil
        pane.agent_session = nil
        pane.title = nil
        pane.display_agent = nil
        pane.state_labels = {}
        pane.agent_status = data.final_status or "unknown"
      end
    else
      local pane = data.pane_id and find_record(raw.panes, "pane_id", data.pane_id) or nil
      if not pane then
        return nil, "agent detection event referenced an unknown pane"
      end
      pane.agent = data.agent or pane.agent
      agent_for_pane(raw, pane)
    end
  elseif event == "workspace.created" or event == "workspace.updated" or event == "workspace.metadata_updated" then
    if type(data.workspace) ~= "table" or not data.workspace.workspace_id then
      return nil, event .. " did not contain a complete workspace"
    end
    upsert(raw.workspaces, "workspace_id", data.workspace)
  elseif event == "workspace.renamed" then
    if not patch_record(raw.workspaces, "workspace_id", data.workspace_id, { label = data.label }) then
      return nil, "workspace.renamed referenced an unknown workspace"
    end
  elseif event == "workspace.moved" or event == "workspace.reordered" then
    if type(data.workspaces) ~= "table" then
      return nil, event .. " did not contain workspaces"
    end
    raw.workspaces = vim.deepcopy(data.workspaces)
  elseif event == "workspace.closed" then
    if not data.workspace_id then
      return nil, "workspace.closed did not contain workspace_id"
    end
    remove_workspace(raw, data.workspace_id)
  elseif event == "workspace.focused" then
    if not data.workspace_id or not find_record(raw.workspaces, "workspace_id", data.workspace_id) then
      return nil, "workspace.focused referenced an unknown workspace"
    end
    raw.focused_workspace_id = data.workspace_id
    for _, workspace in ipairs(raw.workspaces) do
      workspace.focused = workspace.workspace_id == data.workspace_id
    end
  elseif event == "tab.created" then
    if type(data.tab) ~= "table" or not data.tab.tab_id then
      return nil, "tab.created did not contain a complete tab"
    end
    upsert(raw.tabs, "tab_id", data.tab)
  elseif event == "tab.renamed" then
    if not patch_record(raw.tabs, "tab_id", data.tab_id, { label = data.label }) then
      return nil, "tab.renamed referenced an unknown tab"
    end
  elseif event == "tab.moved" then
    if type(data.tabs) ~= "table" or not data.workspace_id then
      return nil, "tab.moved did not contain tabs and workspace_id"
    end
    remove_where(raw.tabs, function(tab)
      return tab.workspace_id == data.workspace_id
    end)
    vim.list_extend(raw.tabs, vim.deepcopy(data.tabs))
  elseif event == "tab.closed" then
    if not data.tab_id then
      return nil, "tab.closed did not contain tab_id"
    end
    remove_tab(raw, data.tab_id)
  elseif event == "tab.focused" then
    if not data.tab_id or not find_record(raw.tabs, "tab_id", data.tab_id) then
      return nil, "tab.focused referenced an unknown tab"
    end
    raw.focused_tab_id = data.tab_id
    for _, tab in ipairs(raw.tabs) do
      tab.focused = tab.tab_id == data.tab_id
    end
    local workspace = find_record(raw.workspaces, "workspace_id", data.workspace_id)
    if workspace then
      workspace.active_tab_id = data.tab_id
    end
  elseif event == "layout.updated" then
    if type(data.layout) ~= "table" then
      return nil, "layout.updated did not contain a layout"
    end
    local key = data.layout.tab_id and "tab_id" or "layout_id"
    upsert(raw.layouts, key, data.layout)
  else
    known = false
  end

  if not known then
    return nil, "Unsupported Herdr event: " .. event
  end
  if not ok then
    return nil, err
  end
  reconcile_resources(raw)
  local _, public = M._replace(raw, meta or { connected = true, stale = false, mode = "socket" })
  return public, nil
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
    panes = {},
    layouts = {},
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
