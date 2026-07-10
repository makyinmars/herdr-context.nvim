local M = {}

local defaults = {
  submit = false,
  focus_after_send = false,
  max_payload_bytes = 64 * 1024,
  target_scope = "workspace",
  remember_target = "session",
  auto_select = true,
  herdr_bin = nil,
  multiline_strategy = "auto",
  bracketed_paste_agents = {
    claude = true,
    codex = true,
  },
  context_file_dir = nil,
  presence = {
    enabled = true,
    socket = true,
    poll_interval_ms = 3000,
    reconnect_max_ms = 10000,
    debounce_ms = 100,
    notifications = {
      idle = false,
      blocked = false,
    },
  },
  agents_view = {
    position = "right",
    width = 44,
    show_cwd = true,
    show_workspace = true,
    show_tab = true,
  },
  statusline = {
    show_target = true,
    show_agent_count = true,
    show_connection = true,
    compact = false,
    icons = {
      herdr = "Herdr",
      target = "▶",
      idle = "●",
      working = "◉",
      blocked = "!",
      done = "●",
      unknown = "○",
      disconnected = "×",
      separator = "·",
    },
  },
}

local options = vim.deepcopy(defaults)

local function validate_choice(name, value, choices)
  if not vim.tbl_contains(choices, value) then
    error(("herdr-context: %s must be one of: %s"):format(name, table.concat(choices, ", ")))
  end
end

local function validate(opts)
  vim.validate({
    submit = { opts.submit, "boolean" },
    focus_after_send = { opts.focus_after_send, "boolean" },
    max_payload_bytes = { opts.max_payload_bytes, "number" },
    target_scope = { opts.target_scope, "string" },
    remember_target = { opts.remember_target, "string" },
    auto_select = { opts.auto_select, "boolean" },
    multiline_strategy = { opts.multiline_strategy, "string" },
    bracketed_paste_agents = { opts.bracketed_paste_agents, "table" },
    presence = { opts.presence, "table" },
    agents_view = { opts.agents_view, "table" },
    statusline = { opts.statusline, "table" },
    ["presence.enabled"] = { opts.presence.enabled, "boolean" },
    ["presence.socket"] = { opts.presence.socket, "boolean" },
    ["presence.poll_interval_ms"] = { opts.presence.poll_interval_ms, "number" },
    ["presence.reconnect_max_ms"] = { opts.presence.reconnect_max_ms, "number" },
    ["presence.debounce_ms"] = { opts.presence.debounce_ms, "number" },
    ["presence.notifications"] = { opts.presence.notifications, "table" },
    ["presence.notifications.idle"] = { opts.presence.notifications.idle, "boolean" },
    ["presence.notifications.blocked"] = { opts.presence.notifications.blocked, "boolean" },
    ["agents_view.position"] = { opts.agents_view.position, "string" },
    ["agents_view.width"] = { opts.agents_view.width, "number" },
    ["agents_view.show_cwd"] = { opts.agents_view.show_cwd, "boolean" },
    ["agents_view.show_workspace"] = { opts.agents_view.show_workspace, "boolean" },
    ["agents_view.show_tab"] = { opts.agents_view.show_tab, "boolean" },
    ["statusline.show_target"] = { opts.statusline.show_target, "boolean" },
    ["statusline.show_agent_count"] = { opts.statusline.show_agent_count, "boolean" },
    ["statusline.show_connection"] = { opts.statusline.show_connection, "boolean" },
    ["statusline.compact"] = { opts.statusline.compact, "boolean" },
    ["statusline.icons"] = { opts.statusline.icons, "table" },
  })

  if opts.max_payload_bytes <= 0 or opts.max_payload_bytes % 1 ~= 0 then
    error("herdr-context: max_payload_bytes must be a positive integer")
  end

  validate_choice("target_scope", opts.target_scope, { "tab", "workspace", "session" })
  validate_choice("remember_target", opts.remember_target, { "none", "session", "workspace" })
  validate_choice("multiline_strategy", opts.multiline_strategy, { "auto", "bracketed_paste", "context_file" })
  validate_choice("agents_view.position", opts.agents_view.position, { "left", "right" })

  for _, key in ipairs({ "poll_interval_ms", "reconnect_max_ms", "debounce_ms" }) do
    local value = opts.presence[key]
    if value <= 0 or value % 1 ~= 0 then
      error("herdr-context: presence." .. key .. " must be a positive integer")
    end
  end
  if opts.agents_view.width < 20 or opts.agents_view.width % 1 ~= 0 then
    error("herdr-context: agents_view.width must be an integer of at least 20")
  end
  for name, icon in pairs(opts.statusline.icons) do
    if type(icon) ~= "string" then
      error("herdr-context: statusline.icons." .. tostring(name) .. " must be a string")
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  vim.validate({ opts = { opts, "table" } })
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  validate(options)
  return options
end

function M.get()
  return options
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
