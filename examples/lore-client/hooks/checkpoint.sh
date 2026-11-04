#!/usr/bin/env bash
# SubagentStop hook of the lore-client example. Reacts to its own agent only
# (agent_type lore-client-worker, plain or plugin-prefixed) and emits one
# `checkpoint` event through the lore shim. Always exits 0.
INPUT="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
agent="$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)"
case "$agent" in lore-client-worker|lore-client:lore-client-worker) ;; *) exit 0 ;; esac
cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LORE_CLIENT_CWD="$cwd" bash "$HERE/../scripts/lore-event.sh" checkpoint "" "lore-client-worker finished" 
exit 0
