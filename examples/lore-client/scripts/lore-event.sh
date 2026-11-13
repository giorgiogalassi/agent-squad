#!/usr/bin/env bash
# lore-event.sh <kind> <key> <line>: write one event through the lore shim.
# The only way this client writes. It never touches the vault, the project's
# state directory or version control. Silent no-op (exit 0, nothing written)
# when the shim is missing, the project is unmapped or the write fails: a
# client must never break its host session.
#
# The project name comes from `lore project` (read-only) run in the working
# directory. An unmapped project (exit 10) writes nothing: first contact is
# `/lore start`, never this client.
LORE="${LORE_BIN:-$HOME/.local/share/lore/bin/lore}"
[ -x "$LORE" ] || exit 0
kind="${1:-}"; key="${2:-}"; line="${3:-}"
[ -n "$kind" ] && [ -n "$line" ] || exit 0
[ -n "${LORE_CLIENT_CWD:-}" ] && { cd "$LORE_CLIENT_CWD" 2>/dev/null || exit 0; }
name="$("$LORE" project 2>/dev/null | sed -n 's/^NAME=//p' | head -n 1)"
[ -n "$name" ] || exit 0
if [ -n "$key" ]; then
  "$LORE" event --project "$name" --source lore-client --kind "$kind" --key "$key" --line "$line" >/dev/null 2>&1
else
  "$LORE" event --project "$name" --source lore-client --kind "$kind" --line "$line" >/dev/null 2>&1
fi
exit 0
