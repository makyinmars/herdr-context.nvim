local failures = {}

local function eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    failures[#failures + 1] = (message or "values differ")
      .. ("\nexpected %s\nactual   %s"):format(vim.inspect(expected), vim.inspect(actual))
  end
end

local context = require("herdr-context.context")
local socket = require("herdr-context.socket")
local targets = require("herdr-context.targets")
local transport = require("herdr-context.transport")

eq("src/module.lua", context._relative_path([[C:\Repo]], [[c:\repo\src\module.lua]]), "relative Windows path")
eq("D:/other/module.lua", context._relative_path([[C:\Repo]], [[D:\other\module.lua]]), "cross-volume path")
eq(
  "src/module.lua",
  context._relative_path([[\\server\share\repo]], [[\\SERVER\SHARE\repo\src\module.lua]]),
  "UNC relative path"
)
eq(
  "//?/UNC/server/shareB/file.lua",
  context._relative_path([[\\?\UNC\server\shareA\repo]], [[\\?\UNC\server\shareB\file.lua]]),
  "extended UNC share boundary"
)
eq(
  "src/module.lua",
  context._relative_path([[\\?\UNC\server\share\repo]], [[\\?\unc\SERVER\SHARE\repo\src\module.lua]]),
  "extended UNC relative path"
)
eq(nil, context.find_git_root([[D:\herdr-context-path-that-does-not-exist]]), "drive root traversal")
eq("C:/Users/Ada/context.md", transport.reference_path([[C:\Users\Ada\context.md]]), "reference separators")
eq([[\\.\pipe\herdr-session]], socket.endpoint("herdr-session"), "named-pipe endpoint")

local snapshot = {
  workspaces = {
    { workspace_id = "w1", worktree = { checkout_path = [[C:\Repo]], repo_root = [[C:\Source]] } },
    { workspace_id = "w2", worktree = { checkout_path = "c:/repo", repo_root = "c:/source" } },
    { workspace_id = "w3", worktree = { checkout_path = [[C:\Other]], repo_root = "c:/SOURCE" } },
    { workspace_id = "w4", worktree = { checkout_path = [[D:\Other]], repo_root = [[D:\Other]] } },
  },
  agents = {
    { pane_id = "w4:p2", workspace_id = "w4", cwd = [[D:\unrelated]] },
    { pane_id = "w4:p1", workspace_id = "w4", foreground_cwd = [[c:\REPO]] },
    { pane_id = "w3:p1", workspace_id = "w3", cwd = [[D:\other]] },
    { pane_id = "w2:p1", workspace_id = "w2", cwd = [[D:\other]] },
  },
}
local candidates = targets.candidates(snapshot, {
  scope = "session",
  pane_id = "self",
  workspace_id = "w1",
  cwd = "C:/repo",
})
eq(
  { "w2:p1", "w3:p1", "w4:p1", "w4:p2" },
  vim.tbl_map(function(candidate)
    return candidate.pane_id
  end, candidates),
  "Windows target ranking"
)
eq(3, #targets.candidates(snapshot, {
  scope = "project",
  pane_id = "self",
  workspace_id = "w1",
  cwd = [[C:\Repo]],
}), "Windows project scope")

local endpoint
local fake_pipe = {
  connect = function(_, path, callback)
    endpoint = path
    callback(nil)
  end,
  is_closing = function()
    return false
  end,
  close = function() end,
}
local available, probe_err = socket.probe("herdr-session", {
  new_pipe = function()
    return fake_pipe
  end,
})
eq(true, available, probe_err or "named-pipe probe")
eq([[\\.\pipe\herdr-session]], endpoint, "probed endpoint")

local uv = vim.uv or vim.loop
local pipe_name = socket.endpoint("herdr-context-test-" .. tostring(uv.os_getpid()))
local server = uv.new_pipe(false)
local bound, bind_err = pcall(server.bind, server, pipe_name)
eq(true, bound, "named-pipe bind: " .. tostring(bind_err))
if bound then
  local listened, listen_err = pcall(server.listen, server, 1, function(err)
    eq(nil, err, "named-pipe accept")
    if not err then
      local peer = uv.new_pipe(false)
      server:accept(peer)
      peer:close()
    end
  end)
  eq(true, listened, "named-pipe listen: " .. tostring(listen_err))
  if listened then
    local present, presence_err = socket.probe(pipe_name, { timeout_ms = 1000 })
    eq(true, present, "named-pipe presence: " .. tostring(presence_err))
  end
end
if not server:is_closing() then
  server:close()
end

local original_system = vim.system
local argv
vim.system = function(command, _, callback)
  argv = vim.deepcopy(command)
  callback({ code = 0, stdout = "", stderr = "" })
  return { kill = function() end }
end
local payload = "Keep <C-Space> and <M-Enter> literal\r\nsecond line"
local completed
transport.stage(
  { herdr_bin = [[C:\Program Files\Herdr\herdr.exe]], submit = true, focus_after_send = false },
  { pane_id = "w0:p2", agent = "codex" },
  payload,
  function(ok, err)
    completed = { ok = ok, err = err }
  end
)
vim.wait(1000, function()
  return completed ~= nil
end, 10)
vim.system = original_system
eq({ [[C:\Program Files\Herdr\herdr.exe]], "agent", "prompt", "w0:p2", payload }, argv, "exact prompt argv")
eq(true, completed and completed.ok, completed and completed.err or "transport did not complete")

if #failures > 0 then
  print(table.concat(failures, "\n\n"))
  vim.cmd("cquit 1")
else
  print("ok - Windows paths, named pipes, and transport")
  vim.cmd("qa!")
end
