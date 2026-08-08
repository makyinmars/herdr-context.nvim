local M = {}

local uv = vim.uv or vim.loop
local herdr = require("herdr-context.herdr")

local bracketed_paste_start = "\27[200~"
local bracketed_paste_end = "\27[201~"

local function has_newline(payload)
  return payload:find("[\r\n]") ~= nil
end

local function context_directory(config)
  return config.context_file_dir or vim.fs.joinpath(vim.fn.stdpath("cache"), "herdr-context")
end

local function write_context_file(config, payload)
  local directory = context_directory(config)
  vim.fn.mkdir(directory, "p")
  local path = vim.fs.joinpath(directory, ("context-%d-%06d.md"):format(os.time(), math.random(0, 999999)))
  local fd, open_err = uv.fs_open(path, "w", 384)
  if not fd then
    return nil, "Could not create context file: " .. tostring(open_err)
  end
  local written, write_err = uv.fs_write(fd, payload, 0)
  uv.fs_close(fd)
  if not written then
    return nil, "Could not write context file: " .. tostring(write_err)
  end
  return path
end

function M.prepare(config, target, payload)
  if not has_newline(payload) then
    return payload, "literal"
  end

  local strategy = config.multiline_strategy
  local agent = (target.agent or ""):lower()
  local supports_bracketed_paste = config.bracketed_paste_agents[agent] == true
  if strategy == "bracketed_paste" or (strategy == "auto" and supports_bracketed_paste) then
    return bracketed_paste_start .. payload .. bracketed_paste_end, "bracketed_paste"
  end

  local path, err = write_context_file(config, payload)
  if not path then
    return nil, nil, err
  end
  return "Context staged in @" .. path, "context_file", nil, path
end

local function focus_if_needed(config, target, callback)
  if not config.focus_after_send then
    callback(true)
    return
  end
  herdr.focus(config, target.pane_id, function(_, err)
    callback(not err, err)
  end)
end

local function prompt_error_message(err)
  if type(err) ~= "table" then
    return tostring(err)
  end
  if err.code == "timeout" then
    return "Herdr tracking timed out; the agent task is still running"
  elseif err.code == "agent_prompt_stalled" then
    return "Herdr observed no agent state transition after prompting; the task may still start"
  end
  return err.message or err.code or vim.inspect(err)
end

function M.stage(config, target, payload, callback, opts)
  opts = opts or {}
  local submit = opts.submit
  if submit == nil then
    submit = config.submit
  end

  if submit then
    herdr.prompt(config, target.pane_id, payload, function(agent, err)
      if err then
        local result = {
          mode = "agent_prompt",
          submitted = err.code == "timeout" or err.code == "agent_prompt_stalled",
          tracked = opts.wait == true,
          tracking_error = err,
          tracking_message = prompt_error_message(err),
        }
        if result.submitted then
          callback(true, nil, result)
        else
          callback(false, "Could not submit context: " .. prompt_error_message(err), result)
        end
        return
      end
      local tracked = opts.wait == true
      local status = tracked and agent and agent.agent_status or nil
      local focus_config = config
      if status == "blocked" and not config.focus_after_send then
        focus_config = vim.tbl_extend("force", config, { focus_after_send = true })
      end
      focus_if_needed(focus_config, target, function(ok, focus_err)
        local result = {
          mode = "agent_prompt",
          submitted = true,
        }
        if tracked then
          result.tracked = true
          result.status = status
          result.agent = agent
        end
        callback(ok, focus_err, result)
      end)
    end, { wait = opts.wait, timeout_ms = opts.timeout_ms })
    return
  end

  local staged, mode, prepare_err, context_file = M.prepare(config, target, payload)
  if not staged then
    callback(false, prepare_err)
    return
  end

  herdr.send(config, target.pane_id, staged, function(_, err)
    if err then
      callback(false, "Could not stage context: " .. err)
      return
    end
    focus_if_needed(config, target, function(ok, final_err)
      callback(ok, final_err, { mode = mode, context_file = context_file, submitted = false })
    end)
  end)
end

M.bracketed_paste_start = bracketed_paste_start
M.bracketed_paste_end = bracketed_paste_end

return M
