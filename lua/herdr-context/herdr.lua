local M = {}

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

function M.read_agent(config, pane_id, opts, callback)
  opts = opts or {}
  local source = opts.source or "recent-unwrapped"
  local lines = opts.lines or 80
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
  return M.run(config, { "agent", "send", pane_id, text }, callback)
end

function M.submit(config, pane_id, callback)
  return M.run(config, { "pane", "send-keys", pane_id, "enter" }, callback)
end

function M.focus(config, pane_id, callback)
  return M.run(config, { "agent", "focus", pane_id }, callback)
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
