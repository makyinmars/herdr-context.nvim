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
  })

  if opts.max_payload_bytes <= 0 or opts.max_payload_bytes % 1 ~= 0 then
    error("herdr-context: max_payload_bytes must be a positive integer")
  end

  validate_choice("target_scope", opts.target_scope, { "tab", "workspace", "session" })
  validate_choice("remember_target", opts.remember_target, { "none", "session", "workspace" })
  validate_choice("multiline_strategy", opts.multiline_strategy, { "auto", "bracketed_paste", "context_file" })
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
