# herdr-context.nvim

See live [Herdr](https://herdr.dev) agents inside Neovim and stage code context in their prompts without
submitting it.

`herdr-context.nvim` is one repository with two install surfaces:

- a Neovim plugin for collecting, formatting, and staging context;
- a Herdr companion plugin with an overlay action for pinning the default target agent.

## Requirements

- Neovim 0.10 or newer
- Herdr 0.7.0 or newer
- `jq` for the optional Herdr overlay target picker

Neovim should normally be running in a Herdr pane so `HERDR_PANE_ID`, `HERDR_TAB_ID`, and
`HERDR_WORKSPACE_ID` are available.

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

For local development, point both systems at the same checkout:

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
| `:HerdrContextTarget` | Choose or change the destination agent |
| `:HerdrContextAgents` | Toggle the live agent drawer |
| `:HerdrContextRefresh` | Force a cached-state refresh |
| `:checkhealth herdr-context` | Check Neovim, environment, Herdr, agents, and the companion plugin |

The three context commands accept an Ex range. Lua calls made from Visual mode preserve linewise,
characterwise, reversed, and blockwise selections.

## Configuration

```lua
require("herdr-context").setup({
  submit = false,
  focus_after_send = false,
  max_payload_bytes = 64 * 1024,
  target_scope = "workspace", -- "tab", "workspace", or "session"
  remember_target = "session", -- "none", "session", or "workspace"

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
    position = "right", -- "left" or "right"
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
})
```

Set `presence.enabled = false` to disable the bootstrap snapshot, socket subscription, reconnect timers,
and polling fallback. Existing v0.1 configurations remain valid.

Additional transport options are available for unusual agents:

```lua
require("herdr-context").setup({
  multiline_strategy = "auto", -- "auto", "bracketed_paste", or "context_file"
  bracketed_paste_agents = {
    codex = true,
    claude = true,
  },
  context_file_dir = nil, -- defaults to stdpath("cache") .. "/herdr-context"
  herdr_bin = nil, -- defaults to HERDR_BIN_PATH, then "herdr"
})
```

In `auto` mode, multiline payloads for Codex and Claude use terminal bracketed-paste sequences.
Unknown agents receive a single-line reference to a temporary Markdown context file. This avoids
injecting literal newline bytes into an agent that may interpret them as Enter.

The bracketed-paste contract has been checked end-to-end with Herdr 0.7.3 against Codex CLI 0.144.0
and Claude Code 2.1.160: both lines remained in the input editor and each agent stayed `idle`. Unknown
or newly introduced agent families remain on the conservative context-file path until configured.

## Live presence

One shared state store serves the statusline, agent drawer, and target UI. Setup fetches an initial
snapshot, then subscribes to Herdr events over `HERDR_SOCKET_PATH`. Events are invalidation signals:
bursts are debounced and produce one fresh snapshot. If the socket disconnects, cached data is marked
stale, polling starts, and socket reconnects use exponential backoff. Polling stops after reconnect.
Every pipe and timer closes on `VimLeavePre`.

The statusline reads only cached Lua state; it never starts a process or performs socket I/O during a
redraw:

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

The native agent drawer is a scratch-buffer split. Its controls are:

- `<CR>` or `t`: select the pane as the context target;
- `f`: focus the Herdr pane;
- `r`: force a state refresh;
- `q`: close the drawer.

`p` reports that recent-output preview is deferred to v0.2.1; the drawer never reads agent output in
the background. The `presence.notifications` flags are likewise reserved for the opt-in transition
notifications planned for v0.2.1.

Advanced consumers can read or subscribe to immutable snapshots:

```lua
local state = require("herdr-context.state")

state.get()
state.agents({ scope = "workspace" })
local subscription = state.subscribe(function(snapshot) end)
state.unsubscribe(subscription)
state.refresh({ force = true }, function(snapshot, err) end)
```

State changes emit `User` events named `HerdrContextUpdated`, `HerdrContextTargetChanged`,
`HerdrContextAgentStatusChanged`, `HerdrContextConnected`, and `HerdrContextDisconnected`. Relevant
event details are available through `vim.v.event` and autocmd callback `data`.

## Target selection

The shared snapshot supplies live agent and layout metadata. Candidates are ranked by:

1. same tab;
2. same workspace;
3. same Git root or working directory;
4. other agents in the session.

`target_scope` filters that list before ranking. The current Herdr pane is excluded. Pane IDs are used
internally because labels such as `codex` are not necessarily unique.

The selected pane is still checked against a fresh snapshot before every send. If it disappeared, the
selection is cleared and the picker reopens (or the sole remaining candidate is selected when
`auto_select = true`). `vim.ui.select` drives the picker, so existing Snacks integrations are honored.

The Herdr companion action `herdr-context.pin-target` opens an overlay picker. It stores one pane ID per
workspace in the plugin config directory. Neovim reads the same file. Set `remember_target = "workspace"`
to make Neovim selections update it too, or set `HERDR_CONTEXT_CONFIG` to override the shared file path.

## Payloads

Reference only:

```text
@lua/plugins/snacks.lua#L53-L60
```

Reference with content:

````text
@lua/plugins/snacks.lua#L53-L60

```lua
zen = {
  toggles = {
    dim = true,
  },
}
```
````

Paths are relative to the Git root, falling back to Neovim's working directory. Modified buffers are
marked `(unsaved changes)`. Content from unnamed buffers is allowed, but reference-only mode rejects it
because it has no stable path. Markdown fences expand past the longest backtick run in the selection.
Payloads over `max_payload_bytes` are rejected rather than truncated.

Diagnostics include severity, source, code, message, and source line:

```text
Diagnostics for @src/index.ts#L18-L27:

- ERROR [typescript:2345] L21: Argument is not assignable…
- WARN [eslint:no-unused-vars] L24: `result` is assigned but never used.
```

## Safety contract

Default sends never submit:

- context is passed to `herdr agent send` as one argv element;
- no shell-concatenated command is used;
- multiline input is bracketed-pasted only for configured agents, otherwise staged through a context file;
- Enter is sent only by the separate `herdr pane send-keys <pane> enter` command when `submit = true`;
- payload size is checked before target resolution or transport.

Keep `submit = false` unless automatic submission is explicitly desired.

## Development

```sh
make test
make lint
# Read-only integration check against a running Herdr server:
make test-live
```

The headless suite covers normal and visual ranges, modified and unnamed buffers, Git-relative paths,
backtick fences, Unicode byte limits, diagnostics, target ranking, immutable state, socket framing,
event debouncing, polling fallback, statusline rendering, drawer mappings, stale targets, context-file
fallback, and proof that default transport does not invoke Enter. Transport tests use a fake Herdr
executable; presence tests use sanitized socket fixtures and fake clients.
