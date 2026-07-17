#!/usr/bin/env bash
set -euo pipefail

log="${FAKE_HERDR_LOG:?FAKE_HERDR_LOG is required}"
{
  printf 'argv'
  printf '\t%s' "$@"
  printf '\n'
} >> "$log"

if [ "${1:-}" = 'api' ] && [ "${2:-}" = 'snapshot' ]; then
  printf '%s\n' "${FAKE_HERDR_SNAPSHOT:?FAKE_HERDR_SNAPSHOT is required}"
else
  printf '%s\n' '{"id":"fake","result":{"type":"ok"}}'
fi
