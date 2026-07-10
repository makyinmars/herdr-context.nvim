local M = {}

local config_module = require("herdr-context.config")
local herdr = require("herdr-context.herdr")
local socket = require("herdr-context.socket")
local state = require("herdr-context.state")

local uv = vim.uv or vim.loop

local static_subscriptions = {
  "pane.agent_detected",
  "pane.created",
  "pane.closed",
  "pane.moved",
  "pane.exited",
  "tab.renamed",
  "tab.moved",
  "workspace.renamed",
  "workspace.moved",
  "workspace.closed",
}

local active = false
local generation = 0
local cfg
local dependencies
local client
local socket_ready = false
local subscribed_signature
local debounce_timer
local poll_timer
local reconnect_timer
local reconnect_delay = 500
local request_number = 0
local augroup

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

local function signature(current)
  local panes = {}
  for pane_id in pairs(current.agents_by_pane or {}) do
    panes[#panes + 1] = pane_id
  end
  table.sort(panes)
  return table.concat(panes, "\0")
end

local function subscriptions(current)
  local result = {}
  for _, event_type in ipairs(static_subscriptions) do
    result[#result + 1] = { type = event_type }
  end
  for pane_id in pairs(current.agents_by_pane or {}) do
    result[#result + 1] = {
      type = "pane.agent_status_changed",
      pane_id = pane_id,
    }
  end
  return result
end

local connect_socket

local function restart_for_agent_set()
  if not active or not socket_ready or signature(state.get()) == subscribed_signature then
    return
  end
  connect_socket(true)
end

local function refresh_snapshot(opts, done)
  dependencies.snapshot(cfg, function(raw, err)
    if not active then
      return
    end
    if not raw then
      state._set_connection({
        connected = socket_ready,
        stale = true,
        mode = socket_ready and "socket" or "disconnected",
      })
      done(nil, err)
      return
    end

    local mode = socket_ready and "socket" or "polling"
    local _, public = state._replace(raw, {
      connected = true,
      stale = false,
      mode = mode,
    })
    done(public, nil)
    restart_for_agent_set()
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
        connect_socket()
      end
    end)
  end)
end

local function socket_failed(expected_generation)
  if not active or expected_generation ~= generation then
    return
  end
  socket_ready = false
  subscribed_signature = nil
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

local function debounce_refresh()
  if not active then
    return
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

connect_socket = function(restarting)
  if not active or not cfg.presence.socket or not vim.env.HERDR_SOCKET_PATH then
    return
  end

  generation = generation + 1
  local current_generation = generation
  socket_ready = false
  stop_reconnect()
  if client then
    client:close({ silent = true, reason = "replace" })
  end

  local current = state.get()
  subscribed_signature = signature(current)
  start_polling(false)
  request_number = request_number + 1
  local request_id = "herdr-context:" .. tostring(request_number)
  client = dependencies.socket_new({
    path = vim.env.HERDR_SOCKET_PATH,
    on_connect = function()
      if not active or current_generation ~= generation then
        return
      end
      client:write({
        id = request_id,
        method = "events.subscribe",
        params = { subscriptions = subscriptions(current) },
      })
    end,
    on_message = function(message)
      if not active or current_generation ~= generation then
        return
      end
      if message.id == request_id then
        if message.error or not (message.result and message.result.type == "subscription_started") then
          socket_failed(current_generation)
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
        state.refresh({ force = true }, function() end)
        return
      end
      if message.event then
        debounce_refresh()
      end
    end,
    on_error = function()
      socket_failed(current_generation)
    end,
    on_close = function()
      socket_failed(current_generation)
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
  subscribed_signature = nil
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
    if cfg.presence.socket and vim.env.HERDR_SOCKET_PATH and vim.env.HERDR_SOCKET_PATH ~= "" then
      connect_socket()
    else
      start_polling(err ~= nil)
    end
  end)
end

function M.stop(opts)
  opts = opts or {}
  active = false
  generation = generation + 1
  socket_ready = false
  subscribed_signature = nil
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
