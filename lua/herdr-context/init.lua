local M = {}

local config = require("herdr-context.config")
local context = require("herdr-context.context")
local format = require("herdr-context.format")
local picker = require("herdr-context.picker")
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
      notify(("Staged context for %s (%s)%s"):format(target.agent or "agent", target.pane_id, suffix))
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
