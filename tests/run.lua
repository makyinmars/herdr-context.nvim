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
local socket = require("herdr-context.socket")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")
local transport = require("herdr-context.transport")
local watch = require("herdr-context.watch")
local provider_fixtures = dofile(vim.fn.getcwd() .. "/tests/fixtures/provider-inputs.lua")

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

test("passes file references literally for Codex and Claude without submitting", function()
  local reference = "@lua/plugins/herdr-context.lua#L13-L20"
  local log = vim.fn.tempname()
  vim.fn.writefile({}, log)
  vim.env.FAKE_HERDR_LOG = log
  local cfg = config.setup({
    herdr_bin = vim.fn.getcwd() .. "/tests/fixtures/fake-herdr.sh",
    submit = false,
  })
  for index, agent in ipairs({ "codex", "claude" }) do
    local target = { pane_id = "w0:p" .. tostring(index), agent = agent }
    local prepared, mode = transport.prepare(cfg, target, reference)
    eq(reference, prepared, agent)
    eq("literal", mode, agent)
    local ok, err, result = stage_and_wait(cfg, target, reference)
    truthy(ok, err)
    eq("literal", result.mode, agent)
  end
  local output = read_log(log)
  contains(output, "target=w0:p1")
  contains(output, "target=w0:p2")
  truthy(not output:find("pane send%-keys"), "file references must not submit")
  vim.fn.delete(log)
end)

