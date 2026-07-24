#!/usr/bin/env bash
set -euo pipefail

log="${FAKE_HERDR_LOG:?FAKE_HERDR_LOG is required}"
printf '%s %s\n' "${1:-}" "${2:-}" >> "$log"

if [ "${FAKE_HERDR_MODE:-}" = 'failure' ]; then
  printf 'fake Herdr server is stopped\n' >&2
  exit 7
fi

if [ "${1:-}" = 'agent' ] && [ "${2:-}" = 'send' ]; then
  printf '%s\n' "error: unrecognized subcommand 'send'" >&2
  exit 2
fi

if [ "${1:-}" = 'pane' ] && [ "${2:-}" = 'send-text' ]; then
  hex=$(printf '%s' "${4:-}" | od -An -v -tx1 | tr -d ' \n')
  printf 'target=%s\ntext=%s\n' "${3:-}" "$hex" >> "$log"
fi

if [ "${1:-}" = 'api' ] && [ "${2:-}" = 'snapshot' ]; then
  if [ "${FAKE_HERDR_MODE:-}" = 'invalid-json' ]; then
    printf '%s\n' 'not json'
  else
    printf '%s\n' '{"id":"fake","result":{"snapshot":{"version":"0.7.5","protocol":17,"agents":[],"workspaces":[],"tabs":[],"panes":[],"layouts":[]}}}'
  fi
elif [ "${1:-}" = 'agent' ] && [ "${2:-}" = 'get' ]; then
  printf '{"id":"fake","result":{"agent":{"agent":"codex","pane_id":"%s"}}}\n' "${3:-}"
else
  printf '%s\n' '{"id":"fake","result":{"type":"ok"}}'
fi
