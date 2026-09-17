# herdr-context.nvim

This plugin shows live [Herdr](https://herdr.dev) agents inside Neovim. You can stage file references in their prompts. Staging puts text in the prompt and does not submit it.

This repository has two parts. The Neovim plugin collects context and stages it. Context is the file references and related items that you attach.

The companion plugin is the Herdr-side plugin. It opens a short-lived popup so that you can pin the default target. A target is the destination agent pane.

## Requirements

You need:

- Neovim 0.10 or newer
- Herdr 0.9.1 or newer
- `jq` for the optional target picker popup on Linux and macOS
- Windows PowerShell 5.1 or newer for the optional picker on Windows.

Run Neovim in a Herdr pane. Then `HERDR_PANE_ID`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` are available.

## Installation

Install the Herdr side:

```sh
herdr plugin install makyinmars/herdr-context.nvim
```

Install the Neovim side with lazy.nvim:

```lua
{
  "makyinmars/herdr-context.nvim",
  cond = vim.env.HERDR_ENV == "1",
  lazy = false, -- keeps :checkhealth herdr-context discoverable before the first mapping
  opts = {},
  keys = {
    {
      "<leader>ac",
      function()
        require("herdr-context").compose()
      end,
      mode = { "n", "v" },
      desc = "Compose Herdr Context",
    },
    {
      "<leader>ap",
      function()
        require("herdr-context").prompt()
      end,
      mode = { "n", "v" },
      desc = "Prompt Herdr with Code Context",
    },
    {
      "<leader>ay",
      function()
        require("herdr-context").reference()
      end,
      mode = { "n", "v" },
      desc = "Send Reference to Herdr Agent",
    },
    {
      "<leader>aY",
      function()
        require("herdr-context").send()
      end,
      mode = { "n", "v" },
      desc = "Send Context to Herdr Agent",
    },
    {
      "<leader>ad",
      function()
        require("herdr-context").diagnostics()
      end,
      mode = { "n", "v" },
      desc = "Send Diagnostics to Herdr Agent",
    },
    {
      "<leader>at",
      function()
        require("herdr-context").select_target()
      end,
      desc = "Select Herdr Agent",
    },
    {
      "<leader>aa",
      function()
        require("herdr-context").agents()
      end,
      desc = "Toggle Herdr Agents",
    },
    {
      "<leader>ar",
      function()
        require("herdr-context").refresh()
      end,
      desc = "Refresh Herdr Agents",
    },
  },
}
```

If you develop locally, point both systems at the same checkout:

```sh
herdr plugin link /path/to/herdr-context.nvim
```

```lua
{
  dir = "/path/to/herdr-context.nvim",
  cond = vim.env.HERDR_ENV == "1",
  opts = {},
}
```

## Commands

| Command | Behavior |
| --- | --- |
| `:HerdrContextReference` | Stage `@path#L10-L20` |
| `:HerdrContextSend` | Stage the reference and selected code |
| `:HerdrContextDiagnostics` | Stage diagnostics for the current line or selection |
| `:HerdrContextCompose [preset]` | Open the composer to collect, preview, and stage context |
| `:HerdrContextPrompt` | Open the message editor with the current line or Visual selection attached |
| `:HerdrContextDelegate <kind> [preset]` | Create an agent and send a reviewed composer payload |
| `:HerdrContextSymbol` | Stage the innermost symbol under the cursor |
| `:HerdrContextHunk` | Stage the Git hunk under the cursor |
| `:HerdrContextQuickfix` | Stage the current quickfix list |
| `:HerdrContextLocationList` | Stage the current window location list |
| `:HerdrContextTarget` | Choose or change the destination agent |
| `:HerdrContextAgents` | Open or close the live agent drawer |
| `:HerdrContextExplainAgent` | Explain how Herdr detected an agent and assigned its state |
| `:HerdrContextHistory` | Inspect, clear, or restage session history |
| `:HerdrContextRefresh` | Refresh the cached Herdr state |
| `:checkhealth herdr-context` | Report Neovim, environment, Herdr, agents, and companion plugin status |

The agent drawer is a side window that lists live agents. Context commands that take a range accept an Ex range. An Ex range is a line range on the command. Lua calls from Visual mode keep linewise, characterwise, reversed, and blockwise selections.

## Configuration

```lua
require("herdr-context").setup({
  submit = false,
  focus_after_send = false,
  max_payload_bytes = 64 * 1024,
  target_scope = "workspace", -- "tab", "workspace", "project", or "session"
  remember_target = "session", -- "none", "session", or "workspace"
  min_herdr_version = "0.9.1",

  composer = {
    layout = "float",
    width = 0.56,
    height = 0.72,
    include = "reference", -- "reference" or "content"
    hide_empty = true,
    attach_empty_diagnostics = false,
    agent_picker = "inline", -- "inline" or "select"
    embed_unsaved = "ask", -- "ask", "always", or "never"
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
    secret_patterns = { -- Lua patterns
      "AKIA[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d]",
      "-----BEGIN .-PRIVATE KEY-----",
      "api[_-]key%s*[:=]%s*%S+",
      "token%s*[:=]%s*%S+",
      "secret%s*[:=]%s*%S+",
      "password%s*[:=]%s*%S+",
      "gh[pousr]_%w+",
      "github_pat_[%w_]+",
      "xox[baprs]%-[%w%-]+",
      '"type"%s*:%s*"service_account"',
      "eyJ[%w_%-]+%.eyJ[%w_%-]+%.[%w_%-]+",
    },
    entropy_enabled = true,
    entropy_threshold = 4.5,
    entropy_min_length = 20,
    entropy_keywords = { "key", "secret", "token", "password", "credential" },
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
      done = false,
      blocked = false,
    },
  },

  agents_view = {
    position = "right", -- "left" or "right"
    width = 44,
    preview_lines = 80,
    deep_preview_lines = 300,
    group_by = "workspace", -- "none", "workspace", or "tab"
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
      done = "✓",
      unknown = "○",
      disconnected = "×",
      separator = "·",
    },
  },
})
```

If you set `presence.enabled = false`, the plugin does not fetch live agent state. It skips the first snapshot, the socket subscription, reconnect timers, and polling. A snapshot is a full copy of live Herdr state. v0.1 configuration files still work.

These configuration keys control multiline transport:

```lua
require("herdr-context").setup({
  multiline_strategy = "auto", -- "auto", "bracketed_paste", or "context_file"
  bracketed_paste_agents = {
    claude = true,
    codex = true,
    grok = true,
    opencode = true,
  },
  context_file_dir = nil, -- defaults to stdpath("cache") .. "/herdr-context"
  herdr_bin = nil, -- defaults to HERDR_BIN_PATH, then "herdr"
})
```

In `auto` mode, multiline payloads for Claude, Codex, Grok, and OpenCode use terminal bracketed-paste sequences. Bracketed paste is a terminal method that pastes many lines as one input. Unknown agents get a one-line reference to a temporary Markdown context file. The context file prevents a raw newline from acting as Enter.

Stage-only transport uses the `pane send-text` API in Herdr. Staging does not submit the prompt. In `auto` mode, bracketed paste keeps all lines in the input editor while the agent is `idle`. Unknown or new agent families use the context-file path until you add them to `bracketed_paste_agents`.

If you press `S` or `<C-Enter>`, or if you set `submit = true`, the plugin sends the original payload with `herdr agent prompt`. That command makes sure that the agent is live. Then it handles the input mode and Enter in one step.

## Context composer

The composer is one floating window with stacked panes. It stores the source buffer, cursor, selection, changedtick, path, and working directory before providers start. A provider is a collector that finds one kind of context. Providers collect at the same time. One timeout or failure does not block the others.

The panes show the live agent list, the message, attached `@path#L…` references, and the exact payload that will be staged. A payload is the exact text that the plugin will stage. If you do not embed a row, the plugin does not dump code into the prompt.

Select code in Visual mode. Run `:HerdrContextPrompt` (or map `require("herdr-context").prompt()`). The message editor opens inside the composer with that range attached as a reference. Type the prompt in the message editor.

Then press `<C-Enter>` to send and submit it. Press `<C-s>` to keep the message so that you can inspect or adjust attached references first. In Normal mode, the same action starts from the current line and finds the containing symbol, hunk, and diagnostics.

Lua callers can turn on tracking. Tracking submits through `agent prompt --wait` and watches the agent until it reaches `idle`, unseen `done`, or `blocked`:

```lua
require("herdr-context").prompt({
  wait = true,
  timeout_ms = 120000,
  preview_result = true, -- also open output for idle/done; blocked always opens it
})
```

`<C-Enter>` sends and does not wait. A tracked `blocked` result focuses the agent and opens its output. `idle` and `done` notify completion. A tracking timeout or `agent_prompt_stalled` warning does not cancel the remote task. The remote task can continue to run.

### Delegating to a new agent

A bundle is the combined payload from the selected providers. `:HerdrContextDelegate codex review` opens the composer with the `review` preset and a new Codex agent as its destination.

Review the exact bundle. Press `s` or `S`. Then choose split, tab, or workspace. Then choose to send without waiting, or to wait and preview the result.

Herdr creates an unfocused shell pane. It starts a uniquely named `reviewer` with `agent start`. It selects that agent as the context target. Then it submits the bundle with `agent prompt`.

Lua callers can skip either picker and set startup values:

```lua
require("herdr-context").delegate({
  kind = "codex",
  preset = "review",
  name = "reviewer", -- receives a numeric suffix when already live
  placement = "tab", -- "split", "tab", or "workspace"; omit to ask
  direction = "right", -- split placement only
  wait = true, -- omit to ask
  timeout_ms = 120000,
  startup_timeout_ms = 30000,
  preview_result = true,
  agent_args = { "--model", "fast" }, -- passed after `agent start ... --`
})
```

If you cancel either choice, the composer stays open. If you accept both choices, the plugin stores the reviewed bundle. Then it closes the composer before any other action. Optional lifecycle tracking then continues in the background.

If creation fails after the composer closes, the plugin reports the kept pane or agent. It does not delete it. It does not retry without a new decision. If the name is taken (`agent_name_taken`), the plugin retries a unique name in the same pane. The plugin reports startup and prompt timeouts. It does not cancel or duplicate the remote process.

Normal mode selects the innermost symbol, the hunk under the cursor, and diagnostics scoped to the symbol (then the hunk). If neither symbol nor hunk is available, it selects the current line. Visual mode selects the exact Visual range and overlapping diagnostics. It does not select symbol or hunk. Empty diagnostics are not attached. If Quickfix, location-list, or Trouble sources have no items, they stay collapsed.

The composer also lists whole-file `@path` references for the current file, the alternate file (`#`), and other listed buffers. These rows start detached. Press `<Space>` to attach one. If you want them selected at composer open, add `file`, `alternate`, or `buffers` to a preset.

Composer keys:

- `<Space>` attaches or detaches the reference under the cursor.
- `e` embeds the buffer snippet for that row instead of a file reference.
- `i` focuses the message editor.
- `1` through `9` pick that live agent in the agent pane.
- `t` or `<CR>` on an agent row pins that Herdr agent as the target.
- `P` applies a named provider preset.
- `r` recaptures the source and reruns providers.
- `s` stages the exact preview. If `submit` is `true`, `s` also submits.
- `S` or `<C-Enter>` sends with `herdr agent prompt`.
- `p` toggles the payload preview.
- `h` opens the session staging history.
- `<C-h>`, `<C-j>`, `<C-k>`, and `<C-l>` move between composer panes. If a direction has no neighbor, focus wraps.
- `<Tab>` cycles the agent, message, references, and preview panes.
- `<S-Tab>` cycles those panes in reverse.
- `?` shows the key reference.
- `q` or `<Esc>` cancels.

In the message buffer, insert-mode `<C-j>`, `<C-k>`, and `<C-l>` leave insert mode and move panes. Insert-mode `<C-h>` is not remapped. It stays as Neovim backspace.

You can also select a preset with a command such as `:HerdrContextCompose debug`. Only available providers with content are selected. The message is included at the top of the payload as plain text.

Press `<C-s>` to keep the message. Press `<C-Enter>` to send it. If the terminal does not distinguish Control-Enter, press `<M-Enter>`. Press `q` in Normal mode to cancel.

If the buffer has unsaved changes, the composer warns before sending a disk reference. Press `e` to embed the live snippet. Press `s` again to send the path anyway.

If you edit the source buffer, the plugin marks the preview as stale. The plugin disables staging until you refresh. If the combined payload exceeds `max_payload_bytes`, the plugin rejects it. It does not truncate or drop sections.

The symbol provider asks every eligible LSP client for document symbols. It chooses the smallest containing range. If LSP has no result, it falls back to Treesitter. The hunk provider prefers MiniDiff because MiniDiff can include unsaved changes. Then it uses `git diff` for saved buffers. If the Trouble plugin is loaded and an open view matches `providers.trouble.modes`, Trouble is used.

Custom providers use the same timeout, preview, and byte-budget path:

```lua
require("herdr-context").register_provider({
  id = "custom-build",
  name = "Build output",
  priority = 70,
  collect = function(request, callback)
    callback({
      id = "custom-build",
      title = "Build output",
      content = "...",
      format = "text",
      fingerprint = "custom-build:latest",
    })
  end,
})
```

`collect` can return a cancellation function. It must call its callback at most once with either a normalized section or an error. Optional integrations must report unavailable state instead of throwing. `:checkhealth herdr-context` summarizes the backends that you can use.

## Live presence

One shared state store serves the statusline, agent drawer, and target UI. During setup, the plugin fetches an initial snapshot. Then it subscribes to Herdr events over `HERDR_SOCKET_PATH`.

The plugin uses Unix socket paths as given. On Windows, it maps a bare pipe name to `\\.\pipe\<name>`. It tests the named pipe by connecting. It does not treat the name as a filesystem entry.

If the connection drops, the plugin marks cached data as stale. Then it starts polling. Reconnects use exponential backoff. Polling stops after reconnect. Every pipe and timer closes on `VimLeavePre`.

The statusline reads only cached Lua state. It does not start a process or do socket I/O during a redraw:

```lua
require("herdr-context").statusline()
-- Herdr ▶ ● codex · 3
```

For lualine:

```lua
{
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, function()
      return require("herdr-context").statusline()
    end)
  end,
}
```

The native agent drawer is a scratch-buffer split. Its keys are:

- `<CR>` or `t` selects the pane as the context target.
- `f` focuses the Herdr pane.
- `p` previews 80 lines of recent agent output.
- `P` requests the deeper 300-line transcript.
- `e` shows Herdr agent-detection, matched-rule, lifecycle-authority, and evidence explanation.
- `/` filters agents by name, status, workspace, tab, path, or message.
- `<Space>` collapses or expands the workspace or tab group under the cursor.
- `c` clears the active filter.
- `r` forces a state refresh.
- `q` closes the drawer.

The drawer groups agents by workspace and tab by default. The drawer reads output only after you press `p` or `P`. It never reads agent output in the background. With a Herdr socket, previews use `agent.read`, so truncation metadata is kept. If the agent is busy, the preview falls back from alternate-screen history to the live viewport. The preview labels that fallback and any omitted older output.

If there is no socket, the plugin uses the text-only CLI. The adjacent preview uses `agents_view.preview_width`. `preview_lines` and `deep_preview_lines` bound the two transcript depths. Press `r` inside the output pane to refresh it.

`:HerdrContextExplainAgent` resolves a target and runs `herdr agent explain <pane> --json`. The same view is available with `e` in the drawer. It reports the final state, active and cached manifest versions, winning and evaluated rules, visible evidence, lifecycle authority, and fallback or skipped reasons. This is Herdr detector output. The plugin does not parse the screen again.

The `presence.notifications` flags turn on desktop-visible Neovim notifications for an existing agent that moves to `idle`, unseen `done`, or `blocked`. Initial snapshots do not notify. All of these transitions are off by default.

You can read or subscribe to snapshots. The copy does not change after you receive it:

```lua
local state = require("herdr-context.state")

state.get()
state.agents({ scope = "workspace" })
local subscription = state.subscribe(function(snapshot) end)
state.unsubscribe(subscription)
state.refresh({ force = true }, function(snapshot, err) end)
```

State changes emit `User` events named `HerdrContextUpdated`, `HerdrContextTargetChanged`, `HerdrContextAgentStatusChanged`, `HerdrContextConnected`, and `HerdrContextDisconnected`. You can read relevant event details in `vim.v.event` and autocmd callback `data`.

Socket presence reads the server version. Then it opens the lifecycle subscription. Then it takes a snapshot and buffers new events during that snapshot.

It then applies pane, tab, workspace, and agent-status events directly to the shared cache. New and removed agents gain or lose a dedicated status stream without reconnecting the lifecycle subscription. The plugin reserves further full snapshots for reconnects, explicit refreshes, unknown or inconsistent events, and backwards pane revisions. The plugin always subscribes to `workspace.reordered`.

## Target selection

The shared snapshot gives live agent and layout metadata. The plugin ranks candidates by:

1. Same tab
2. Same workspace
3. Same exact worktree
4. Another worktree from the same repository
5. Same working directory
6. Same Git root
7. Other agents in the session.

A worktree is a Git working copy of a repository. The plugin prefers Herdr workspace data for worktree comparisons. Working-directory and Git-root matching stay as lower-priority signals.

`target_scope` filters that list before ranking. `"project"` includes the current repository worktrees and cwd or Git-root matches. `"tab"`, `"workspace"`, and `"session"` keep their narrower or broader meanings. The current Herdr pane is excluded.

The plugin uses pane IDs internally because labels such as `codex` are not unique. If Herdr changes a workspace-qualified pane ID during a move, the plugin migrates the session selection and any stored workspace pins to the new ID.

Before every send, the plugin makes sure that the selected pane is still in a fresh snapshot. If `remember_target` is `"session"` (the default) and more than one agent is live, the picker opens again. The plugin does not reuse the previous destination without asking. If only one candidate remains and `auto_select` is `true`, the plugin selects it. `vim.ui.select` drives the picker. Snacks integrations work with this picker.

The Herdr companion action `herdr-context.pin-target` on Linux/macOS, or `herdr-context.pin-target-windows` on Windows, opens an 80%-wide, 20-row popup picker. The popup does not join the tiled layout. It does not appear in agent snapshots. It does not emit pane lifecycle events. If the picker exits, the popup closes.

The Bash picker uses `jq`. The Windows picker uses only the bundled Windows PowerShell runtime. It stores one pane ID per workspace in the plugin configuration directory. Neovim reads the same file.

If you set `remember_target = "workspace"`, Neovim selections update that file too. Then the pin stays across sends. If you set `HERDR_CONTEXT_CONFIG`, the plugin uses that path for the shared file.

## Payloads

The composer default is a message plus file references:

```text
Explain the snacks zen toggles.

@lua/plugins/snacks.lua#L53-L60
```

Press `e` on a row to embed the snippet. You can also set `composer.include = "content"`:

````text
Explain the snacks zen toggles.

@lua/plugins/snacks.lua#L53-L60

```lua
zen = {
  toggles = {
    dim = true,
  },
}
```
````

`:HerdrContextReference` stages a single `@path#L10-L20` line. `:HerdrContextSend` embeds the selected code. Paths are relative to the Git root. If there is no Git root, paths are relative to the Neovim working directory. The plugin marks modified buffers as `(unsaved changes)`. Unnamed buffers have no stable path, so they are embedded.

Markdown fences expand past the longest backtick run in the selection. The plugin normalizes drive-letter and UNC paths. On Windows, path comparison ignores case. Context-file references use forward slashes so that they stay clear in agent prompts. If a payload is over `max_payload_bytes`, the plugin rejects it. It does not truncate the payload.

Diagnostics are short lists. The plugin omits empty diagnostics:

```text
- ERROR [typescript:2345] L21: Argument is not assignable…
- WARN [eslint:no-unused-vars] L24: `result` is assigned but never used.
```

## Safety contract

The plugin applies safety exclusions before it builds the bundle. The plugin blocks current-buffer sections that match `safety.exclude_patterns`. It removes matching items in list providers and reports them. The plugin also matches selected content against `safety.secret_patterns`.

The composer shows warnings and requires a second `s` press after review. Direct staging commands use a picker that asks you to continue. If you change the payload, you must accept the warning again. The plugin never prints the matched secret. The default patterns cover AWS keys, private keys, common assignments, GitHub and Slack tokens, GCP service-account JSON, and JWTs. If a secret-related word or identifier part is on the same line, entropy scanning also warns about long, unformatted values.

Successful stages stay in memory up to `history.max_entries`. `:HerdrContextHistory` can inspect the exact payload, clear the list, or restage an entry. The plugin never writes history to disk. If Neovim exits, history disappears.

Default sends do not submit:

- The plugin passes context to `herdr pane send-text` as one argv element.
- The plugin does not use a shell-concatenated command.
- The plugin uses bracketed paste for multiline input only for agents in `bracketed_paste_agents`.
- Other agents are staged through a context file.
- Explicit submission passes the original payload to agent-aware `herdr agent prompt` as one argv element.
- The plugin rejects an oversized payload before target resolution or transport.

If you want staging only, keep `submit = false`. If `submit` is `true`, the plugin submits the prompt after it stages the text.

## Development

```sh
make test
make lint
# Read-only integration check against a running Herdr server:
make test-live
```

The test suite covers deterministic bundles, provider timeout and cancellation, and LSP symbol fixtures. It also covers MiniDiff add/change/delete hunks, Git diff parsing, and quickfix normalization. It covers stale composer buffers, exact preview rendering, and combined byte budgets. Transport tests use a fake Herdr executable. Presence tests use sanitized socket fixtures and fake clients.

Shell smoke tests exercise the companion popup launcher and manifest sizing, target ranking, and workspace target persistence. Windows CI covers drive and UNC paths, named-pipe endpoints and presence probes, exact multiline/modified-key transport, and the PowerShell companion picker.