test("default transport wraps Codex multiline input and never presses Enter", function()
  local log = vim.fn.tempname()
  vim.fn.writefile({}, log)
  vim.env.FAKE_HERDR_LOG = log
  local cfg = config.setup({ herdr_bin = vim.fn.getcwd() .. "/tests/fixtures/fake-herdr.sh" })
  local ok, err, result = stage_and_wait(cfg, { pane_id = "w1:p2", agent = "codex" }, "line one\nline two")
  truthy(ok, err)
  eq("bracketed_paste", result.mode)
  local output = read_log(log)
  contains(output, "pane send-text")
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

test("reads recent agent output with bounded text arguments", function()
  local seen
  local original_run = herdr.run
  herdr.run = function(_, args, callback)
    seen = args
    callback("first line\nsecond line\n", nil)
    return { kill = function() end }
  end
  local output
  herdr.read_agent({}, "w0:p9", { source = "recent-unwrapped", lines = 25 }, function(value, err)
    truthy(value, err)
    output = value
  end)
  herdr.run = original_run
  eq("first line\nsecond line\n", output)
  eq({
    "agent",
    "read",
    "w0:p9",
    "--source",
    "recent-unwrapped",
    "--lines",
    "25",
    "--format",
    "text",
  }, seen)
end)

test("normalizes state and returns immutable public snapshots", function()
  state._reset()
  state._replace({
    version = "0.7.5",
    protocol = 17,
    focused_workspace_id = "w0",
    focused_tab_id = "w0:t1",
    focused_pane_id = "w0:self",
    workspaces = { { workspace_id = "w0", label = "project" } },
    tabs = { { tab_id = "w0:t1", workspace_id = "w0", label = "api" } },
    agents = {
      {
        pane_id = "w0:pB",
        workspace_id = "w0",
        tab_id = "w0:t1",
        agent = "codex",
        agent_status = "idle",
      },
    },
  }, { connected = true, stale = false, mode = "socket" })

  local first = state.get()
  eq("codex", first.agents_by_pane["w0:pB"].agent)
  eq("project", first.agents_by_pane["w0:pB"].workspace_label)
  eq("api", first.agents_by_pane["w0:pB"].tab_label)
  first.agents_by_pane["w0:pB"].agent = "mutated"
  first.agents[1].agent = "mutated"
  eq("codex", state.get().agents_by_pane["w0:pB"].agent)
end)

test("filters cached agents and cleans up state subscribers", function()
  state._reset()
  local updates = 0
  local subscriber = state.subscribe(function()
    updates = updates + 1
  end)
  local raw = {
    focused_workspace_id = "w0",
    focused_tab_id = "w0:t1",
    agents = {
      { pane_id = "self", workspace_id = "w0", tab_id = "w0:t1", agent = "codex" },
      { pane_id = "tab", workspace_id = "w0", tab_id = "w0:t1", agent = "codex" },
      { pane_id = "workspace", workspace_id = "w0", tab_id = "w0:t2", agent = "claude" },
      { pane_id = "session", workspace_id = "w1", tab_id = "w1:t1", agent = "codex" },
    },
  }
  state._replace(raw, { connected = true, mode = "socket" })
  eq(1, updates)
  eq(2, #state.agents({ scope = "tab", pane_id = "self", tab_id = "w0:t1" }))
  eq(3, #state.agents({ scope = "workspace", pane_id = "self", workspace_id = "w0" }))
  eq(4, #state.agents({ scope = "session", pane_id = "self" }))
  eq(3, #state.agents({ scope = "session", pane_id = "self", exclude_current = true }))
  state.unsubscribe(subscriber)
  state._set_connection({ stale = true })
  eq(1, updates)
end)

test("deduplicates concurrent state refresh requests", function()
  state._reset()
  local starts = 0
  local finish
  local callbacks = 0
  state._set_refresher(function(_, done)
    starts = starts + 1
    finish = done
  end)
  state.refresh({}, function(current, err)
    truthy(current, err)
    callbacks = callbacks + 1
  end)
  state.refresh({ force = true }, function(current, err)
    truthy(current, err)
    callbacks = callbacks + 1
  end)
  eq(1, starts)
  eq(0, callbacks)
  finish(state.get(), nil)
  eq(2, callbacks)
  state._set_refresher(nil)
end)

test("emits status and target User events with event data", function()
  state._reset()
  local status_event
  local target_event
  local connected_event
  local disconnected_event
  local group = vim.api.nvim_create_augroup("HerdrContextTestEvents", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HerdrContextAgentStatusChanged",
    callback = function(args)
      status_event = args.data
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HerdrContextConnected",
    callback = function(args)
      connected_event = args.data
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HerdrContextDisconnected",
    callback = function(args)
      disconnected_event = args.data
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HerdrContextTargetChanged",
    callback = function(args)
      target_event = args.data
    end,
  })
  local raw = {
    agents = { { pane_id = "w0:p1", agent = "codex", agent_status = "working" } },
  }
  state._replace(raw, { connected = true, mode = "socket" })
  eq("socket", connected_event.mode)
  raw.agents[1].agent_status = "idle"
  state._replace(raw, { connected = true, mode = "socket" })
  state.set_target("w0:p1")
  state._set_connection({ connected = false, stale = true, mode = "polling" })
  eq("w0:p1", status_event.pane_id)
  eq("working", status_event.previous_status)
  eq("idle", status_event.status)
  eq("w0:p1", target_event.pane_id)
  eq("polling", disconnected_event.mode)
  eq(true, disconnected_event.stale)
  vim.api.nvim_del_augroup_by_id(group)
end)

test("sends only opted-in agent status notifications", function()
  local notifications = require("herdr-context.notifications")
  state._reset()
  config.setup({
    presence = {
      enabled = true,
      notifications = { idle = true, blocked = false },
    },
  })
  notifications.setup()
  local messages = {}
  local original_notify = vim.notify
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  local raw = {
    agents = { { pane_id = "w0:p1", agent = "codex", agent_status = "working" } },
  }
  state._replace(raw, { connected = true, mode = "socket" })
  eq(0, #messages, "initial snapshot must not notify")
  raw.agents[1].agent_status = "idle"
  state._replace(raw, { connected = true, mode = "socket" })
  raw.agents[1].agent_status = "blocked"
  state._replace(raw, { connected = true, mode = "socket" })
  eq(1, #messages)
  contains(messages[1].message, "Herdr codex (w0:p1) is idle")
  eq(vim.log.levels.INFO, messages[1].level)

  config.setup({
    presence = {
      enabled = true,
      notifications = { idle = false, blocked = true },
    },
  })
  notifications.setup()
  raw.agents[1].agent_status = "working"
  state._replace(raw, { connected = true, mode = "socket" })
  raw.agents[1].agent_status = "blocked"
  state._replace(raw, { connected = true, mode = "socket" })
  vim.notify = original_notify
  notifications.stop()
  eq(2, #messages)
  contains(messages[2].message, "Herdr codex (w0:p1) is blocked")
  eq(vim.log.levels.WARN, messages[2].level)
end)

test("decodes fragmented and batched socket messages", function()
  local messages = {}
  local errors = {}
  local decoder = socket.decoder(function(message)
    messages[#messages + 1] = message
  end, function(err, line)
    errors[#errors + 1] = { err = err, line = line }
  end)
  local fixture = table.concat(vim.fn.readfile(vim.fn.getcwd() .. "/tests/fixtures/socket-events.ndjson"), "\n") .. "\n"
  decoder.feed(fixture:sub(1, 23))
  decoder.feed(fixture:sub(24, 91))
  decoder.feed(fixture:sub(92))
  decoder.feed("not-json\n")
  decoder.feed('{"event":"partial"')
  decoder.finish()
  eq(3, #messages)
  eq("subscription_started", messages[1].result.type)
  eq("pane_agent_status_changed", messages[2].event)
  eq(2, #errors)
  contains(errors[1].err, "invalid JSON")
  contains(errors[2].err, "closed during")
end)

test("socket client reads NDJSON and suppresses callbacks after shutdown", function()
  local uv = vim.uv or vim.loop
  local path = "/tmp/herdr-context-test-" .. tostring(uv.os_getpid()) .. ".sock"
  vim.fn.delete(path)
  local messages = {}
  local errors = {}
  local closes = 0
  local server = uv.new_pipe(false)
  local bound, bind_err = server:bind(path)
  if not bound then
    server:close()
    vim.fn.delete(path)
    if tostring(bind_err):find("EPERM", 1, true) then
      return
    end
    fail(tostring(bind_err))
  end
  local peer
  server:listen(1, function(err)
    if err then
      errors[#errors + 1] = err
      return
    end
    peer = uv.new_pipe(false)
    server:accept(peer)
    peer:read_start(function(read_err, chunk)
      if read_err then
        errors[#errors + 1] = read_err
        return
      end
      if chunk then
        peer:write('{"sequence":')
        peer:write('1}\n{"sequence":2}\n')
      end
    end)
  end)

  local client
  client = socket.new({
    path = path,
    on_connect = function()
      client:write({ request = "subscribe" })
    end,
    on_message = function(message)
      messages[#messages + 1] = message
    end,
    on_error = function(err)
      errors[#errors + 1] = err
    end,
    on_close = function()
      closes = closes + 1
    end,
  })
  client:connect()
  truthy(
    vim.wait(500, function()
      return #messages == 2
    end),
    "socket client did not decode server writes: " .. vim.inspect({ messages = messages, errors = errors })
  )
  eq(1, messages[1].sequence)
  eq(2, messages[2].sequence)
  eq(0, #errors)
  client:close({ silent = true })
  if peer then
    peer:read_stop()
    peer:close()
  end
  server:close()
  vim.wait(20)
  eq(0, closes)
  vim.fn.delete(path)
end)

test("watcher debounces events and falls back to polling", function()
  state._reset()
  watch.stop({ silent = true })
  local old_env = {
    HERDR_ENV = vim.env.HERDR_ENV,
    HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
    HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
  }
  vim.env.HERDR_ENV = "1"
  vim.env.HERDR_SOCKET_PATH = "/tmp/herdr-context-fake.sock"
  vim.env.HERDR_PANE_ID = "self"

  local snapshot_count = 0
  local raw = {
    version = "0.7.5",
    protocol = 17,
    focused_workspace_id = "w0",
    focused_tab_id = "w0:t1",
    agents = {
      {
        pane_id = "w0:p1",
        workspace_id = "w0",
        tab_id = "w0:t1",
        agent = "codex",
        agent_status = "idle",
      },
    },
  }
  local function fake_snapshot(_, callback)
    snapshot_count = snapshot_count + 1
    callback(vim.deepcopy(raw), nil)
  end

  local sockets = {}
  local function fake_socket_new(opts)
    local fake = { opts = opts, writes = {}, closed = false }
    function fake:connect()
      self.opts.on_connect()
    end
    function fake:write(message)
      self.writes[#self.writes + 1] = message
      return true
    end
    function fake:close()
      self.closed = true
    end
    sockets[#sockets + 1] = fake
    return fake
  end

  local cfg = config.setup({
    presence = {
      enabled = true,
      socket = true,
      poll_interval_ms = 20,
      reconnect_max_ms = 30,
      debounce_ms = 10,
    },
  })
  watch.start(cfg, { snapshot = fake_snapshot, socket_new = fake_socket_new })
  eq(1, snapshot_count)
  eq(1, #sockets)
  eq("events.subscribe", sockets[1].writes[1].method)
  local subscriptions = sockets[1].writes[1].params.subscriptions
  truthy(vim.tbl_contains(
    vim.tbl_map(function(item)
      return item.type .. ":" .. (item.pane_id or "")
    end, subscriptions),
    "pane.agent_status_changed:w0:p1"
  ))

  sockets[1].opts.on_message({
    id = sockets[1].writes[1].id,
    result = { type = "subscription_started" },
  })
  eq(2, snapshot_count)
  eq("socket", state.get().mode)
  sockets[1].opts.on_message({ event = "pane_agent_status_changed", data = {} })
  sockets[1].opts.on_message({ event = "pane_agent_status_changed", data = {} })
  sockets[1].opts.on_message({ event = "pane_closed", data = {} })
  truthy(
    vim.wait(200, function()
      return snapshot_count == 3
    end),
    "event burst did not produce one refresh"
  )

  sockets[1].opts.on_close("eof")
  truthy(
    vim.wait(100, function()
      return state.get().mode == "polling" and snapshot_count >= 4
    end),
    "socket closure did not activate polling"
  )
  truthy(
    vim.wait(200, function()
      return #sockets == 2
    end),
    "socket reconnect was not attempted"
  )
  sockets[2].opts.on_message({
    id = sockets[2].writes[1].id,
    result = { type = "subscription_started" },
  })
  truthy(
    vim.wait(100, function()
      local current = state.get()
      return current.mode == "socket" and current.connected and not current.stale
    end),
    "successful reconnect did not restore socket mode"
  )
  local reconnected_count = snapshot_count
  vim.wait(60)
  eq(reconnected_count, snapshot_count, "polling continued after reconnect")
  watch.stop({ silent = true })
  local stopped_count = snapshot_count
  vim.wait(60)
  eq(stopped_count, snapshot_count, "poll callbacks continued after shutdown")

  vim.env.HERDR_ENV = old_env.HERDR_ENV
  vim.env.HERDR_SOCKET_PATH = old_env.HERDR_SOCKET_PATH
  vim.env.HERDR_PANE_ID = old_env.HERDR_PANE_ID
end)

test("renders the statusline entirely from cached state", function()
  local old_pane_id = vim.env.HERDR_PANE_ID
  vim.env.HERDR_PANE_ID = "self"
  local statusline = require("herdr-context.ui.statusline")
  local cfg = config.setup({ target_scope = "session" })
  local agent = { pane_id = "w0:p1", agent = "codex", agent_status = "idle" }
  local current = {
    connected = true,
    stale = false,
    mode = "socket",
    agents = { agent },
    agents_by_pane = { ["w0:p1"] = agent },
    target_pane_id = "w0:p1",
  }
  eq("Herdr ▶ ● codex · 1", statusline.render(cfg, current))
  agent.agent_status = "working"
  eq("Herdr ▶ ◉ codex · 1", statusline.render(cfg, current))
  agent.agent_status = "blocked"
  eq("Herdr ! blocked · 1", statusline.render(cfg, current))
  agent.agent_status = "idle"
  current.connected = false
  current.stale = true
  eq("Herdr × ▶ ● codex · 1", statusline.render(cfg, current))
  current.connected = true
  current.stale = false
  current.target_pane_id = "gone"
  eq("Herdr ○ 1", statusline.render(cfg, current))
  current.agents = {}
  current.agents_by_pane = {}
  eq("Herdr ○ 0", statusline.render(cfg, current))
  current.connected = false
  eq("Herdr × disconnected", statusline.render(cfg, current))

  current.connected = true
  current.agents = { agent }
  current.agents_by_pane = { ["w0:p1"] = agent }
  current.target_pane_id = "w0:p1"
  cfg = config.setup({
    target_scope = "session",
    statusline = { compact = true, icons = { idle = "I" } },
  })
  eq("▶ I codex · 1", statusline.render(cfg, current))

  cfg = config.setup({ presence = { enabled = false } })
  eq("", statusline.render(cfg, current))
  vim.env.HERDR_PANE_ID = old_pane_id
end)

test("renders the drawer with stable pane mappings and actions", function()
  state._reset()
  targets.clear()
  local old_env = {
    HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
    HERDR_WORKSPACE_ID = vim.env.HERDR_WORKSPACE_ID,
    HERDR_TAB_ID = vim.env.HERDR_TAB_ID,
  }
  vim.env.HERDR_PANE_ID = "self"
  vim.env.HERDR_WORKSPACE_ID = "w0"
  vim.env.HERDR_TAB_ID = "w0:t1"
  config.setup({
    target_scope = "workspace",
    agents_view = { width = 44 },
    presence = { enabled = false },
  })
  local raw = {
    focused_workspace_id = "w0",
    focused_tab_id = "w0:t1",
    workspaces = { { workspace_id = "w0", label = "project" } },
    tabs = {
      { tab_id = "w0:t1", workspace_id = "w0", label = "api" },
      { tab_id = "w0:t2", workspace_id = "w0", label = "web" },
    },
    agents = {
      {
        pane_id = "w0:p2",
        workspace_id = "w0",
        tab_id = "w0:t2",
        agent = "claude",
        agent_status = "working",
        cwd = "/tmp/project",
      },
      {
        pane_id = "w0:p1",
        workspace_id = "w0",
        tab_id = "w0:t1",
        agent = "codex",
        agent_status = "idle",
        cwd = "/tmp/project",
      },
    },
  }
  state._replace(raw, { connected = true, stale = false, mode = "socket" })
  local drawer = require("herdr-context.ui.agents")
  local drawer_buf = drawer.open()
  eq("nofile", vim.bo[drawer_buf].buftype)
  eq("wipe", vim.bo[drawer_buf].bufhidden)
  eq("herdr-context-agents", vim.bo[drawer_buf].filetype)
  local drawer_text = table.concat(vim.api.nvim_buf_get_lines(drawer_buf, 0, -1, false), "\n")
  contains(drawer_text, "project / api")
  contains(drawer_text, "project / web")
  local mapping = drawer._line_to_pane()
  local p2_line
  for line, pane_id in pairs(mapping) do
    if pane_id == "w0:p2" then
      p2_line = line
    end
  end
  truthy(p2_line)
  vim.api.nvim_win_set_cursor(0, { p2_line, 0 })
  drawer.select_target()
  eq("w0:p2", state.get().target_pane_id)

  local focused
  local original_focus = herdr.focus
  herdr.focus = function(_, pane_id, callback)
    focused = pane_id
    callback("", nil)
  end
  drawer.focus()
  herdr.focus = original_focus
  eq("w0:p2", focused)

  local read_request
  local original_read_agent = herdr.read_agent
  herdr.read_agent = function(_, pane_id, opts, callback)
    read_request = { pane_id = pane_id, opts = opts }
    callback("build passed\nready", nil)
    return { kill = function() end }
  end
  drawer.preview()
  herdr.read_agent = original_read_agent
  local preview = require("herdr-context.ui.preview")
  local active_preview = preview._active()
  truthy(active_preview)
  eq("w0:p2", read_request.pane_id)
  eq("recent-unwrapped", read_request.opts.source)
  eq(80, read_request.opts.lines)
  eq({ "build passed", "ready" }, vim.api.nvim_buf_get_lines(active_preview.bufnr, 0, -1, false))
  preview.close()

  local original_input = vim.ui.input
  vim.ui.input = function(_, callback)
    callback("claude")
  end
  drawer.filter()
  eq("claude", drawer._filter())
  local filtered = vim.tbl_values(drawer._line_to_pane())
  eq({ "w0:p2" }, filtered)
  vim.ui.input = function(_, callback)
    callback("")
  end
  drawer.filter()
  vim.ui.input = original_input

  raw.agents[1].agent_status = "idle"
  raw.agents[#raw.agents + 1] = {
    pane_id = "w0:p0",
    workspace_id = "w0",
    tab_id = "w0:t1",
    agent = "codex",
    agent_status = "idle",
    cwd = "/tmp/project",
  }
  state._replace(raw, { connected = true, stale = false, mode = "socket" })
  truthy(
    vim.wait(200, function()
      local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
      return drawer._line_to_pane()[cursor_line] == "w0:p2"
    end),
    "drawer did not preserve the selected pane under the cursor"
  )
  drawer.close()
  truthy(
    vim.wait(100, function()
      return not vim.api.nvim_buf_is_valid(drawer_buf)
    end),
    "drawer buffer was not wiped"
  )

  vim.env.HERDR_PANE_ID = old_env.HERDR_PANE_ID
  vim.env.HERDR_WORKSPACE_ID = old_env.HERDR_WORKSPACE_ID
  vim.env.HERDR_TAB_ID = old_env.HERDR_TAB_ID
end)

test("cancels superseded output previews and ignores stale callbacks", function()
  config.setup({ agents_view = { preview_lines = 12 } })
  local preview = require("herdr-context.ui.preview")
  local callbacks = {}
  local killed = {}
  local original_read_agent = herdr.read_agent
  herdr.read_agent = function(_, pane_id, opts, callback)
    callbacks[pane_id] = callback
    eq(12, opts.lines)
    return {
      kill = function(_, signal)
        killed[pane_id] = signal
      end,
    }
  end

  preview.open({ pane_id = "w0:p1", agent = "codex" })
  preview.open({ pane_id = "w0:p2", agent = "claude" })
  eq(15, killed["w0:p1"])
  callbacks["w0:p1"]("stale output", nil)
  callbacks["w0:p2"]("fresh output", nil)
  local active_preview = preview._active()
  eq({ "fresh output" }, vim.api.nvim_buf_get_lines(active_preview.bufnr, 0, -1, false))
  preview.close()
  herdr.read_agent = original_read_agent
end)

test("builds deterministic exact bundles with safe fences and deduplication", function()
  local bundle = require("herdr-context.bundle")
  local built = bundle.build({
    {
      id = "diagnostics",
      title = "Diagnostics",
      priority = 30,
      format = "diagnostics",
      items = {
        { severity = vim.diagnostic.severity.ERROR, source = "lua", code = 12, lnum = 3, message = "Bad\nvalue" },
      },
      fingerprint = "diagnostics:one",
    },
    {
      id = "symbol",
      title = "Current symbol",
      priority = 20,
      reference = "@lua/sample.lua#L2-L4",
      language = "lua",
      content = "local marker = [[```]]",
      format = "code",
      fingerprint = "symbol:one",
    },
    {
      id = "symbol-copy",
      title = "Duplicate",
      priority = 1,
      content = "must not render",
      format = "text",
      fingerprint = "symbol:one",
    },
  }, 64 * 1024)
  truthy(built)
  eq(2, #built.sections)
  eq(#built.payload, built.bytes)
  truthy(built.payload:find("## Current symbol", 1, true) < built.payload:find("## Diagnostics", 1, true))
  contains(built.payload, "````lua\nlocal marker = [[```]]\n````")
  contains(built.payload, "- ERROR [lua:12] L4: Bad value")
  truthy(not built.payload:find("must not render", 1, true))

  local oversized = bundle.build(built.sections, 8)
  eq(true, oversized.oversized)
  contains(oversized.error, tostring(oversized.bytes))
end)

test("excludes sensitive paths and detects secret-like content", function()
  local safety = require("herdr-context.safety")
  config.setup({})
  local excluded, pattern = safety.excluded_path("config/.env")
  eq(true, excluded)
  eq(".env", pattern)
  local section, reason = safety.sanitize({
    id = "selection",
    title = "Environment",
    format = "code",
    content = "PASSWORD=hunter2",
    reference = "@config/.env#L1",
    fingerprint = "env",
  }, {})
  eq(nil, section)
  contains(reason, "Excluded config/.env")
  local warnings = safety.scan({
    {
      id = "instructions",
      title = "Instructions",
      format = "text",
      content = "password = hunter2",
    },
  })
  eq(1, #warnings)
  contains(warnings[1], "may contain a secret")
end)

test("bounds immutable session history and renders it", function()
  local history = require("herdr-context.history")
  local history_ui = require("herdr-context.ui.history")
  config.setup({ history = { enabled = true, max_entries = 2 } })
  history._reset()
  for index = 1, 3 do
    history.record({
      kind = "test" .. index,
      target = { pane_id = "w0:p" .. index, agent = "codex" },
      payload = "payload " .. index,
      bytes = 9,
    })
  end
  local entries = history.get()
  eq(2, #entries)
  eq("test3", entries[1].kind)
  eq("test2", entries[2].kind)
  entries[1].kind = "mutated"
  eq("test3", history.get()[1].kind)
  local history_buf = history_ui.open()
  eq("herdr-context-history", vim.bo[history_buf].filetype)
  local rendered = table.concat(vim.api.nvim_buf_get_lines(history_buf, 0, -1, false), "\n")
  contains(rendered, "test3")
  contains(rendered, "w0:p3")
  history_ui.toggle()
end)

test("deduplicates matching quickfix and Trouble items without dropping sections", function()
  local bundle = require("herdr-context.bundle")
  local item = { path = "src/main.lua", line = 4, column = 2, type = "E", message = "Broken" }
  local built = bundle.build({
    {
      id = "quickfix",
      title = "Quickfix",
      priority = 40,
      format = "list",
      items = { item },
      fingerprint = "quickfix:list",
    },
    {
      id = "trouble",
      title = "Trouble",
      priority = 60,
      format = "list",
      items = { vim.tbl_extend("force", item, { severity = "ERROR", type = nil }) },
      fingerprint = "trouble:list",
    },
  }, 10000)
  eq(2, #built.sections)
  eq(1, #built.sections[1].items)
  eq(0, #built.sections[2].items)
  contains(built.payload, "## Trouble")
  contains(built.payload, "No unique valid items")
end)

test("isolates provider timeouts, cancellation, and repeated callbacks", function()
  local registry = require("herdr-context.providers")
  registry._reset()
  local cancelled = 0
  registry.register({
    id = "test-fast",
    name = "Fast",
    collect = function(_, callback)
      vim.defer_fn(function()
        callback({ id = "test-fast", title = "Fast", content = "first", format = "text" })
        callback({ id = "test-fast", title = "Fast", content = "second", format = "text" })
      end, 1)
    end,
  })
  registry.register({
    id = "test-timeout",
    name = "Timeout",
    collect = function()
      return function()
        cancelled = cancelled + 1
      end
    end,
  })
  local result
  registry.collect({}, { ids = { "test-fast", "test-timeout" }, timeout_ms = 15 }, function(entries)
    result = entries
  end)
  truthy(
    vim.wait(200, function()
      return result ~= nil
    end),
    "provider collection did not complete"
  )
  local by_id = {}
  for _, entry in ipairs(result) do
    by_id[entry.id] = entry
  end
  eq("available", by_id["test-fast"].status)
  eq("first", by_id["test-fast"].section.content)
  eq("failed", by_id["test-timeout"].status)
  contains(by_id["test-timeout"].error, "Timed out")
  eq(1, cancelled)
end)

test("selects the innermost deterministic LSP document symbol", function()
  local symbol = require("herdr-context.providers.symbol")
  local bufnr = buffer({ "outer", "inner", "body", "end", "done" }, vim.fn.getcwd() .. "/src/symbol.lua")
  local request = {
    bufnr = bufnr,
    cursor = { 3, 1 },
    path = vim.api.nvim_buf_get_name(bufnr),
    relative_path = "src/symbol.lua",
    filetype = "lua",
    modified = true,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
  }
  local old_get_clients = vim.lsp.get_clients
  local function client(id, name, result)
    return {
      id = id,
      name = name,
      supports_method = function()
        return true
      end,
      request = function(_, _, _, handler)
        handler(nil, result)
        return true, id
      end,
      cancel_request = function() end,
    }
  end
  vim.lsp.get_clients = function()
    return {
      client(2, "z-client", provider_fixtures.lsp.document_symbols),
      client(1, "a-client", provider_fixtures.lsp.symbol_information),
    }
  end
  config.setup({ providers = { symbol = { lsp = true, treesitter_fallback = false } } })
  local section, symbol_err
  symbol.collect(request, function(value, err)
    section, symbol_err = value, err
  end)
  vim.lsp.get_clients = old_get_clients
  truthy(section, symbol_err)
  eq("inner-a", section.symbol_name)
  eq("L2-L4", section.summary:match("L%d+%-L%d+"))
  eq("inner\nbody\nend", section.content)
  delete_buffer(bufnr)
end)

test("renders MiniDiff change, add, and zero-line delete hunks", function()
  local mini = require("herdr-context.providers.hunk.mini_diff")
  local bufnr = buffer({ "one", "new", "three" })
  local request = { bufnr = bufnr }
  local changed = mini.render(request, { ref_text = "one\nold\nthree\n" }, provider_fixtures.mini_diff.change, 1)
  eq("@@ -1,3 +1,3 @@\n one\n-old\n+new\n three", changed)

  local added = mini.render(request, { ref_text = "one\nthree\n" }, provider_fixtures.mini_diff.add, 1)
  contains(added, "+new")
  eq("add", mini.find_hunk({ { buf_start = 2, buf_count = 1, type = "add" } }, 2).type)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "three" })
  local deleted = mini.render(request, { ref_text = "one\nold\nthree\n" }, provider_fixtures.mini_diff.delete, 1)
  contains(deleted, "-old")
  eq("delete", mini.find_hunk({ { buf_start = 0, buf_count = 0, type = "delete" } }, 1).type)
  delete_buffer(bufnr)
end)

test("parses and locates saved Git diff hunks", function()
  local git_hunk = require("herdr-context.providers.hunk.git")
  local hunks = git_hunk.parse_hunks(table.concat({
    "diff --git a/a.lua b/a.lua",
    "--- a/a.lua",
    "+++ b/a.lua",
    "@@ -2,2 +2,3 @@ function demo()",
    " same",
    "-old",
    "+new",
    "+more",
    "@@ -10 +11,0 @@",
    "-gone",
  }, "\n"))
  eq(2, #hunks)
  eq(3, hunks[1].new_count)
  eq(1, hunks[2].old_count)
  eq(0, hunks[2].new_count)
  local first, start_line, end_line = git_hunk.find_hunk(hunks, 4)
  truthy(first)
  eq(2, start_line)
  eq(4, end_line)
  truthy(git_hunk.find_hunk(hunks, 11))
end)

test("normalizes quickfix lists and reports invalid entries", function()
  local quickfix = require("herdr-context.providers.quickfix").providers[1]
  local bufnr = buffer({ "bad" }, vim.fn.getcwd() .. "/src/quickfix.lua")
  vim.fn.setqflist({}, " ", {
    title = "Build errors",
    items = {
      { bufnr = bufnr, lnum = 1, col = 2, type = "E", text = "Bad\nvalue" },
      { valid = 0, text = "invalid" },
    },
  })
  local section, qf_err
  quickfix.collect({ cwd = vim.fn.getcwd(), winid = vim.api.nvim_get_current_win() }, function(value, err)
    section, qf_err = value, err
  end)
  truthy(section, qf_err)
  eq("Build errors", section.title)
  eq(1, #section.items)
  eq(1, section.invalid_count)
  eq("src/quickfix.lua", section.items[1].path)
  eq("Bad value", section.items[1].message)
  vim.fn.setqflist({}, "f")
  delete_buffer(bufnr)
end)

test("normalizes loaded Trouble views and stays optional when absent", function()
  local trouble_provider = require("herdr-context.providers.trouble")
  local old_trouble = package.loaded.trouble
  config.setup({ providers = { trouble = { enabled = true, modes = { "diagnostics", "quickfix" } } } })
  package.loaded.trouble = nil
  local available, reason = trouble_provider.available()
  eq(false, available)
  contains(reason, "not loaded")

  package.loaded.trouble = {
    is_open = function(mode)
      return mode == "diagnostics"
    end,
    get_items = function()
      return provider_fixtures.trouble
    end,
  }
  available = trouble_provider.available()
  local section, trouble_err
  trouble_provider.collect({ cwd = vim.fn.getcwd() }, function(value, err)
    section, trouble_err = value, err
  end)
  package.loaded.trouble = old_trouble
  eq(true, available)
  truthy(section, trouble_err)
  eq(1, #section.items)
  eq("src/trouble.lua", section.items[1].path)
  eq(8, section.items[1].line)
  eq("ERROR", section.items[1].severity)
end)

test("marks composer payloads stale and renders exact preview in a native scratch buffer", function()
  local bundle = require("herdr-context.bundle")
  local composer = require("herdr-context.composer")
  local composer_ui = require("herdr-context.ui.composer")
  config.setup({ submit = true, presence = { enabled = false } })
  local source = buffer({ "return true" }, vim.fn.getcwd() .. "/lua/composer-test.lua")
  vim.api.nvim_set_current_buf(source)
  local request = composer.capture_request({ bufnr = source, winid = vim.api.nvim_get_current_win(), line = 1 })
  local session = composer._create_session(request)
  session.entries = {
    {
      id = "selection",
      name = "Current line",
      status = "available",
      section = {
        id = "selection",
        title = "Current line",
        priority = 10,
        reference = "@lua/composer-test.lua#L1",
        language = "lua",
        content = "return true",
        format = "code",
        fingerprint = "selection:test",
      },
    },
  }
  session.selected.selection = true
  session.bundle = bundle.build({ session.entries[1].section }, config.get().max_payload_bytes)
  local ui_buf = composer_ui.open(session)
  eq("nofile", vim.bo[ui_buf].buftype)
  eq("wipe", vim.bo[ui_buf].bufhidden)
  eq(false, vim.bo[ui_buf].swapfile)
  eq("herdr-context-composer", vim.bo[ui_buf].filetype)
  local active_composer = composer_ui._active()
  truthy(active_composer.list_winid ~= active_composer.preview_winid)
  eq("herdr-context-preview", vim.bo[active_composer.preview_bufnr].filetype)
  local rendered = table.concat(vim.api.nvim_buf_get_lines(ui_buf, 0, -1, false), "\n")
  local preview_rendered = table.concat(vim.api.nvim_buf_get_lines(active_composer.preview_bufnr, 0, -1, false), "\n")
  contains(preview_rendered, session.bundle.payload)
  contains(rendered, "s stage + submit")
  local instruction_ui = require("herdr-context.ui.instruction")
  local instruction_buf = instruction_ui.open(session)
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(instruction_buf, 0, -1, false, { "Keep the public API stable", "Add focused tests" })
  instruction_ui.save()
  truthy(vim.wait(100, function()
    local payload = table.concat(vim.api.nvim_buf_get_lines(active_composer.preview_bufnr, 0, -1, false), "\n")
    return payload:find("## Instructions", 1, true) ~= nil
  end))
  contains(session.bundle.payload, "Keep the public API stable")
  contains(session.bundle.payload, "Add focused tests")

  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "return false" })
  eq(true, session:is_stale())
  local original_transport_stage = transport.stage
  local stage_calls = 0
  transport.stage = function()
    stage_calls = stage_calls + 1
  end
  session:stage()
  transport.stage = original_transport_stage
  eq(0, stage_calls)
  session:close()
  delete_buffer(source)
end)

test("applies presets, requires sensitive-content confirmation, and records successful staging", function()
  local bundle = require("herdr-context.bundle")
  local composer = require("herdr-context.composer")
  local history = require("herdr-context.history")
  config.setup({
    history = { enabled = true, max_entries = 20 },
    composer = { presets = { secure = { "selection" } } },
  })
  history._reset()
  local source = buffer({ "password = hunter2" }, vim.fn.getcwd() .. "/lua/sensitive-test.lua")
  local request = composer.capture_request({ bufnr = source, winid = vim.api.nvim_get_current_win(), line = 1 })
  local session = composer._create_session(request)
  session.entries = {
    {
      id = "selection",
      name = "Current line",
      status = "available",
      section = {
        id = "selection",
        title = "Current line",
        priority = 10,
        reference = "@lua/sensitive-test.lua#L1",
        language = "lua",
        content = "password = hunter2",
        format = "code",
        fingerprint = "selection:sensitive",
      },
    },
  }
  eq(true, session:apply_preset("secure"))
  eq(true, session.selected.selection)
  truthy(session.bundle and session.bundle.payload)
  eq(1, #session.safety_warnings)

  local resolve_calls = 0
  local stage_calls = 0
  local original_resolve = targets.resolve
  local original_stage = transport.stage
  targets.resolve = function(_, _, _, callback)
    resolve_calls = resolve_calls + 1
    callback({ pane_id = "w0:p9", agent = "codex" })
  end
  transport.stage = function(_, _, _, callback)
    stage_calls = stage_calls + 1
    callback(true, nil, { mode = "literal" })
  end
  session:stage()
  eq(0, resolve_calls, "first stage should only confirm the warning")
  eq(true, session.safety_confirmed)
  session:stage()
  targets.resolve = original_resolve
  transport.stage = original_stage
  eq(1, resolve_calls)
  eq(1, stage_calls)
  eq(1, #history.get())
  eq("composer", history.get()[1].kind)
  delete_buffer(source)
end)

test("applies mode-aware composer defaults and current-line fallback", function()
  local composer = require("herdr-context.composer")
  config.setup({})
  local function entries()
    return {
      {
        id = "selection",
        name = "Current line",
        status = "available",
        section = { range = { start_line = 7, end_line = 7 } },
      },
      {
        id = "symbol",
        name = "Current symbol",
        status = "available",
        section = { range = { start_line = 4, end_line = 12 } },
      },
      {
        id = "hunk",
        name = "Current hunk",
        status = "available",
        section = { range = { start_line = 6, end_line = 9 } },
      },
      {
        id = "diagnostics",
        name = "Diagnostics",
        status = "available",
        section = { range = { start_line = 7, end_line = 7 } },
      },
    }
  end

  local normal = {
    request = { selection = nil },
    entries = entries(),
  }
  composer._apply_defaults(normal)
  eq(true, normal.selected.symbol)
  eq(true, normal.selected.hunk)
  eq(nil, normal.selected.selection)
  eq(true, normal.selected.diagnostics)

  local visual = {
    request = { selection = { mode = "v" } },
    entries = entries(),
  }
  composer._apply_defaults(visual)
  eq(true, visual.selected.selection)
  eq(nil, visual.selected.symbol)
  eq(nil, visual.selected.hunk)
  eq(true, visual.selected.diagnostics)

  normal.entries[2].status = "unavailable"
  normal.entries[3].status = "unavailable"
  composer._apply_defaults(normal)
  eq(true, normal.selected.selection)
end)

test("registers all user commands", function()
  for _, name in ipairs({
    "HerdrContextReference",
    "HerdrContextSend",
    "HerdrContextDiagnostics",
    "HerdrContextCompose",
    "HerdrContextSymbol",
    "HerdrContextHunk",
    "HerdrContextQuickfix",
    "HerdrContextLocationList",
    "HerdrContextTarget",
    "HerdrContextAgents",
    "HerdrContextHistory",
    "HerdrContextRefresh",
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
