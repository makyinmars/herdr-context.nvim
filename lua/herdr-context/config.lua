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
  composer = {
    layout = "float",
    width = 0.92,
    height = 0.8,
    checklist_width = 0.38,
    provider_timeout_ms = 1500,
    hunk_context_lines = 3,
    preview = true,
    defaults = {
      selection = true,
      symbol = true,
      hunk = true,
      diagnostics = true,
      quickfix = false,
      location_list = false,
      trouble = false,
    },
    presets = {
      debug = { "selection", "symbol", "hunk", "diagnostics" },
      review = { "hunk", "diagnostics", "quickfix", "trouble" },
      explain = { "selection", "symbol", "diagnostics" },
    },
  },
  safety = {
    enabled = true,
    confirm_warnings = true,
    exclude_patterns = { ".env", ".env.*", "*.pem", "*.key", "credentials*", "secrets*" },
    secret_patterns = {
      "AKIA[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d]",
      "-----BEGIN .-PRIVATE KEY-----",
      "api[_-]key%s*[:=]%s*%S+",
      "token%s*[:=]%s*%S+",
      "secret%s*[:=]%s*%S+",
      "password%s*[:=]%s*%S+",
    },
  },
  history = {
    enabled = true,
    max_entries = 20,
  },
  providers = {
    symbol = {
      enabled = true,
      lsp = true,
      treesitter_fallback = true,
    },
    hunk = {
      enabled = true,
      backends = { "mini_diff", "git" },
    },
    trouble = {
      enabled = true,
      modes = { "diagnostics", "quickfix" },
    },
  },
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
    preview_lines = 80,
    group_by = "workspace",
    side_preview = true,
    preview_width = 64,
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
    composer = { opts.composer, "table" },
    safety = { opts.safety, "table" },
    history = { opts.history, "table" },
    providers = { opts.providers, "table" },
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
    ["agents_view.preview_lines"] = { opts.agents_view.preview_lines, "number" },
    ["agents_view.group_by"] = { opts.agents_view.group_by, "string" },
    ["agents_view.side_preview"] = { opts.agents_view.side_preview, "boolean" },
    ["agents_view.preview_width"] = { opts.agents_view.preview_width, "number" },
    ["agents_view.show_cwd"] = { opts.agents_view.show_cwd, "boolean" },
    ["agents_view.show_workspace"] = { opts.agents_view.show_workspace, "boolean" },
    ["agents_view.show_tab"] = { opts.agents_view.show_tab, "boolean" },
    ["statusline.show_target"] = { opts.statusline.show_target, "boolean" },
    ["statusline.show_agent_count"] = { opts.statusline.show_agent_count, "boolean" },
    ["statusline.show_connection"] = { opts.statusline.show_connection, "boolean" },
    ["statusline.compact"] = { opts.statusline.compact, "boolean" },
    ["statusline.icons"] = { opts.statusline.icons, "table" },
    ["composer.layout"] = { opts.composer.layout, "string" },
    ["composer.width"] = { opts.composer.width, "number" },
    ["composer.height"] = { opts.composer.height, "number" },
    ["composer.checklist_width"] = { opts.composer.checklist_width, "number" },
    ["composer.provider_timeout_ms"] = { opts.composer.provider_timeout_ms, "number" },
    ["composer.hunk_context_lines"] = { opts.composer.hunk_context_lines, "number" },
    ["composer.preview"] = { opts.composer.preview, "boolean" },
    ["composer.defaults"] = { opts.composer.defaults, "table" },
    ["composer.presets"] = { opts.composer.presets, "table" },
    ["safety.enabled"] = { opts.safety.enabled, "boolean" },
    ["safety.confirm_warnings"] = { opts.safety.confirm_warnings, "boolean" },
    ["safety.exclude_patterns"] = { opts.safety.exclude_patterns, "table" },
    ["safety.secret_patterns"] = { opts.safety.secret_patterns, "table" },
    ["history.enabled"] = { opts.history.enabled, "boolean" },
    ["history.max_entries"] = { opts.history.max_entries, "number" },
    ["providers.symbol"] = { opts.providers.symbol, "table" },
    ["providers.symbol.enabled"] = { opts.providers.symbol.enabled, "boolean" },
    ["providers.symbol.lsp"] = { opts.providers.symbol.lsp, "boolean" },
    ["providers.symbol.treesitter_fallback"] = { opts.providers.symbol.treesitter_fallback, "boolean" },
    ["providers.hunk"] = { opts.providers.hunk, "table" },
    ["providers.hunk.enabled"] = { opts.providers.hunk.enabled, "boolean" },
    ["providers.hunk.backends"] = { opts.providers.hunk.backends, "table" },
    ["providers.trouble"] = { opts.providers.trouble, "table" },
    ["providers.trouble.enabled"] = { opts.providers.trouble.enabled, "boolean" },
    ["providers.trouble.modes"] = { opts.providers.trouble.modes, "table" },
  })

  if opts.max_payload_bytes <= 0 or opts.max_payload_bytes % 1 ~= 0 then
    error("herdr-context: max_payload_bytes must be a positive integer")
  end

  validate_choice("target_scope", opts.target_scope, { "tab", "workspace", "session" })
  validate_choice("remember_target", opts.remember_target, { "none", "session", "workspace" })
  validate_choice("multiline_strategy", opts.multiline_strategy, { "auto", "bracketed_paste", "context_file" })
  validate_choice("agents_view.position", opts.agents_view.position, { "left", "right" })
  validate_choice("agents_view.group_by", opts.agents_view.group_by, { "none", "workspace", "tab" })
  validate_choice("composer.layout", opts.composer.layout, { "float" })

  for _, key in ipairs({ "width", "height" }) do
    local value = opts.composer[key]
    if value <= 0 then
      error("herdr-context: composer." .. key .. " must be greater than zero")
    end
  end
  if opts.composer.checklist_width <= 0 or opts.composer.checklist_width >= 1 then
    error("herdr-context: composer.checklist_width must be between zero and one")
  end
  if opts.composer.provider_timeout_ms <= 0 or opts.composer.provider_timeout_ms % 1 ~= 0 then
    error("herdr-context: composer.provider_timeout_ms must be a positive integer")
  end
  if opts.composer.hunk_context_lines < 0 or opts.composer.hunk_context_lines % 1 ~= 0 then
    error("herdr-context: composer.hunk_context_lines must be a non-negative integer")
  end
  for name, value in pairs(opts.composer.defaults) do
    if type(value) ~= "boolean" then
      error("herdr-context: composer.defaults." .. tostring(name) .. " must be a boolean")
    end
  end
  for name, preset in pairs(opts.composer.presets) do
    if type(name) ~= "string" or name == "" or type(preset) ~= "table" then
      error("herdr-context: composer.presets must map non-empty names to provider lists")
    end
    for _, id in ipairs(preset) do
      if type(id) ~= "string" or id == "" then
        error("herdr-context: composer preset entries must be non-empty provider ids")
      end
    end
  end
  for _, key in ipairs({ "exclude_patterns", "secret_patterns" }) do
    for _, pattern in ipairs(opts.safety[key]) do
      if type(pattern) ~= "string" or pattern == "" then
        error("herdr-context: safety." .. key .. " entries must be non-empty strings")
      end
    end
  end
  if opts.history.max_entries <= 0 or opts.history.max_entries % 1 ~= 0 then
    error("herdr-context: history.max_entries must be a positive integer")
  end
  for _, backend in ipairs(opts.providers.hunk.backends) do
    validate_choice("providers.hunk.backends", backend, { "mini_diff", "git" })
  end
  for _, mode in ipairs(opts.providers.trouble.modes) do
    if type(mode) ~= "string" or mode == "" then
      error("herdr-context: providers.trouble.modes entries must be non-empty strings")
    end
  end

  for _, key in ipairs({ "poll_interval_ms", "reconnect_max_ms", "debounce_ms" }) do
    local value = opts.presence[key]
    if value <= 0 or value % 1 ~= 0 then
      error("herdr-context: presence." .. key .. " must be a positive integer")
    end
  end
  if opts.agents_view.width < 20 or opts.agents_view.width % 1 ~= 0 then
    error("herdr-context: agents_view.width must be an integer of at least 20")
  end
  if opts.agents_view.preview_lines <= 0 or opts.agents_view.preview_lines % 1 ~= 0 then
    error("herdr-context: agents_view.preview_lines must be a positive integer")
  end
  if opts.agents_view.preview_width < 20 or opts.agents_view.preview_width % 1 ~= 0 then
    error("herdr-context: agents_view.preview_width must be an integer of at least 20")
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
