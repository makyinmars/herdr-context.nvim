local M = {}

local socket = require("herdr-context.socket")

local function binary(config)
  return config.herdr_bin or vim.env.HERDR_BIN_PATH or "herdr"
end

local function command(config, args)
  local argv = { binary(config) }
  vim.list_extend(argv, args)
  return argv
end

local function result_error(result)
  local detail = result.stderr ~= "" and result.stderr or result.stdout
  detail = (detail or ""):gsub("%s+$", "")
  if detail == "" then
    detail = "Herdr exited with status " .. tostring(result.code)
  end
  return detail
end

function M.run(config, args, callback)
  local argv = command(config, args)
  if callback then
    local ok, process = pcall(vim.system, argv, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, result_error(result), result)
          return
        end
        callback(result.stdout or "", nil, result)
      end)
    end)
    if not ok then
      vim.schedule(function()
        callback(nil, "Could not start Herdr: " .. tostring(process))
      end)
      return nil
    end
    return process
  end

  local ok, process = pcall(vim.system, argv, { text = true })
  if not ok then
    return nil, "Could not start Herdr: " .. tostring(process)
  end
  local waited, result = pcall(process.wait, process, 5000)
  if not waited then
    return nil, "Could not wait for Herdr: " .. tostring(result)
  end
  if result.code ~= 0 then
    return nil, result_error(result), result
  end
  return result.stdout or "", nil, result
end

local function decode_response(output)
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= "table" then
    return nil, "Herdr returned invalid JSON"
  end
  if decoded.error then
    local message = type(decoded.error) == "table" and decoded.error.message or decoded.error
    return nil, "Herdr API error: " .. tostring(message)
  end
  return decoded
end

local function decode_error(err)
  local ok, decoded = pcall(vim.json.decode, err or "")
  if ok and type(decoded) == "table" and type(decoded.error) == "table" then
    return decoded.error
  end
  return err
end

local function json_command(config, args, callback)
  if callback then
    return M.run(config, args, function(output, err)
      if err then
        callback(nil, err)
        return
      end
      local decoded, decode_err = decode_response(output)
      callback(decoded, decode_err)
    end)
  end

  local output, err = M.run(config, args)
  if not output then
    return nil, err
  end
  return decode_response(output)
end

function M.snapshot(config, callback)
  local function unwrap(decoded, err)
    if not decoded then
      return nil, err
    end
    local snapshot = decoded.result and decoded.result.snapshot or decoded.snapshot
    if type(snapshot) ~= "table" then
      return nil, "Herdr snapshot response did not contain result.snapshot"
    end
    return snapshot
  end

  if callback then
    return json_command(config, { "api", "snapshot" }, function(decoded, err)
      callback(unwrap(decoded, err))
    end)
  end
  return unwrap(json_command(config, { "api", "snapshot" }))
end

function M.get_agent(config, target, callback)
  local function unwrap(decoded, err)
    if not decoded then
      return nil, err
    end
    local agent = decoded.result and decoded.result.agent or decoded.agent
    if type(agent) ~= "table" then
      return nil, "Herdr agent response did not contain result.agent"
    end
    return agent
  end

  if callback then
    return json_command(config, { "agent", "get", target }, function(decoded, err)
      callback(unwrap(decoded, err))
    end)
  end
  return unwrap(json_command(config, { "agent", "get", target }))
end

function M.explain_agent(config, target, callback)
  local function unwrap(decoded, err)
    if not decoded then
      return nil, err
    end
    local explanation = decoded.result and decoded.result.explain or decoded.explain or decoded
    if type(explanation) ~= "table" or not explanation.state then
      return nil, "Herdr agent explain response did not contain an explanation"
    end
    return explanation
  end

  if callback then
    return json_command(config, { "agent", "explain", target, "--json" }, function(decoded, err)
      callback(unwrap(decoded, err))
    end)
  end
  return unwrap(json_command(config, { "agent", "explain", target, "--json" }))
end

