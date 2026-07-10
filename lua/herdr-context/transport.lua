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

local function after_send(config, target, callback)
  local function focus_if_needed()
    if not config.focus_after_send then
      callback(true)
      return
    end
    herdr.focus(config, target.pane_id, function(_, err)
      callback(not err, err)
    end)
  end

  if not config.submit then
    focus_if_needed()
    return
  end

  herdr.submit(config, target.pane_id, function(_, err)
    if err then
      callback(false, "Context was staged, but submission failed: " .. err)
      return
    end
    focus_if_needed()
  end)
end

function M.stage(config, target, payload, callback)
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
    after_send(config, target, function(ok, final_err)
      callback(ok, final_err, { mode = mode, context_file = context_file })
    end)
  end)
end

M.bracketed_paste_start = bracketed_paste_start
M.bracketed_paste_end = bracketed_paste_end

return M
