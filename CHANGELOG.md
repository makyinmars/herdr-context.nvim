# Changelog

All notable changes to `herdr-context.nvim` are documented here.

## Unreleased

- Add `:HerdrContextDelegate <kind> [preset]` to review a composer bundle, create a split/tab/workspace agent, start and prompt it, and optionally wait for and preview its result.
- Add `:HerdrContextExplainAgent` and drawer `e` to inspect Herdr's authoritative detection rules, evidence, lifecycle authority, fallback reasons, and manifest versions.
- Rank and scope targets with Herdr worktree provenance, add project scope, and migrate remembered or pinned targets when pane moves change their IDs.
- Add opt-in `prompt({ wait = true })` lifecycle tracking with completion/blocked handling, optional result previews, and non-cancelling timeout/stall reporting.
- Apply Herdr socket resource events directly to the presence cache, including `workspace.reordered`, and reserve snapshots for bootstrap, reconnect, explicit refresh, and inconsistency recovery.
- Add normal and deep socket-backed agent output previews with busy-agent viewport fallback and truncation indicators.
- Treat Herdr's unseen `done` lifecycle as a first-class state in target ranking, notifications, the picker, drawer, and statusline, and render custom display names and state labels when available.
- Add `:HerdrContextPrompt` and `prompt()` for a Visual-selection-to-message workflow entirely inside Neovim.
- Add an explicit `S`/`<C-Enter>` send-now action without changing the safe non-submitting default.
- Route explicit sends through agent-aware `herdr agent prompt` while retaining raw, non-submitting staging.
- Refresh the composer and message editor with clearer context attachments, source details, payload sizing, and key hints.
- Reopen target selection before each send when multiple agents are live instead of silently reusing a session target.

## 0.4.0 - 2026-07-16

- Replace the composer with paired provider-checklist and exact-payload panes.
- Add editable instructions and named composer presets, including command completion.
- Group, filter, and collapse agents in the drawer and show recent output in an adjacent pane.
- Add configurable sensitive-path exclusions and secret-pattern confirmations.
- Add bounded, in-memory staging history with payload inspection and restaging.
- Add `:HerdrContextHistory` and expand UI, safety, preset, and history coverage.

## 0.3.0 - 2026-07-16

- Add the context composer with selection, symbol, hunk, diagnostics, quickfix, location-list, and Trouble providers.
- Add deterministic bundle rendering, provider isolation, exact previews, stale-buffer protection, and byte budgets.
- Add on-demand recent-output previews to the live agent drawer.
- Add opt-in notifications for agent transitions to idle or blocked.
- Add `:HerdrContextLocationList`.
- Add companion picker shell tests and expand the headless Neovim suite.

## 0.2.0

- Add the shared live-state store, socket watcher, polling fallback, statusline, agent drawer, and target persistence.

## 0.1.0

- Add range-aware context capture, safe staging transport, target selection, health checks, and the Herdr companion picker.
