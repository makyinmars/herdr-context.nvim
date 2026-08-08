local M = {}

local config = require("herdr-context.config")
local context = require("herdr-context.context")
local format = require("herdr-context.format")
local picker = require("herdr-context.picker")
local safety = require("herdr-context.safety")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")
local transport = require("herdr-context.transport")
local watch = require("herdr-context.watch")

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "herdr-context.nvim" })
end

local function capture(opts)
  local ok, result = pcall(context.capture, opts)
  if not ok then
    notify(result, vim.log.levels.ERROR)
    return nil
  end
  return result
end

local function stage(kind, opts)
  local cfg = config.get()
  local captured = capture(opts)
  if not captured then
    return
  end
  local excluded, pattern = safety.excluded_path(captured.relative_path, cfg.safety)
  if excluded then
    notify(
      ("Refusing to stage %s because it matches safety exclusion %q"):format(captured.relative_path, pattern),
      vim.log.levels.ERROR
    )
    return
  end

  local payload, err
  if kind == "reference" then
    payload, err = format.reference(captured)
  elseif kind == "content" then
    payload = format.content(captured)
  elseif kind == "diagnostics" then
    payload = format.diagnostics(captured, context.diagnostics(captured))
  else
    notify("Unknown context operation: " .. tostring(kind), vim.log.levels.ERROR)
    return
  end

  if not payload then
    notify(err, vim.log.levels.ERROR)
    return
  end
  payload, err = format.validate(payload, cfg.max_payload_bytes)
  if not payload then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local warnings = safety.scan({ { title = "Context", content = payload } }, cfg.safety)
  safety.confirm(warnings, function(confirmed)
    if not confirmed then
      return
    end
    targets.resolve(cfg, picker, {}, function(target, target_err)
      if not target then
        if target_err ~= "Target selection cancelled" then
          notify(target_err, vim.log.levels.ERROR)
        end
        return
      end

      transport.stage(cfg, target, payload, function(ok, transport_err, result)
        if not ok then
          notify(transport_err, vim.log.levels.ERROR)
          return
        end
        local suffix = result.mode == "context_file" and " via a temporary context file" or ""
        require("herdr-context.history").record({
          kind = kind,
          target = target,
          payload = payload,
          bytes = #payload,
          providers = {},
          mode = result.mode,
        })
        notify(("Staged context for %s (%s)%s"):format(target.agent or "agent", target.pane_id, suffix))
      end)
    end)
  end)
end

function M.setup(opts)
  local cfg = config.setup(opts)
  require("herdr-context.ui.statusline").setup()
  require("herdr-context.notifications").setup()
  watch.start(cfg)
  return cfg
end

function M.reference(opts)
  stage("reference", opts)
end

function M.send(opts)
  stage("content", opts)
end

function M.diagnostics(opts)
  stage("diagnostics", opts)
end

function M.compose(opts)
  return require("herdr-context.composer").open(opts)
end

function M.prompt(opts)
  opts = opts or {}
  vim.validate({
    opts = { opts, "table" },
    wait = { opts.wait, "boolean", true },
    timeout_ms = { opts.timeout_ms, "number", true },
    preview_result = { opts.preview_result, "boolean", true },
  })
  if opts.timeout_ms and (opts.timeout_ms <= 0 or opts.timeout_ms % 1 ~= 0) then
    error("herdr-context: prompt timeout_ms must be a positive integer")
  end
  if opts.timeout_ms and not opts.wait then
    error("herdr-context: prompt timeout_ms requires wait = true")
  end
  opts = vim.tbl_extend("force", opts or {}, { edit_instruction = true })
  return require("herdr-context.composer").open(opts)
end

function M.delegate(opts)
  opts = opts or {}
  vim.validate({
    opts = { opts, "table" },
    kind = { opts.kind, "string" },
    name = { opts.name, "string", true },
    preset = { opts.preset, "string", true },
    placement = { opts.placement, "string", true },
    direction = { opts.direction, "string", true },
    wait = { opts.wait, "boolean", true },
    timeout_ms = { opts.timeout_ms, "number", true },
    startup_timeout_ms = { opts.startup_timeout_ms, "number", true },
    preview_result = { opts.preview_result, "boolean", true },
    agent_args = { opts.agent_args, "table", true },
  })
  if opts.kind == "" then
    error("herdr-context: delegate kind must not be empty")
  end
  if opts.placement and not vim.tbl_contains({ "split", "tab", "workspace" }, opts.placement) then
    error("herdr-context: delegate placement must be split, tab, or workspace")
  end
  if opts.direction and not vim.tbl_contains({ "right", "down" }, opts.direction) then
    error("herdr-context: delegate direction must be right or down")
  end
  if opts.timeout_ms and (opts.timeout_ms <= 0 or opts.timeout_ms % 1 ~= 0) then
    error("herdr-context: delegate timeout_ms must be a positive integer")
  end
  if opts.timeout_ms and opts.wait == false then
    error("herdr-context: delegate timeout_ms requires wait = true or an interactive tracking choice")
  end
  if
    opts.startup_timeout_ms
    and (opts.startup_timeout_ms <= 3000 or opts.startup_timeout_ms > 300000 or opts.startup_timeout_ms % 1 ~= 0)
  then
    error("herdr-context: delegate startup_timeout_ms must be greater than 3000 and at most 300000")
  end
  if opts.agent_args and not vim.islist(opts.agent_args) then
    error("herdr-context: delegate agent_args must be a list")
  end
  for _, arg in ipairs(opts.agent_args or {}) do
    if type(arg) ~= "string" then
      error("herdr-context: delegate agent_args entries must be strings")
    end
  end
  return require("herdr-context.delegate").open(opts)
end

function M.symbol(opts)
  return require("herdr-context.composer").stage_provider("symbol", opts)
end

function M.hunk(opts)
  return require("herdr-context.composer").stage_provider("hunk", opts)
end

function M.quickfix(opts)
  return require("herdr-context.composer").stage_provider("quickfix", opts)
end

function M.location_list(opts)
  return require("herdr-context.composer").stage_provider("location_list", opts)
end

function M.register_provider(provider)
  return require("herdr-context.providers").register(provider)
end

function M.select_target()
  local cfg = config.get()
  targets.resolve(cfg, picker, { force = true }, function(target, err)
    if not target then
      if err ~= "Target selection cancelled" then
        notify(err, vim.log.levels.ERROR)
      end
      return
    end
    notify(("Herdr target: %s (%s)"):format(target.agent or "agent", target.pane_id))
  end)
end

function M.statusline()
  return require("herdr-context.ui.statusline").get()
end

function M.agents()
  require("herdr-context.ui.agents").toggle()
end

function M.explain_agent(target)
  local function open(agent)
    require("herdr-context.ui.explain").open(agent)
  end
  if target then
    open(target)
    return
  end
  local cfg = config.get()
  targets.resolve(cfg, picker, {}, function(agent, err)
    if not agent then
      if err ~= "Target selection cancelled" then
        notify(err, vim.log.levels.ERROR)
      end
      return
    end
    open(agent)
  end)
end

function M.history()
  return require("herdr-context.ui.history").toggle()
end

function M.refresh(callback)
  state.refresh({ force = true }, function(current, err)
    if err then
      notify("Could not refresh Herdr state: " .. err, vim.log.levels.ERROR)
    end
    if callback then
      callback(current, err)
    end
  end)
end

return M
