local M = {}

local composer = require("herdr-context.composer")
local config = require("herdr-context.config")
local herdr = require("herdr-context.herdr")
local history = require("herdr-context.history")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")
local transport = require("herdr-context.transport")

local placements = {
  { id = "split", label = "Split the current tab" },
  { id = "tab", label = "Create a new tab" },
  { id = "workspace", label = "Create a new workspace" },
}

local tracking_choices = {
  { wait = false, label = "Send and continue without waiting" },
  { wait = true, label = "Wait and preview the result" },
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "herdr-context.nvim" })
end

local function choose(items, prompt, format_item, selected, callback)
  if selected ~= nil then
    callback(selected)
    return
  end
  vim.ui.select(items, { prompt = prompt, format_item = format_item }, function(choice)
    callback(choice)
  end)
end

local function used_names(snapshot)
  local used = {}
  for _, agent in ipairs((snapshot and snapshot.agents) or {}) do
    if agent.name then
      used[agent.name] = true
    end
  end
  return used
end

local function name_base(requested)
  local base = tostring(requested or "reviewer"):lower():gsub("[^a-z0-9_-]", "-"):gsub("^[^a-z]+", "")
  base = base:sub(1, 32)
  if base == "" then
    base = "reviewer"
  end
  return base
end

local function unique_name(base, used)
  if not used[base] then
    return base
  end
  local index = 2
  while true do
    local suffix = "-" .. tostring(index)
    local candidate = base:sub(1, 32 - #suffix) .. suffix
    if not used[candidate] then
      return candidate
    end
    index = index + 1
  end
end

local function error_message(err)
  if type(err) == "table" then
    return err.message or err.code or vim.inspect(err)
  end
  return tostring(err)
end

local function placement_by_id(id)
  for _, item in ipairs(placements) do
    if item.id == id then
      return item
    end
  end
end

function M.execute(operation, opts, callback)
  opts = opts or {}
  operation = vim.deepcopy(operation)
  local cfg = config.get()
  local selected_placement = opts.placement and placement_by_id(opts.placement) or nil
  choose(
    placements,
    "Create delegated agent in:",
    function(item)
      return item.label
    end,
    selected_placement,
    function(placement)
      if not placement or (opts.cancelled and opts.cancelled()) then
        callback(nil, "Delegation cancelled")
        return
      end
      local selected_tracking = opts.wait ~= nil and { wait = opts.wait } or nil
      choose(
        tracking_choices,
        "After submitting context:",
        function(item)
          return item.label
        end,
        selected_tracking,
        function(tracking)
          if not tracking or (opts.cancelled and opts.cancelled()) then
            callback(nil, "Delegation cancelled")
            return
          end
          if opts.on_committed then
            opts.on_committed(placement.id, tracking.wait)
          end
          herdr.snapshot(cfg, function(snapshot, snapshot_err)
            if not snapshot then
              callback(nil, "Could not inspect live agents before delegation: " .. error_message(snapshot_err))
              return
            end
            local base = name_base(opts.name)
            local names = used_names(snapshot)
            local name = unique_name(base, names)
            herdr.create_pane(cfg, placement.id, {
              cwd = operation.cwd,
              direction = opts.direction,
              label = opts.label or opts.preset or name,
              workspace_id = vim.env.HERDR_WORKSPACE_ID or state.get().focused_workspace_id,
            }, function(pane, create_err)
              if not pane then
                callback(nil, "Could not create delegation pane: " .. error_message(create_err))
                return
              end

              local function start_agent()
                herdr.start_agent(cfg, name, opts.kind, pane.pane_id, {
                  timeout_ms = opts.startup_timeout_ms,
                  args = opts.agent_args,
                }, function(agent, start_err)
                  if not agent and type(start_err) == "table" and start_err.code == "agent_name_taken" then
                    names[name] = true
                    name = unique_name(base, names)
                    start_agent()
                    return
                  end
                  if not agent then
                    local detail
                    if type(start_err) == "table" and start_err.code == "timeout" then
                      detail = ("Created pane %s, but agent startup timed out; the pane and any launched process were retained"):format(
                        pane.pane_id
                      )
                    else
                      detail = ("Created pane %s, but could not start the delegated agent: %s; the pane was retained"):format(
                        pane.pane_id,
                        error_message(start_err)
                      )
                    end
                    callback(nil, detail)
                    return
                  end
                  local remembered, remember_err = targets.remember(cfg, agent)
                  if not remembered then
                    notify(remember_err, vim.log.levels.WARN)
                  end
                  if opts.on_started then
                    opts.on_started(agent, placement.id, tracking.wait)
                  end
                  transport.stage(cfg, agent, operation.payload, function(ok, stage_err, transport_result)
                    if not ok then
                      callback(
                        nil,
                        ("Started %s in pane %s, but %s; the agent was retained"):format(
                          name,
                          pane.pane_id,
                          error_message(stage_err)
                        )
                      )
                      return
                    end
                    callback({
                      agent = agent,
                      name = name,
                      kind = opts.kind,
                      pane = pane,
                      placement = placement.id,
                      transport = transport_result,
                    })
                  end, {
                    submit = true,
                    wait = tracking.wait,
                    timeout_ms = tracking.wait and opts.timeout_ms or nil,
                  })
                end)
              end
              start_agent()
            end)
          end)
        end
      )
    end
  )
end

local function operation_for(session)
  return {
    cwd = session.request.cwd,
    payload = session.bundle.payload,
    bytes = session.bundle.bytes,
    providers = session:selected_ids(),
    instruction = session.instruction,
    preset = session.preset,
  }
end

local function complete(operation, opts, result)
  local target = result.agent
  local tracked = result.transport.tracked
  local status = result.transport.status
  history.record({
    kind = "delegate",
    target = target,
    payload = operation.payload,
    bytes = operation.bytes,
    providers = operation.providers,
    instruction = operation.instruction,
    preset = operation.preset,
    mode = result.transport.mode,
    submitted = result.transport.submitted,
    tracked = tracked,
    status = status,
    placement = result.placement,
  })
  if result.transport.tracking_error then
    notify(result.transport.tracking_message, vim.log.levels.WARN)
  elseif tracked then
    notify(("Delegated %s reached %s"):format(result.name, status or "a settled state"))
  else
    notify(("Delegated context to %s (%s)"):format(result.name, target.pane_id))
  end
  if tracked and (opts.preview_result ~= false or status == "blocked") then
    vim.schedule(function()
      require("herdr-context.ui.preview").open(result.transport.agent or target)
    end)
  end
end

function M.open(opts)
  opts = opts or {}
  local session
  opts = vim.deepcopy(opts)
  opts.target_label = ("new %s agent"):format(opts.kind)
  opts.stage_handler = function(current)
    if current.delegating then
      return
    end
    current.delegating = true
    local operation = operation_for(current)
    local execute_opts = vim.tbl_extend("force", opts, {
      cancelled = function()
        return current.closed
      end,
      on_committed = function()
        current:close()
      end,
      on_started = function(agent, placement, wait)
        notify(
          ("Started %s (%s) in a new %s%s"):format(
            agent.name or opts.name or "delegated agent",
            agent.pane_id,
            placement,
            wait and "; waiting for its result…" or ""
          )
        )
      end,
    })
    M.execute(operation, execute_opts, function(result, err)
      current.delegating = false
      if not result then
        if err ~= "Delegation cancelled" then
          notify(err, vim.log.levels.ERROR)
        end
        return
      end
      complete(operation, execute_opts, result)
    end)
  end
  session = composer.open(opts)
  return session
end

M.placements = placements
M.tracking_choices = tracking_choices
M._unique_name = function(requested, snapshot)
  return unique_name(name_base(requested), used_names(snapshot or {}))
end
M._operation_for = operation_for
M._complete = complete

return M
