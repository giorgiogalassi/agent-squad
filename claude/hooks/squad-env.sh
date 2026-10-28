#!/usr/bin/env bash
# Squad SessionStart env export. Runs path-resolve.sh once and appends the five
# resolved values to $CLAUDE_ENV_FILE as shell-quoted `export` lines, so every
# later Bash call in the session (skills and subagents included) sees
# SQUAD_VAULT_PATH, SQUAD_PROJECT_ROOT, SQUAD_DISPLAY_NAME, SQUAD_DIR and
# SQUAD_TRACKER_MODE without re-running the script. path-resolve.sh stays the
# single source of the algorithm (PATH_RESOLUTION.md); this hook only transports
# its output.
#
# Registered by hooks/hooks.json (SessionStart), matcher startup|clear|compact|resume,
# in its own entry: lore-orient early-exits on resume, so it cannot share one.
# A resumed session likely gets a fresh env file, hence resume is included.
# CwdChanged is deliberately not registered: path-resolve.sh resolves a linked
# worktree to its main project, so the values do not change when the session
# works inside a `claude -w` worktree, and a Bash `cd` never changes the project.
#
# Idempotent: earlier SQUAD_* export lines are removed before the new ones are
# appended, so clear/compact never leave duplicates. Never blocks: always exit 0;
# no CLAUDE_ENV_FILE or no usable resolution is a silent no-op.

[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -f "$HOOK_DIR/path-resolve.sh" ] || exit 0

# The session's own directory comes from the hook input (cwd), when given.
HOOK_INPUT=""
if [ ! -t 0 ]; then
  IFS= read -r -t 2 -d '' HOOK_INPUT || true
fi
if [ -n "$HOOK_INPUT" ]; then
  if command -v jq >/dev/null 2>&1; then
    HOOK_CWD="$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  else
    HOOK_CWD="$(printf '%s' "$HOOK_INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  fi
  [ -n "$HOOK_CWD" ] && cd "$HOOK_CWD" 2>/dev/null
fi

# Parsed line by line, never eval'd: the output is not shell-quoted.
V_VAULT=""; V_ROOT=""; V_NAME=""; V_DIR=""; V_MODE=""; GOT_ROOT=0
while IFS='=' read -r _k _v; do
  case "$_k" in
    VAULT_PATH) V_VAULT="$_v" ;;
    PROJECT_ROOT) V_ROOT="$_v"; GOT_ROOT=1 ;;
    DISPLAY_NAME) V_NAME="$_v" ;;
    SQUAD_DIR) V_DIR="$_v" ;;
    TRACKER_MODE) V_MODE="$_v" ;;
  esac
done < <(bash "$HOOK_DIR/path-resolve.sh" 2>/dev/null)
[ "$GOT_ROOT" = 1 ] || exit 0

# squote <value>: single-quoted shell word, safe for spaces and quotes.
squote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Drop earlier lines for our own keys (idempotence), keep everything else.
TMP="$(mktemp "${TMPDIR:-/tmp}/squad-env.XXXXXX" 2>/dev/null)" || exit 0
if [ -f "$CLAUDE_ENV_FILE" ]; then
  grep -Ev '^export SQUAD_(VAULT_PATH|PROJECT_ROOT|DISPLAY_NAME|DIR|TRACKER_MODE)=' "$CLAUDE_ENV_FILE" > "$TMP" 2>/dev/null || true
fi
{
  printf 'export SQUAD_VAULT_PATH=%s\n' "$(squote "$V_VAULT")"
  printf 'export SQUAD_PROJECT_ROOT=%s\n' "$(squote "$V_ROOT")"
  printf 'export SQUAD_DISPLAY_NAME=%s\n' "$(squote "$V_NAME")"
  printf 'export SQUAD_DIR=%s\n' "$(squote "$V_DIR")"
  printf 'export SQUAD_TRACKER_MODE=%s\n' "$(squote "$V_MODE")"
} >> "$TMP"
cat "$TMP" > "$CLAUDE_ENV_FILE" 2>/dev/null
rm -f "$TMP"
exit 0
