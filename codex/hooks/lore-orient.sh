#!/usr/bin/env bash
# Lore SessionStart orientation. Read-only. Injects "where you left off"
# context at session start so you do not have to ask. Never writes, never
# blocks: it always exits 0 and prints best-effort orientation to stdout,
# which the host injects as context.
#
# Install (Codex): copy to ~/.codex/hooks/lore-orient.sh, chmod +x, and add
# to ~/.codex/config.toml:
#   [[hooks.SessionStart]]
#   [[hooks.SessionStart.hooks]]
#   type = "command"
#   command = '"$HOME/.codex/hooks/lore-orient.sh"'

VAULT="${SECOND_BRAIN_PATH:-$HOME/second-brain}"
if [ ! -d "$VAULT" ]; then
  echo "Lore: no vault at $VAULT. Run /lore start to initialize."
  exit 0
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$ROOT" ]; then
  exit 0   # not a git repo; nothing to orient on, stay silent
fi
NAME="$(basename "$ROOT")"

# Resolve display name from the lore-config.json projects map (best effort).
DISPLAY="$NAME"
CONFIG="$VAULT/lore-config.json"
if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
  MAPPED="$(jq -r --arg k "$ROOT" '.projects[$k] // empty' "$CONFIG" 2>/dev/null)"
  [ -n "$MAPPED" ] && DISPLAY="$MAPPED"
fi

PROJ="$VAULT/projects/$DISPLAY"
STATUS="$PROJ/status.md"

echo "## Lore orientation — $DISPLAY (read-only, auto-injected)"
echo
if [ -f "$STATUS" ]; then
  echo "### Last recorded status"
  cat "$STATUS"
else
  echo "No status.md for this project yet. Reconstruct from the evidence below,"
  echo "or run /lore start to initialize."
fi

# Local evidence: cheap, offline, lets the model reconcile a stale status.md
echo
echo "### Evidence (reconcile against the status above; it may be stale)"
echo "Branch: $(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "Recent commits:"
git -C "$ROOT" log --oneline -5 2>/dev/null
if [ -f "$PROJ/.squad/progress.txt" ]; then
  echo "progress.txt (tail):"; tail -n 5 "$PROJ/.squad/progress.txt"
fi
if [ -f "$PROJ/.squad/session.log" ]; then
  echo "session.log (tail):"; tail -n 5 "$PROJ/.squad/session.log"
fi

echo
echo "If the status looks stale next to the evidence, run /lore recover to rebuild it."
echo "Run /lore start for setup (first-time naming, migration, session-log reset)."
exit 0
