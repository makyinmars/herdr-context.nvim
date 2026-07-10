# herdr-context.nvim

Stage code context from Neovim in a live [Herdr](https://herdr.dev) agent prompt without submitting it.

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
})
```

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

## Target selection

One `herdr api snapshot` call supplies all live agent and layout metadata. Candidates are ranked by:

1. same tab;
2. same workspace;
3. same Git root or working directory;
4. other agents in the session.

`target_scope` filters that list before ranking. The current Herdr pane is excluded. Pane IDs are used
internally because labels such as `codex` are not necessarily unique.

The selected pane is checked against a fresh snapshot before every send. If it disappeared, the
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
backtick fences, Unicode byte limits, diagnostics, target ranking, stale targets, context-file fallback,
and proof that default transport does not invoke Enter. Transport tests use a fake Herdr executable.
