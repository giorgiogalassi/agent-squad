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

# Resolve vault path, project root, and display name via the shared
# path-resolve.sh utility (installed alongside this hook) rather than
# re-deriving the algorithm here. See PATH_RESOLUTION.md.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -x "$HOOK_DIR/path-resolve.sh" ]; then
  eval "$("$HOOK_DIR/path-resolve.sh")"
  VAULT="$VAULT_PATH"
  ROOT="$PROJECT_ROOT"
  DISPLAY="$DISPLAY_NAME"
else
  # path-resolve.sh not installed alongside this hook — degrade to
  # resolving inline rather than failing the whole orientation.
  VAULT="${SECOND_BRAIN_PATH:-$HOME/second-brain}"
  ROOT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$ROOT" ]; then ROOT="$(dirname "$ROOT")"; else ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; fi
  DISPLAY=""
  if [ -n "$ROOT" ] && [ -f "$VAULT/lore-config.json" ] && command -v jq >/dev/null 2>&1; then
    DISPLAY="$(jq -r --arg k "$ROOT" '.projects[$k] // empty' "$VAULT/lore-config.json" 2>/dev/null)"
  fi
fi

if [ ! -d "$VAULT" ]; then
  echo "Lore: no vault at $VAULT. Run /lore start to initialize."
  exit 0
fi
if [ -z "$ROOT" ]; then
  exit 0   # not a git repo; nothing to orient on, stay silent
fi
[ -z "$DISPLAY" ] && DISPLAY="$(basename "$ROOT")"

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
# Uses the actual working directory, not $ROOT: $ROOT is the main project
# root (needed for the vault lookup above), but the branch/commits should
# reflect wherever this session actually is — the main checkout, or a
# Sidecar worktree on a different branch entirely.
echo
echo "### Evidence (reconcile against the status above; it may be stale)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "Recent commits:"
git log --oneline -5 2>/dev/null
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
