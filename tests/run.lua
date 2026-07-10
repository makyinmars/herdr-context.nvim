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

test("normalizes state and returns immutable public snapshots", function()
  state._reset()
  state._replace({
    version = "0.7.3",
    protocol = 16,
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
    version = "0.7.3",
    protocol = 16,
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

test("registers all user commands", function()
  for _, name in ipairs({
    "HerdrContextReference",
    "HerdrContextSend",
    "HerdrContextDiagnostics",
    "HerdrContextTarget",
    "HerdrContextAgents",
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
