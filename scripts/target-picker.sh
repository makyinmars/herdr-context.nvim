#!/usr/bin/env bash
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
workspace_id="${HERDR_WORKSPACE_ID:-}"
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${HOME}/.config/herdr/plugins/config/herdr-context}"
config_file="${HERDR_CONTEXT_CONFIG:-${config_dir}/targets}"

if ! command -v jq >/dev/null 2>&1; then
  printf 'herdr-context: jq is required by the overlay target picker\n' >&2
  read -r -p 'Press Enter to close... ' _
  exit 1
fi

snapshot=$("$herdr" api snapshot)
rows=$(printf '%s' "$snapshot" | jq -r --arg workspace "$workspace_id" '
  .result.snapshot as $snapshot
  | ($snapshot.workspaces | map({ key: .workspace_id, value: .label }) | from_entries) as $workspaces
  | ($snapshot.tabs | map({ key: .tab_id, value: .label }) | from_entries) as $tabs
  | $snapshot.agents[]
  | [
      (if .workspace_id == $workspace then 0 else 1 end),
      (.agent_status // "unknown"),
      (.agent // "agent"),
      ($workspaces[.workspace_id] // .workspace_id // "?"),
      ($tabs[.tab_id] // .tab_id // "?"),
      (.foreground_cwd // .cwd // "?"),
      .pane_id
    ]
  | @tsv
' | sort -t $'\t' -k1,1n -k2,2 -k3,3 -k7,7)

if [ -z "$rows" ]; then
  printf 'No live Herdr agents found.\n'
  read -r -p 'Press Enter to close... ' _
  exit 1
fi

pane_ids=()
count=0
printf '\nPin a default herdr-context target\n\n'
while IFS=$'\t' read -r _rank status agent workspace tab cwd pane_id; do
  count=$((count + 1))
  pane_ids[$count]="$pane_id"
  marker='○'
  case "$status" in
    idle) marker='●' ;;
    working) marker='◉' ;;
    blocked) marker='!' ;;
  esac
  printf '%2d) %s %-8s %-8s %s / %s   %s   %s\n' "$count" "$marker" "$status" "$agent" "$workspace" "$tab" "$cwd" "$pane_id"
done <<< "$rows"

printf '\nChoose 1-%d (or q to cancel): ' "$count"
read -r choice
if [ "$choice" = 'q' ] || [ "$choice" = 'Q' ] || [ -z "$choice" ]; then
  exit 0
fi
case "$choice" in
  *[!0-9]*) printf 'Invalid choice.\n' >&2; exit 2 ;;
esac
if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
  printf 'Invalid choice.\n' >&2
  exit 2
fi

selected="${pane_ids[$choice]}"
if [ -z "$workspace_id" ]; then
  workspace_id=$(printf '%s' "$snapshot" | jq -r '.result.snapshot.focused_workspace_id // empty')
fi
if [ -z "$workspace_id" ]; then
  printf 'Could not determine the current workspace.\n' >&2
  exit 1
fi

mkdir -p "$(dirname "$config_file")"
tmp=$(mktemp "${config_file}.XXXXXX")
trap 'rm -f "$tmp"' EXIT
if [ -r "$config_file" ]; then
  awk -F '\t' -v workspace="$workspace_id" '$1 != workspace' "$config_file" > "$tmp"
fi
printf '%s\t%s\n' "$workspace_id" "$selected" >> "$tmp"
mv "$tmp" "$config_file"
trap - EXIT

printf '\nPinned %s for workspace %s.\n' "$selected" "$workspace_id"
sleep "${HERDR_CONTEXT_CLOSE_DELAY:-1}"
