local M = {}

local config = require("herdr-context.config")
local herdr = require("herdr-context.herdr")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")

local health = vim.health or require("health")

local function has_version(major, minor)
  local version = vim.version()
  return version.major > major or (version.major == major and version.minor >= minor)
end

local function check_environment()
  if vim.env.HERDR_ENV == "1" then
    health.ok("HERDR_ENV=1")
  else
    health.warn("HERDR_ENV is not set; start Neovim inside a Herdr pane")
  end

  for _, name in ipairs({ "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID" }) do
    if vim.env[name] and vim.env[name] ~= "" then
      health.ok(name .. "=" .. vim.env[name])
    else
      health.warn(name .. " is missing; target ranking will be less precise")
    end
  end
end

local function check_companion(cfg)
  local output, err = herdr.run(cfg, { "plugin", "list", "--plugin", "herdr-context", "--json" })
  if not output then
    health.warn("Could not inspect the Herdr companion plugin: " .. err)
    return
  end
  if output:find('"herdr%-context"') or output:find('"id"%s*:%s*"herdr%-context"') then
    health.ok("Herdr companion plugin is installed")
    if vim.fn.executable("jq") == 1 then
      health.ok("jq is available for the companion target picker")
    else
      health.warn("jq is missing; install it to use the companion target picker")
    end
  else
    health.warn("Herdr companion plugin is not installed; run `herdr plugin install makyinmars/herdr-context.nvim`")
  end
end

local function check_providers(cfg)
  local count = #require("herdr-context.providers").list()
  health.ok(("Context composer has %d registered provider%s"):format(count, count == 1 and "" or "s"))

  if cfg.providers.symbol.enabled then
    local lsp = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = 0 }) or vim.lsp.get_active_clients({ bufnr = 0 })
    local supports_symbols = false
    for _, client in ipairs(lsp) do
      local ok, supported = pcall(client.supports_method, client, "textDocument/documentSymbol")
      supports_symbols = supports_symbols or (ok and supported)
    end
    if supports_symbols then
      health.ok("Symbol provider: LSP document symbols")
    elseif cfg.providers.symbol.treesitter_fallback then
      local ok = pcall(vim.treesitter.get_parser, 0)
      health.info(ok and "Symbol provider: Treesitter fallback" or "Symbol provider: no backend for current buffer")
    else
      health.info("Symbol provider: no backend for current buffer")
    end
  else
    health.info("Symbol provider is disabled")
  end

  local mini = package.loaded["mini.diff"] or _G.MiniDiff
  if mini and type(mini.get_buf_data) == "function" then
    health.ok("Hunk provider: MiniDiff (supports unsaved changes)")
  elseif vim.fn.executable("git") == 1 then
    health.info("Hunk provider: saved-buffer Git fallback; load MiniDiff for unsaved changes")
  else
    health.warn("Hunk provider has no available backend")
  end

  if not cfg.providers.trouble.enabled then
    health.info("Trouble provider is disabled")
  elseif package.loaded.trouble then
    health.ok("Trouble provider is loaded")
  else
    health.info("Trouble provider is optional and currently unloaded")
  end
end

function M.check()
  health.start("herdr-context.nvim")

  if has_version(0, 10) then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim >= 0.10 is required")
  end

  local cfg = config.get()
  check_providers(cfg)
  if not cfg.presence.enabled then
    health.info("Background presence is disabled")
  else
    local current = state.get()
    local socket_path = vim.env.HERDR_SOCKET_PATH
    if socket_path and socket_path ~= "" then
      if (vim.uv or vim.loop).fs_stat(socket_path) then
        health.ok("Herdr socket: " .. socket_path)
      else
        health.warn("HERDR_SOCKET_PATH does not exist: " .. socket_path)
      end
    elseif cfg.presence.socket then
      health.warn("HERDR_SOCKET_PATH is missing; presence will use polling")
    end
    local connection = current.connected and "connected" or "disconnected"
    local stale = current.stale and ", stale" or ""
    health.info(("Presence: %s (%s%s)"):format(current.mode, connection, stale))
  end

  local executable, path = herdr.executable(cfg)
  if not executable then
    health.error(("Herdr executable %q was not found; set `herdr_bin` in setup()"):format(path))
    check_environment()
    return
  end
  health.ok("Herdr executable: " .. path)
  check_environment()

  local snapshot, snapshot_err = herdr.snapshot(cfg)
  if not snapshot then
    health.error("Could not reach the Herdr server: " .. snapshot_err)
    return
  end
  health.ok(
    ("Connected to Herdr %s (protocol %s)"):format(snapshot.version or "unknown", snapshot.protocol or "unknown")
  )

  local candidates = targets.candidates(snapshot, { scope = cfg.target_scope })
  if #candidates > 0 then
    health.ok(("Found %d live target agent(s) in %s scope"):format(#candidates, cfg.target_scope))
  else
    health.warn(
      ('No live target agents found in %s scope; open an agent or use `target_scope = "session"`'):format(
        cfg.target_scope
      )
    )
  end

  check_companion(cfg)
  health.info("Shared target file: " .. targets.config_file())
end

return M
