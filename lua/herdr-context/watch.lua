local M = {}

local config_module = require("herdr-context.config")
local herdr = require("herdr-context.herdr")
local socket = require("herdr-context.socket")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")

local uv = vim.uv or vim.loop

local base_subscriptions = {
  "pane.agent_detected",
  "pane.created",
  "pane.updated",
  "pane.closed",
  "pane.moved",
  "pane.exited",
  "pane.focused",
  "tab.created",
  "tab.closed",
  "tab.focused",
  "tab.renamed",
  "tab.moved",
  "workspace.created",
  "workspace.updated",
  "workspace.metadata_updated",
  "workspace.focused",
  "workspace.renamed",
  "workspace.moved",
  "workspace.closed",
  "layout.updated",
}

local active = false
local generation = 0
local socket_generation = 0
local cfg
local dependencies
local client
local status_clients = {}
local socket_ready = false
local debounce_timer
local poll_timer
local reconnect_timer
local reconnect_delay = 500
local request_number = 0
local augroup
local reconcile_status_clients
local debounce_refresh
local socket_failed
local syncing = false
local event_buffer = {}
local snapshot_inflight = false
local sync_followup_pending = false
local bootstrap_pending = false

local function close_timer(timer)
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
end

local function stop_polling()
  close_timer(poll_timer)
  poll_timer = nil
end

local function stop_reconnect()
  close_timer(reconnect_timer)
  reconnect_timer = nil
end

local function version_at_least(version, major, minor)
  local current_major, current_minor = tostring(version or ""):match("^(%d+)%.(%d+)")
  current_major, current_minor = tonumber(current_major), tonumber(current_minor)
  if not current_major then
    return false
  end
  return current_major > major or (current_major == major and current_minor >= minor)
end

