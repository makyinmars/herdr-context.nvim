#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_herdr="$root/tests/fixtures/fake-companion-herdr.sh"
log="$tmp/herdr.log"
: > "$log"

FAKE_HERDR_LOG="$log" \
HERDR_BIN_PATH="$fake_herdr" \
HERDR_PLUGIN_ID='custom-context' \
HERDR_PANE_ID='w0:self' \
  "$root/scripts/open-target-picker.sh" >/dev/null

expected_open=$'argv\tplugin\tpane\topen\t--plugin\tcustom-context\t--entrypoint\ttarget-picker\t--placement\toverlay\t--focus\t--target-pane\tw0:self'
if ! grep -Fqx "$expected_open" "$log"; then
  printf 'open-target-picker.sh passed unexpected arguments\n' >&2
  sed -n '1,20p' "$log" >&2
  exit 1
fi

snapshot='{"id":"fake","result":{"snapshot":{"focused_workspace_id":"w0","workspaces":[{"workspace_id":"w0","label":"current"},{"workspace_id":"w1","label":"other"}],"tabs":[{"tab_id":"w0:t1","label":"api"},{"tab_id":"w1:t1","label":"web"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"claude","agent_status":"idle","cwd":"/tmp/other"},{"pane_id":"w0:p2","workspace_id":"w0","tab_id":"w0:t1","agent":"codex","agent_status":"working","cwd":"/tmp/current"}]}}}'
config_file="$tmp/targets"

printf '1\n' | \
  FAKE_HERDR_LOG="$log" \
  FAKE_HERDR_SNAPSHOT="$snapshot" \
  HERDR_BIN_PATH="$fake_herdr" \
  HERDR_WORKSPACE_ID='w0' \
  HERDR_CONTEXT_CONFIG="$config_file" \
  HERDR_CONTEXT_CLOSE_DELAY=0 \
  "$root/scripts/target-picker.sh" >/dev/null

if [ "$(cat "$config_file")" != $'w0\tw0:p2' ]; then
  printf 'target-picker.sh did not persist the ranked workspace target\n' >&2
  sed -n '1,20p' "$config_file" >&2
  exit 1
fi

printf 'ok - companion picker scripts\n'