function M.create_pane(config, placement, opts, callback)
  opts = opts or {}
  local args
  local pane_field
  if placement == "split" then
    args = { "pane", "split", "--current", "--direction", opts.direction or "right" }
    pane_field = "pane"
  elseif placement == "tab" then
    args = { "tab", "create" }
    if opts.workspace_id then
      vim.list_extend(args, { "--workspace", opts.workspace_id })
    end
    pane_field = "root_pane"
  elseif placement == "workspace" then
    args = { "workspace", "create" }
    pane_field = "root_pane"
  else
    return callback(nil, "Unknown delegation placement: " .. tostring(placement))
  end
  if opts.cwd then
    vim.list_extend(args, { "--cwd", opts.cwd })
  end
  if placement ~= "split" and opts.label then
    vim.list_extend(args, { "--label", opts.label })
  end
  args[#args + 1] = "--no-focus"

  return json_command(config, args, function(decoded, err)
    if not decoded then
      callback(nil, decode_error(err))
      return
    end
    local pane = decoded.result and decoded.result[pane_field] or decoded[pane_field]
    if type(pane) ~= "table" or not pane.pane_id then
      callback(nil, "Herdr pane creation response did not contain a pane")
      return
    end
    callback(pane)
  end)
end

function M.start_agent(config, name, kind, pane_id, opts, callback)
  opts = opts or {}
  local args = { "agent", "start", name, "--kind", kind, "--pane", pane_id }
  if opts.timeout_ms then
    vim.list_extend(args, { "--timeout", tostring(opts.timeout_ms) })
  end
  if opts.args and #opts.args > 0 then
    args[#args + 1] = "--"
    vim.list_extend(args, opts.args)
  end
  return json_command(config, args, function(decoded, err)
    if not decoded then
      callback(nil, decode_error(err))
      return
    end
    local agent = decoded.result and decoded.result.agent or decoded.agent
    if type(agent) ~= "table" or not agent.pane_id then
      callback(nil, "Herdr agent start response did not contain result.agent")
      return
    end
    callback(agent)
  end)
end

function M.read_agent(config, pane_id, opts, callback)
  opts = opts or {}
  local source = opts.source or "recent-unwrapped"
  local lines = opts.lines or 80
  local socket_path = opts.socket_path or vim.env.HERDR_SOCKET_PATH
  if opts.metadata and callback and socket_path and socket_path ~= "" then
    local request = opts.socket_request or socket.request
    return request({
      path = socket_path,
      method = "agent.read",
      params = {
        target = pane_id,
        source = source:gsub("-", "_"),
        lines = lines,
        format = "text",
        strip_ansi = true,
      },
    }, function(result, err)
      if err then
        callback(nil, err)
        return
      end
      local read = result and result.read
      if type(read) ~= "table" or type(read.text) ~= "string" then
        callback(nil, { code = "invalid_response", message = "Herdr agent.read response did not contain result.read" })
        return
      end
      callback(read, nil)
    end)
  end
  return M.run(config, {
    "agent",
    "read",
    pane_id,
    "--source",
    source,
    "--lines",
    tostring(lines),
    "--format",
    "text",
  }, callback)
end

function M.send(config, pane_id, text, callback)
  return M.run(config, { "pane", "send-text", pane_id, text }, callback)
end

function M.prompt(config, pane_id, text, callback, opts)
  opts = opts or {}
  local args = { "agent", "prompt", pane_id, text }
  if opts.wait then
    vim.list_extend(args, {
      "--wait",
      "--until",
      "idle",
      "--until",
      "done",
      "--until",
      "blocked",
    })
    if opts.timeout_ms then
      vim.list_extend(args, { "--timeout", tostring(opts.timeout_ms) })
    end
  end
  if not opts.wait then
    return M.run(config, args, callback)
  end
  return M.run(config, args, function(output, err, result)
    if err then
      local detail = result and result.stderr or err
      local ok, decoded = pcall(vim.json.decode, detail or "")
      local api_err = ok and type(decoded) == "table" and decoded.error or nil
      if type(api_err) ~= "table" then
        api_err = { code = "prompt_failed", message = err }
      end
      api_err.message = api_err.message or err
      callback(nil, api_err, result)
      return
    end
    local ok, decoded = pcall(vim.json.decode, output or "")
    local agent = ok and decoded and decoded.result and decoded.result.agent or nil
    if type(agent) ~= "table" or not agent.agent_status then
      callback(
        nil,
        { code = "invalid_response", message = "Herdr prompt response did not contain result.agent" },
        result
      )
      return
    end
    callback(agent, nil, result)
  end)
end

function M.submit(config, pane_id, callback)
  return M.run(config, { "pane", "send-keys", pane_id, "enter" }, callback)
end

function M.focus(config, pane_id, callback)
  return M.run(config, { "agent", "focus", pane_id }, callback)
end

function M.version_meets_minimum(version, minimum)
  local function parts(str)
    if type(str) ~= "string" then
      return nil
    end
    local major, minor, patch = str:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then
      return nil
    end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
  end

  local version_parts = parts(version)
  local minimum_parts = parts(minimum)
  if not version_parts or not minimum_parts then
    return nil
  end

  for i = 1, 3 do
    if version_parts[i] > minimum_parts[i] then
      return true
    elseif version_parts[i] < minimum_parts[i] then
      return false
    end
  end
  return true
end

function M.executable(config)
  local bin = binary(config)
  if bin:find("/", 1, true) then
    return vim.fn.executable(bin) == 1, bin
  end
  local found = vim.fn.exepath(bin)
  return found ~= "", found ~= "" and found or bin
end

return M
