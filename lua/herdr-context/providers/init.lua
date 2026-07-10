local M = {}

local bundle = require("herdr-context.bundle")

local registry = {}
local builtins_loaded = false

local builtin_modules = {
  "herdr-context.providers.selection",
  "herdr-context.providers.symbol",
  "herdr-context.providers.hunk",
  "herdr-context.providers.diagnostics",
  "herdr-context.providers.quickfix",
  "herdr-context.providers.trouble",
}

local function validate_provider(provider)
  if type(provider) ~= "table" then
    error("herdr-context: provider must be a table")
  end
  vim.validate({
    ["provider.id"] = { provider.id, "string" },
    ["provider.name"] = { provider.name, "string" },
    ["provider.collect"] = { provider.collect, "function" },
  })
  if provider.id == "" or not provider.id:match("^[%w_.-]+$") then
    error("herdr-context: provider.id must contain only letters, numbers, dots, underscores, and dashes")
  end
  if provider.name == "" then
    error("herdr-context: provider.name must not be empty")
  end
  if provider.priority ~= nil and type(provider.priority) ~= "number" then
    error("herdr-context: provider.priority must be a number")
  end
  if provider.available ~= nil and type(provider.available) ~= "function" then
    error("herdr-context: provider.available must be a function")
  end
end

function M.register(provider, opts)
  opts = opts or {}
  validate_provider(provider)
  if registry[provider.id] and not opts.replace then
    error("herdr-context: provider " .. provider.id .. " is already registered")
  end
  registry[provider.id] = provider
  return provider
end

local function ensure_builtins()
  if builtins_loaded then
    return
  end
  builtins_loaded = true
  for _, module in ipairs(builtin_modules) do
    local loaded = require(module)
    local providers = loaded.providers or { loaded }
    for _, provider in ipairs(providers) do
      M.register(provider, { replace = true })
    end
  end
end

function M.get(id)
  ensure_builtins()
  return registry[id]
end

function M.list()
  ensure_builtins()
  local result = {}
  for _, provider in pairs(registry) do
    result[#result + 1] = provider
  end
  table.sort(result, function(a, b)
    local a_priority, b_priority = a.priority or 100, b.priority or 100
    if a_priority ~= b_priority then
      return a_priority < b_priority
    end
    return a.id < b.id
  end)
  return result
end

function M.unavailable(message)
  return { kind = "unavailable", message = message }
end

local function error_kind(err)
  if type(err) == "table" then
    return err.kind == "unavailable" and "unavailable" or "failed", err.message or vim.inspect(err)
  end
  return "failed", tostring(err)
end

function M.collect(request, opts, callback)
  opts = opts or {}
  local timeout = opts.timeout_ms or 1500
  local wanted
  if opts.ids then
    wanted = {}
    for _, id in ipairs(opts.ids) do
      wanted[id] = true
    end
  end

  local entries = {}
  for _, provider in ipairs(M.list()) do
    if not wanted or wanted[provider.id] then
      entries[#entries + 1] = {
        id = provider.id,
        name = provider.name,
        priority = provider.priority or 100,
        provider = provider,
        status = "collecting",
      }
    end
  end

  local remaining = #entries
  local cancelled = false
  local cancels = {}

  local function update(entry)
    if opts.on_update then
      opts.on_update(entry, entries)
    end
  end

  local function complete(entry, status, section, err)
    if entry.done or cancelled then
      return
    end
    entry.done = true
    if entry.timer then
      entry.timer:stop()
      entry.timer:close()
      entry.timer = nil
    end
    entry.status = status
    entry.section = section
    entry.error = err
    remaining = remaining - 1
    update(entry)
    if remaining == 0 then
      callback(entries)
    end
  end

  if remaining == 0 then
    callback(entries)
  end

  for _, entry in ipairs(entries) do
    local provider = entry.provider
    local available, reason = true, nil
    if provider.available then
      local ok, value, detail = pcall(provider.available, request)
      if not ok then
        complete(entry, "failed", nil, tostring(value))
        available = nil
      else
        available, reason = value ~= false, detail
      end
    end

    if available == false then
      complete(entry, "unavailable", nil, reason or "Not available in the current context")
    elseif available then
      update(entry)
      local timer = (vim.uv or vim.loop).new_timer()
      entry.timer = timer
      timer:start(timeout, 0, function()
        vim.schedule(function()
          if not entry.done and not cancelled then
            local cancel = cancels[entry.id]
            complete(entry, "failed", nil, ("Timed out after %d ms"):format(timeout))
            if cancel then
              pcall(cancel)
            end
          end
        end)
      end)

      local called = false
      local function provider_callback(section, err)
        if vim.in_fast_event() then
          if called or entry.done or cancelled then
            return
          end
          called = true
          vim.schedule(function()
            called = false
            provider_callback(section, err)
          end)
          return
        end
        if called or entry.done or cancelled then
          return
        end
        called = true
        if err then
          local status, message = error_kind(err)
          complete(entry, status, nil, message)
          return
        end
        if not section then
          complete(entry, "unavailable", nil, "No context at the current position")
          return
        end
        local normalized, normalize_err = bundle.normalize(section, provider)
        if not normalized then
          complete(entry, "failed", nil, normalize_err)
          return
        end
        complete(entry, "available", normalized)
      end

      local ok, cancel_or_err = pcall(provider.collect, request, provider_callback)
      if not ok then
        if not called then
          called = true
          complete(entry, "failed", nil, tostring(cancel_or_err))
        end
      elseif type(cancel_or_err) == "function" and not entry.done then
        cancels[entry.id] = cancel_or_err
      end
    end
  end

  return function()
    if cancelled then
      return
    end
    cancelled = true
    for _, entry in ipairs(entries) do
      if entry.timer then
        entry.timer:stop()
        entry.timer:close()
        entry.timer = nil
      end
      if not entry.done and cancels[entry.id] then
        pcall(cancels[entry.id])
      end
      entry.done = true
    end
  end
end

function M._reset()
  registry = {}
  builtins_loaded = false
end

return M
