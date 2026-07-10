local M = {}

local uv = vim.uv or vim.loop

function M.decoder(on_message, on_error)
  on_message = on_message or function() end
  on_error = on_error or function() end
  local pending = ""
  local stopped = false
  local decoder = {}

  local function decode(line)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if line == "" then
      return
    end
    local ok, value = pcall(vim.json.decode, line)
    if not ok or type(value) ~= "table" then
      on_error("Herdr socket returned invalid JSON", line)
      return
    end
    on_message(value)
  end

  function decoder.feed(chunk)
    if stopped or not chunk or chunk == "" then
      return
    end
    pending = pending .. chunk
    while true do
      local newline = pending:find("\n", 1, true)
      if not newline then
        break
      end
      local line = pending:sub(1, newline - 1)
      pending = pending:sub(newline + 1)
      decode(line)
    end
  end

  function decoder.finish()
    if stopped then
      return
    end
    stopped = true
    if pending ~= "" then
      on_error("Herdr socket closed during a JSON message", pending)
    end
    pending = ""
  end

  return decoder
end

local Client = {}
Client.__index = Client

local function dispatch(client, callback, ...)
  if not callback then
    return
  end
  local values = { n = select("#", ...), ... }
  vim.schedule(function()
    if not client.silent then
      callback(unpack(values, 1, values.n))
    end
  end)
end

function Client:_finish(reason)
  if self.closed then
    return
  end
  self.closed = true
  if self.decoder then
    self.decoder.finish()
  end
  if self.pipe then
    pcall(self.pipe.read_stop, self.pipe)
    if not self.pipe:is_closing() then
      self.pipe:close()
    end
  end
  dispatch(self, self.on_close, reason)
end

function Client:connect()
  if self.pipe or self.closed then
    return nil
  end
  self.pipe = uv.new_pipe(false)
  self.decoder = M.decoder(function(message)
    dispatch(self, self.on_message, message)
  end, function(err, line)
    dispatch(self, self.on_error, err, line)
  end)

  self.pipe:connect(self.path, function(err)
    if self.closed then
      return
    end
    if err then
      dispatch(self, self.on_error, "Could not connect to Herdr socket: " .. tostring(err))
      self:_finish("connect_error")
      return
    end

    self.pipe:read_start(function(read_err, chunk)
      if self.closed then
        return
      end
      if read_err then
        dispatch(self, self.on_error, "Could not read from Herdr socket: " .. tostring(read_err))
        self:_finish("read_error")
        return
      end
      if chunk == nil then
        self:_finish("eof")
        return
      end
      self.decoder.feed(chunk)
    end)
    dispatch(self, self.on_connect)
  end)
  return self
end

function Client:write(message)
  if self.closed or not self.pipe then
    return nil, "Herdr socket is not connected"
  end
  local payload = type(message) == "string" and message or vim.json.encode(message)
  if payload:sub(-1) ~= "\n" then
    payload = payload .. "\n"
  end
  self.pipe:write(payload, function(err)
    if err and not self.closed then
      dispatch(self, self.on_error, "Could not write to Herdr socket: " .. tostring(err))
      self:_finish("write_error")
    end
  end)
  return true
end

function Client:close(opts)
  opts = opts or {}
  self.silent = opts.silent == true
  self:_finish(opts.reason or "closed")
end

function Client:is_active()
  return self.pipe ~= nil and not self.closed
end

function M.new(opts)
  opts = opts or {}
  vim.validate({
    path = { opts.path, "string" },
    on_connect = { opts.on_connect, "function", true },
    on_message = { opts.on_message, "function", true },
    on_error = { opts.on_error, "function", true },
    on_close = { opts.on_close, "function", true },
  })
  return setmetatable({
    path = opts.path,
    on_connect = opts.on_connect,
    on_message = opts.on_message,
    on_error = opts.on_error,
    on_close = opts.on_close,
    closed = false,
    silent = false,
  }, Client)
end

return M