local function subscriptions()
  local result = {}
  for _, event_type in ipairs(base_subscriptions) do
    result[#result + 1] = { type = event_type }
  end
  if version_at_least(state.get().version, 0, 8) then
    result[#result + 1] = { type = "workspace.reordered" }
  end
  return result
end

local connect_socket

local function socket_requested()
  return cfg.presence.socket and vim.env.HERDR_SOCKET_PATH and vim.env.HERDR_SOCKET_PATH ~= ""
end

local function close_status_clients()
  for pane_id, status_client in pairs(status_clients) do
    status_client:close({ silent = true, reason = "replace" })
    status_clients[pane_id] = nil
  end
end

local function refresh_snapshot(opts, done)
  local expected_generation = generation
  local expected_socket_generation = socket_generation
  snapshot_inflight = true
  if socket_ready and not syncing then
    syncing = true
    event_buffer = {}
  end
  dependencies.snapshot(cfg, function(raw, err)
    if not active or expected_generation ~= generation then
      return
    end
    snapshot_inflight = false
    if not raw then
      state._set_connection({
        connected = socket_ready,
        stale = true,
        mode = socket_ready and "socket" or "disconnected",
      })
      done(nil, err)
      if socket_ready and expected_socket_generation == socket_generation then
        socket_failed(expected_socket_generation)
      end
      return
    end

    local mode = socket_ready and "socket" or "polling"
    local defer_socket_sync = socket_ready and sync_followup_pending and not opts.socket_sync
    local _, public = state._replace(raw, {
      connected = true,
      stale = defer_socket_sync,
      mode = mode,
    })
    if not defer_socket_sync then
      local buffered = event_buffer
      event_buffer = {}
      syncing = false
      for _, event in ipairs(buffered) do
        local _, event_err = state._apply_event(event, { connected = true, stale = false, mode = "socket" })
        if event_err then
          done(nil, event_err)
          socket_failed(expected_socket_generation)
          return
        end
        if (event.event == "pane_moved" or event.event == "pane.moved") and event.data and event.data.pane then
          local _, migrate_err = targets.migrate(event.data.previous_pane_id, event.data.pane)
          if migrate_err then
            vim.notify("herdr-context: " .. migrate_err, vim.log.levels.WARN)
          end
        end
      end
    end
    public = state.get()
    local should_connect = bootstrap_pending and socket_requested()
    if should_connect then
      bootstrap_pending = false
    end
    done(public, nil)
    if should_connect then
      connect_socket(false)
    elseif socket_ready and not defer_socket_sync and reconcile_status_clients then
      reconcile_status_clients()
    end
  end)
end

local function poll_once()
  if not active or socket_ready then
    return
  end
  state.refresh({}, function() end)
end

local function start_polling(immediate)
  if not active then
    return
  end
  if poll_timer then
    if immediate then
      poll_once()
    end
    return
  end
  poll_timer = uv.new_timer()
  poll_timer:start(cfg.presence.poll_interval_ms, cfg.presence.poll_interval_ms, function()
    vim.schedule(poll_once)
  end)
  if immediate then
    poll_once()
  end
end

local function schedule_reconnect()
  if reconnect_timer or not active or not cfg.presence.socket or not vim.env.HERDR_SOCKET_PATH then
    return
  end
  local delay = reconnect_delay
  reconnect_delay = math.min(reconnect_delay * 2, cfg.presence.reconnect_max_ms)
  reconnect_timer = uv.new_timer()
  reconnect_timer:start(delay, 0, function()
    vim.schedule(function()
      stop_reconnect()
      if active and not socket_ready then
        connect_socket(true)
      end
    end)
  end)
end

socket_failed = function(expected_socket_generation)
  if not active or expected_socket_generation ~= socket_generation then
    return
  end
  socket_ready = false
  syncing = false
  event_buffer = {}
  sync_followup_pending = false
  close_status_clients()
  if client then
    client:close({ silent = true, reason = "reconnect" })
    client = nil
  end
  state._set_connection({
    connected = false,
    stale = true,
    mode = "polling",
  })
  start_polling(true)
  schedule_reconnect()
end

debounce_refresh = function()
  if not active then
    return
  end
  if socket_ready and not syncing then
    syncing = true
    event_buffer = {}
  end
  if not debounce_timer then
    debounce_timer = uv.new_timer()
  end
  debounce_timer:stop()
  debounce_timer:start(cfg.presence.debounce_ms, 0, function()
    vim.schedule(function()
      if active then
        state.refresh({}, function() end)
      end
    end)
  end)
end

local function apply_event(message)
  if syncing then
    event_buffer[#event_buffer + 1] = message
    return true
  end
  local _, err = state._apply_event(message, { connected = true, stale = false, mode = "socket" })
  if err then
    debounce_refresh()
    return false
  end
  if (message.event == "pane_moved" or message.event == "pane.moved") and message.data and message.data.pane then
    local _, migrate_err = targets.migrate(message.data.previous_pane_id, message.data.pane)
    if migrate_err then
      vim.notify("herdr-context: " .. migrate_err, vim.log.levels.WARN)
    end
  end
  reconcile_status_clients()
  return true
end

local function connect_status_client(pane_id)
  request_number = request_number + 1
  local request_id = "herdr-context:status:" .. tostring(request_number)
  local expected_socket_generation = socket_generation
  local status_client
  status_client = dependencies.socket_new({
    path = vim.env.HERDR_SOCKET_PATH,
    on_connect = function()
      if not active or not socket_ready or expected_socket_generation ~= socket_generation then
        return
      end
      status_client:write({
        id = request_id,
        method = "events.subscribe",
        params = {
          subscriptions = {
            { type = "pane.agent_status_changed", pane_id = pane_id, agent_status = "idle" },
            { type = "pane.agent_status_changed", pane_id = pane_id, agent_status = "working" },
            { type = "pane.agent_status_changed", pane_id = pane_id, agent_status = "blocked" },
            { type = "pane.agent_status_changed", pane_id = pane_id, agent_status = "done" },
            { type = "pane.agent_status_changed", pane_id = pane_id, agent_status = "unknown" },
          },
        },
      })
    end,
    on_message = function(message)
      if not active or not socket_ready or expected_socket_generation ~= socket_generation then
        return
      end
      if message.id == request_id then
        if message.error or not (message.result and message.result.type == "subscription_started") then
          status_clients[pane_id] = nil
          status_client:close({ silent = true, reason = "subscription_failed" })
          debounce_refresh()
        end
        return
      end
      if message.event then
        apply_event(message)
      end
    end,
    on_error = function()
      if status_clients[pane_id] == status_client then
        status_clients[pane_id] = nil
        debounce_refresh()
      end
    end,
    on_close = function()
      if status_clients[pane_id] == status_client then
        status_clients[pane_id] = nil
        debounce_refresh()
      end
    end,
  })
  status_clients[pane_id] = status_client
  status_client:connect()
end

reconcile_status_clients = function()
  if not active or not socket_ready then
    return
  end
  local current = state.get()
  for pane_id, status_client in pairs(status_clients) do
    if not current.agents_by_pane[pane_id] then
      status_client:close({ silent = true, reason = "agent_removed" })
      status_clients[pane_id] = nil
    end
  end
  for pane_id in pairs(current.agents_by_pane) do
    if not status_clients[pane_id] then
      connect_status_client(pane_id)
    end
  end
end

connect_socket = function(restarting)
  if not active or not cfg.presence.socket or not vim.env.HERDR_SOCKET_PATH then
    return
  end

  socket_generation = socket_generation + 1
  local current_socket_generation = socket_generation
  socket_ready = false
  syncing = true
  event_buffer = {}
  stop_reconnect()
  close_status_clients()
  if client then
    client:close({ silent = true, reason = "replace" })
  end

  start_polling(false)
  request_number = request_number + 1
  local request_id = "herdr-context:" .. tostring(request_number)
  client = dependencies.socket_new({
    path = vim.env.HERDR_SOCKET_PATH,
    on_connect = function()
      if not active or current_socket_generation ~= socket_generation then
        return
      end
      client:write({
        id = request_id,
        method = "events.subscribe",
        params = { subscriptions = subscriptions() },
      })
    end,
    on_message = function(message)
      if not active or current_socket_generation ~= socket_generation then
        return
      end
      if message.id == request_id then
        if message.error or not (message.result and message.result.type == "subscription_started") then
          socket_failed(current_socket_generation)
          return
        end
        socket_ready = true
        reconnect_delay = math.min(500, cfg.presence.reconnect_max_ms)
        stop_polling()
        state._set_connection({
          connected = true,
          stale = true,
          mode = "socket",
        })
        local function run_socket_sync()
          if not active or not socket_ready or current_socket_generation ~= socket_generation then
            return
          end
          sync_followup_pending = false
          state.refresh({ force = true, socket_sync = true }, function() end)
        end
        if snapshot_inflight then
          sync_followup_pending = true
          state.refresh({}, function(_, err)
            if not err then
              run_socket_sync()
            end
          end)
        else
          run_socket_sync()
        end
        return
      end
      if message.event then
        apply_event(message)
      end
    end,
    on_error = function()
      socket_failed(current_socket_generation)
    end,
    on_close = function()
      socket_failed(current_socket_generation)
    end,
  })
  if restarting then
    state._set_connection({ connected = false, stale = true, mode = "polling" })
    start_polling(false)
  end
  client:connect()
end

function M.start(options, opts)
  options = options or config_module.get()
  opts = opts or {}
  M.stop({ silent = true })

  cfg = options
  dependencies = {
    snapshot = opts.snapshot or herdr.snapshot,
    socket_new = opts.socket_new or socket.new,
  }
  active = true
  generation = generation + 1
  reconnect_delay = math.min(500, cfg.presence.reconnect_max_ms)
  socket_ready = false
  status_clients = {}
  syncing = false
  event_buffer = {}
  snapshot_inflight = false
  sync_followup_pending = false
  bootstrap_pending = socket_requested()
  state._set_enabled(cfg.presence.enabled)

  if not cfg.presence.enabled then
    active = false
    state._set_refresher(nil)
    state._set_connection({ connected = false, stale = false, mode = "disconnected" })
    return
  end

  state._set_refresher(refresh_snapshot)
  augroup = vim.api.nvim_create_augroup("HerdrContextPresence", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      M.stop({ silent = true })
    end,
  })

  if vim.env.HERDR_ENV ~= "1" then
    state._set_connection({ connected = false, stale = false, mode = "disconnected" })
    return
  end

  state.refresh({ force = true }, function(_, err)
    if not active then
      return
    end
    if err then
      start_polling(true)
    elseif not socket_requested() then
      start_polling(false)
    end
  end)
end

function M.stop(opts)
  opts = opts or {}
  active = false
  generation = generation + 1
  socket_ready = false
  syncing = false
  event_buffer = {}
  snapshot_inflight = false
  sync_followup_pending = false
  bootstrap_pending = false
  close_status_clients()
  close_timer(debounce_timer)
  debounce_timer = nil
  stop_polling()
  stop_reconnect()
  if client then
    client:close({ silent = true, reason = "shutdown" })
    client = nil
  end
  state._set_refresher(nil)
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  if not opts.silent and state.enabled() then
    state._set_connection({ connected = false, stale = true, mode = "disconnected" })
  end
end

function M.running()
  return active
end

function M._debounce_refresh()
  debounce_refresh()
end

return M
