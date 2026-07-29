#!/usr/bin/env bash
# Lore SessionStart orientation. Read-only. Injects "where you left off"
# context at session start so you do not have to ask. Never writes, never
# blocks: it always exits 0 and prints best-effort orientation to stdout,
# which the host injects as context.
#
# Install (Claude Code): copy to ~/.claude/hooks/lore-orient.sh, chmod +x,
# and add to ~/.claude/settings.json:
#   { "hooks": { "SessionStart": [ { "matcher": "*", "hooks": [
#     { "type": "command", "command": "bash /Users/ggadmin/.claude/hooks/lore-orient.sh" } ] } ] } }

VAULT="${SECOND_BRAIN_PATH:-$HOME/second-brain}"
if [ ! -d "$VAULT" ]; then
  echo "{\"systemMessage\": \"Lore: no vault at $VAULT. Run /lore start to initialize.\"}"
  exit 0
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$ROOT" ]; then
  echo "{}"
  exit 0
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

NL=$'\n'

# Accumulate all text output into a variable
OUTPUT="## Lore orientation — $DISPLAY (read-only, auto-injected)${NL}${NL}"

if [ -f "$STATUS" ]; then
  OUTPUT="${OUTPUT}### Last recorded status${NL}$(cat "$STATUS" | sed 's/"/\\"/g')${NL}"
else
  OUTPUT="${OUTPUT}No status.md for this project yet. Reconstruct from the evidence below,${NL}or run /lore start to initialize.${NL}"
fi

# Local evidence: cheap, offline, lets the model reconcile a stale status.md
OUTPUT="${OUTPUT}${NL}### Evidence (reconcile against the status above; it may be stale)${NL}"
OUTPUT="${OUTPUT}Branch: $(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)${NL}"
OUTPUT="${OUTPUT}Recent commits:${NL}$(git -C "$ROOT" log --oneline -5 2>/dev/null | sed 's/"/\\"/g')${NL}"

if [ -f "$PROJ/.squad/progress.txt" ]; then
  OUTPUT="${OUTPUT}progress.txt (tail):${NL}$(tail -n 5 "$PROJ/.squad/progress.txt" | sed 's/"/\\"/g')${NL}"
fi

if [ -f "$PROJ/.squad/session.log" ]; then
  OUTPUT="${OUTPUT}session.log (tail):${NL}$(tail -n 5 "$PROJ/.squad/session.log" | sed 's/"/\\"/g')${NL}"
fi

OUTPUT="${OUTPUT}${NL}If the status looks stale next to the evidence, run /lore recover to rebuild it.${NL}"
OUTPUT="${OUTPUT}Run /lore start for setup (first-time naming, migration, session-log reset)."

# Export final JSON — systemMessage shows in UI, additionalContext is injected as prompt context
jq -n --arg msg "$OUTPUT" '{
  systemMessage: $msg,
  additionalContext: $msg
}'

exit 0