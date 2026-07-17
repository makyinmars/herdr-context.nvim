# Changelog

All notable changes to `herdr-context.nvim` are documented here.

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
