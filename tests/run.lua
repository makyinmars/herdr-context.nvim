local failures = {}
local total = 0

local function inspect(value)
  return vim.inspect(value)
end

local function fail(message)
  error(message, 2)
end

local function eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail((message and (message .. ": ") or "") .. "expected " .. inspect(expected) .. ", got " .. inspect(actual))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or ("expected truthy value, got " .. inspect(value)))
  end
end

local function contains(haystack, needle, message)
  if not haystack:find(needle, 1, true) then
    fail((message and (message .. ": ") or "") .. inspect(haystack) .. " does not contain " .. inspect(needle))
  end
end

local function test(name, callback)
  total = total + 1
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    print("ok " .. total .. " - " .. name)
  else
    failures[#failures + 1] = { name = name, err = err }
    print("not ok " .. total .. " - " .. name)
  end
end

local context = require("herdr-context.context")
local format = require("herdr-context.format")
local config = require("herdr-context.config")
local herdr = require("herdr-context.herdr")
local targets = require("herdr-context.targets")
local transport = require("herdr-context.transport")

local function buffer(lines, name, filetype)
  local bufnr = vim.api.nvim_create_buf(false, false)
  if name then
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = filetype or "lua"
  return bufnr
end

local function delete_buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

test("captures a normal-mode current line", function()
  local bufnr = buffer({ "alpha", "bravo", "charlie" }, vim.fn.getcwd() .. "/lua/sample.lua")
  vim.bo[bufnr].modified = true
  local captured = context.capture({ bufnr = bufnr, line = 2 })
  eq(2, captured.start_line)
  eq(2, captured.end_line)
  eq("bravo", captured.text)
  eq("lua/sample.lua", captured.relative_path)
  eq(true, captured.modified)
  delete_buffer(bufnr)
end)

test("captures reversed linewise selections", function()
  local bufnr = buffer({ "alpha", "bravo", "charlie" })
  local captured = context.capture({
    bufnr = bufnr,
    selection = { mode = "V", start = { 3, 1 }, finish = { 1, 1 } },
  })
  eq(1, captured.start_line)
  eq(3, captured.end_line)
  eq("alpha\nbravo\ncharlie", captured.text)
  delete_buffer(bufnr)
end)

test("captures inclusive reversed characterwise selections", function()
  local bufnr = buffer({ "alpha", "bravo" })
  local captured = context.capture({
    bufnr = bufnr,
    selection = { mode = "v", start = { 2, 3 }, finish = { 1, 3 } },
  })
  eq("pha\nbra", captured.text)
  delete_buffer(bufnr)
end)

test("captures blockwise selections", function()
  local bufnr = buffer({ "alpha", "bravo", "x" })
  local captured = context.capture({
    bufnr = bufnr,
    selection = { mode = "block", start = { 1, 2 }, finish = { 3, 4 } },
  })
  eq("lph\nrav\n", captured.text)
  delete_buffer(bufnr)
end)

test("resolves non-Git paths relative to the supplied cwd", function()
  local relative, root = context.resolve_path("/tmp/herdr-context-other/file.lua", "/tmp/herdr-context-cwd")
  eq("../herdr-context-other/file.lua", relative)
  eq("/tmp/herdr-context-cwd", root)
end)

test("formats references relative to the Git root", function()
  local payload =
    format.reference({ relative_path = "lua/plugin.lua", unnamed = false, start_line = 10, end_line = 20 })
  eq("@lua/plugin.lua#L10-L20", payload)
end)

test("marks modified content and chooses a longer Markdown fence", function()
  local payload = format.content({
    relative_path = "lua/plugin.lua",
    unnamed = false,
    start_line = 3,
    end_line = 3,
    modified = true,
    filetype = "lua",
    text = "local example = [[```]]",
  })
  contains(payload, "@lua/plugin.lua#L3 (unsaved changes)")
  contains(payload, "````lua\n")
  truthy(payload:sub(-4) == "````")
end)

test("allows unnamed content but rejects unnamed references", function()
  local captured = {
    unnamed = true,
    start_line = 1,
    end_line = 1,
    modified = true,
    filetype = "lua",
    text = "return true",
  }
  local reference, err = format.reference(captured)
  eq(nil, reference)
  contains(err, "named buffer")
  contains(format.content(captured), "Unnamed buffer")
end)

test("enforces byte limits without truncating Unicode", function()
  local payload, err = format.validate("é", 1)
  eq(nil, payload)
  contains(err, "2 bytes")
  eq("é", format.validate("é", 2))
end)

test("collects and formats diagnostics in the selected range", function()
  local bufnr = buffer({ "one", "two", "three" }, vim.fn.getcwd() .. "/src/index.ts", "typescript")
  local namespace = vim.api.nvim_create_namespace("herdr-context-test")
  vim.diagnostic.set(namespace, bufnr, {
    {
      lnum = 1,
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      source = "typescript",
      code = 2345,
      message = "Bad\nvalue",
    },
    {
      lnum = 2,
      col = 0,
      severity = vim.diagnostic.severity.WARN,
      source = "eslint",
      code = "unused",
      message = "Unused",
    },
  })
  local captured = context.capture({ bufnr = bufnr, line1 = 2, line2 = 2 })
  local diagnostics = context.diagnostics(captured)
  eq(1, #diagnostics)
  local payload = format.diagnostics(captured, diagnostics)
  contains(payload, "Diagnostics for @src/index.ts#L2")
  contains(payload, "- ERROR [typescript:2345] L2: Bad value")
  vim.diagnostic.reset(namespace, bufnr)
  delete_buffer(bufnr)
end)

test("ranks targets by tab, workspace, project, then session", function()
  local root = vim.fn.getcwd()
  local snapshot = {
    workspaces = {
      { workspace_id = "w1", label = "current" },
      { workspace_id = "w2", label = "other" },
    },
    tabs = {
      { tab_id = "w1:t1", label = "api" },
      { tab_id = "w1:t2", label = "web" },
      { tab_id = "w2:t1", label = "other" },
    },
    agents = {
      {
        pane_id = "w2:p9",
        workspace_id = "w2",
        tab_id = "w2:t1",
        agent = "codex",
        agent_status = "idle",
        cwd = "/tmp",
      },
      { pane_id = "w2:p2", workspace_id = "w2", tab_id = "w2:t1", agent = "codex", agent_status = "idle", cwd = root },
      {
        pane_id = "w1:p2",
        workspace_id = "w1",
        tab_id = "w1:t2",
        agent = "claude",
        agent_status = "idle",
        cwd = "/tmp",
      },
      {
        pane_id = "w1:p1",
        workspace_id = "w1",
        tab_id = "w1:t1",
        agent = "codex",
        agent_status = "working",
        cwd = "/tmp",
      },
      { pane_id = "w1:p0", workspace_id = "w1", tab_id = "w1:t1", agent = "codex", agent_status = "idle", cwd = root },
    },
  }
  local candidates = targets.candidates(snapshot, {
    scope = "session",
    pane_id = "w1:p0",
    workspace_id = "w1",
    tab_id = "w1:t1",
    cwd = root,
  })
  eq(
    { "w1:p1", "w1:p2", "w2:p2", "w2:p9" },
    vim.tbl_map(function(item)
      return item.pane_id
    end, candidates)
  )
  local scoped = targets.candidates(snapshot, {
    scope = "workspace",
    pane_id = "w1:p0",
    workspace_id = "w1",
    tab_id = "w1:t1",
    cwd = root,
  })
  eq(2, #scoped)
end)

test("clears a stale remembered pane and resolves a live replacement", function()
  targets.clear()
  local cfg = config.setup({ target_scope = "session", auto_select = true })
  targets.remember(cfg, { pane_id = "w1:stale", agent = "codex" })
  local original_snapshot = herdr.snapshot
  herdr.snapshot = function(_, callback)
    callback({
      agents = {
        { pane_id = "w2:live", workspace_id = "w2", tab_id = "w2:t1", agent = "claude", agent_status = "idle" },
      },
      workspaces = {},
      tabs = {},
    })
  end
  local resolved
  targets.resolve(cfg, { select = function() end }, {}, function(target)
    resolved = target
  end)
  herdr.snapshot = original_snapshot
  eq("w2:live", resolved.pane_id)
  eq("w2:live", targets.selected().pane_id)
end)

local function read_log(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function stage_and_wait(cfg, target, payload)
  local done, values = false, nil
  transport.stage(cfg, target, payload, function(...)
    values = { n = select("#", ...), ... }
    done = true
  end)
  truthy(
    vim.wait(3000, function()
      return done
    end),
    "transport callback timed out"
  )
  return unpack(values, 1, values.n)
end

test("default transport wraps Codex multiline input and never presses Enter", function()
  local log = vim.fn.tempname()
  vim.fn.writefile({}, log)
  vim.env.FAKE_HERDR_LOG = log
  local cfg = config.setup({ herdr_bin = vim.fn.getcwd() .. "/tests/fixtures/fake-herdr.sh" })
  local ok, err, result = stage_and_wait(cfg, { pane_id = "w1:p2", agent = "codex" }, "line one\nline two")
  truthy(ok, err)
  eq("bracketed_paste", result.mode)
  local output = read_log(log)
  contains(output, "agent send")
  truthy(not output:find("pane send%-keys"), "default transport must not send Enter")
  contains(output, "text=1b5b3230307e")
  contains(output, "1b5b3230317e")
  vim.fn.delete(log)
end)

test("unknown agents receive a single-line context-file reference", function()
  local log = vim.fn.tempname()
  vim.fn.writefile({}, log)
  vim.env.FAKE_HERDR_LOG = log
  local directory = vim.fn.tempname()
  local cfg = config.setup({
    herdr_bin = vim.fn.getcwd() .. "/tests/fixtures/fake-herdr.sh",
    context_file_dir = directory,
  })
  local ok, err, result = stage_and_wait(cfg, { pane_id = "w1:p3", agent = "other" }, "one\ntwo")
  truthy(ok, err)
  eq("context_file", result.mode)
  eq(1, vim.fn.filereadable(result.context_file))
  eq("one\ntwo", table.concat(vim.fn.readfile(result.context_file), "\n"))
  local output = read_log(log)
  truthy(not output:find("0a"), "staged fallback text must be a single line")
  truthy(not output:find("pane send%-keys"), "fallback must not submit")
  vim.fn.delete(log)
  vim.fn.delete(directory, "rf")
end)

test("submission is a separate explicit opt-in command", function()
  local log = vim.fn.tempname()
  vim.fn.writefile({}, log)
  vim.env.FAKE_HERDR_LOG = log
  local cfg = config.setup({
    herdr_bin = vim.fn.getcwd() .. "/tests/fixtures/fake-herdr.sh",
    submit = true,
  })
  local ok, err = stage_and_wait(cfg, { pane_id = "w1:p2", agent = "codex" }, "@file.lua#L1")
  truthy(ok, err)
  contains(read_log(log), "pane send-keys")
  vim.fn.delete(log)
end)

test("reports invalid Herdr JSON and stopped-server errors", function()
  local log = vim.fn.tempname()
  vim.fn.writefile({}, log)
  vim.env.FAKE_HERDR_LOG = log
  local cfg = config.setup({ herdr_bin = vim.fn.getcwd() .. "/tests/fixtures/fake-herdr.sh" })

  vim.env.FAKE_HERDR_MODE = "invalid-json"
  local snapshot, invalid_err = herdr.snapshot(cfg)
  eq(nil, snapshot)
  contains(invalid_err, "invalid JSON")

  vim.env.FAKE_HERDR_MODE = "failure"
  snapshot, invalid_err = herdr.snapshot(cfg)
  eq(nil, snapshot)
  contains(invalid_err, "server is stopped")

  vim.env.FAKE_HERDR_MODE = nil
  vim.fn.delete(log)
end)

test("reports a missing Herdr executable instead of throwing", function()
  local output, err = herdr.run({ herdr_bin = "/definitely/missing/herdr" }, { "api", "snapshot" })
  eq(nil, output)
  contains(err, "Could not start Herdr")
end)

test("registers all user commands", function()
  for _, name in ipairs({
    "HerdrContextReference",
    "HerdrContextSend",
    "HerdrContextDiagnostics",
    "HerdrContextTarget",
  }) do
    eq(2, vim.fn.exists(":" .. name), name)
  end
end)

print(("1..%d"):format(total))
if #failures > 0 then
  print("\nFailures:")
  for _, failure in ipairs(failures) do
    print(("\n%s\n%s"):format(failure.name, failure.err))
  end
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
