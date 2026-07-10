#!/usr/bin/env bash
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
plugin_id="${HERDR_PLUGIN_ID:-herdr-context}"

args=(plugin pane open --plugin "$plugin_id" --entrypoint target-picker --placement overlay --focus)
if [ -n "${HERDR_PANE_ID:-}" ]; then
  args+=(--target-pane "$HERDR_PANE_ID")
fi

exec "$herdr" "${args[@]}"
