#!/usr/bin/env bash
# golden-check.sh — golden-set regression check for a project's orientation.
#
# Runs each question of <vault>/projects/<name>/golden.md in a cold
# headless session (`claude -p`) that sees exactly the orientation the
# SessionStart hook (lore-orient.sh) injects, and nothing else. Answers
# are stored in <vault>/projects/<name>/golden-runs/<date>.md and diffed
# per question against the previous run. Regression-based: no absolute
# score, only "changed" / "unchanged". Run it by hand after editing any
# skill, agent, hook or rule file.
#
# Read-only outside golden-runs/. Always exits 0 (informational).
#
# Usage: scripts/golden-check.sh [--project <name>]
#   --project <name>  Must match the project resolved from the current
#                     checkout (the orientation is always built for the cwd's
#                     project); a different name exits 2.
# Env: SQUAD_LORE_MODEL (default haiku) selects the headless model.

set -uo pipefail

PROJECT_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "golden-check: --project needs a value." >&2; exit 2; fi
      PROJECT_OVERRIDE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

find_hook() {
  for c in "$REPO_ROOT/claude/hooks/$1" "$HOME/.claude/hooks/$1"; do
    if [ -f "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

PATH_RESOLVE="$(find_hook path-resolve.sh)" || { echo "golden-check: cannot find path-resolve.sh" >&2; exit 2; }
ORIENT="$(find_hook lore-orient.sh)" || { echo "golden-check: cannot find lore-orient.sh" >&2; exit 2; }

VAULT_PATH=""; PROJECT_ROOT=""; DISPLAY_NAME=""
while IFS='=' read -r key value; do
  case "$key" in
    VAULT_PATH) VAULT_PATH="$value" ;;
    PROJECT_ROOT) PROJECT_ROOT="$value" ;;
    DISPLAY_NAME) DISPLAY_NAME="$value" ;;
  esac
done < <(bash "$PATH_RESOLVE")

NAME="$DISPLAY_NAME"
[ -z "$NAME" ] && [ -n "$PROJECT_ROOT" ] && NAME="$(basename "$PROJECT_ROOT")"
if [ -n "$PROJECT_OVERRIDE" ] && [ -n "$NAME" ] && [ "$PROJECT_OVERRIDE" != "$NAME" ]; then
  echo "golden-check: run golden-check from $PROJECT_OVERRIDE's checkout (current project is $NAME)." >&2
  exit 2
fi
if [ -z "$VAULT_PATH" ] || [ -z "$NAME" ]; then
  echo "golden-check: could not resolve vault or project name." >&2
  exit 2
fi

GOLDEN="$VAULT_PATH/projects/$NAME/golden.md"
if [ ! -f "$GOLDEN" ]; then
  echo "golden-check: $GOLDEN not found (run /seed first)." >&2
  exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "golden-check: claude CLI not on PATH." >&2
  exit 0
fi

# Orientation: exactly what the SessionStart hook would inject.
# The hook emits a JSON envelope (systemMessage + additionalContext with the
# same text); keep only additionalContext, as a real session sees it. Falls
# back to the raw output when it is not JSON.
RAW_ORIENT="$(cd "${PROJECT_ROOT:-.}" && printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "${PROJECT_ROOT:-.}" | bash "$ORIENT" 2>/dev/null)"
ORIENTATION=""
if command -v jq >/dev/null 2>&1; then
  ORIENTATION="$(printf '%s' "$RAW_ORIENT" | jq -r '(.hookSpecificOutput.additionalContext // .additionalContext // empty)' 2>/dev/null)"
fi
[ -z "$ORIENTATION" ] && ORIENTATION="$RAW_ORIENT"

RUNS="$VAULT_PATH/projects/$NAME/golden-runs"
mkdir -p "$RUNS"
STAMP="$(date +%Y-%m-%d)"
OUT="$RUNS/$STAMP.md"
[ -e "$OUT" ] && OUT="$RUNS/$STAMP-$(date +%H%M).md"

# Previous run = most recently modified other file (name order is not
# chronological once a -HHMM suffix exists).
PREV=""
while IFS= read -r f; do
  if [ "$f" != "$OUT" ]; then PREV="$f"; break; fi
done < <(ls -t "$RUNS"/*.md 2>/dev/null)

TMO=""
command -v timeout >/dev/null 2>&1 && TMO="timeout 300"

# Parse questions: "## Q<n>" heading, body up to "Expected:" (exclusive).
QDIR="$(mktemp -d)"
# Neutral cwd for claude: no project CLAUDE.md or .claude/ gets discovered.
NEUTRAL="$(mktemp -d)"
trap 'rm -rf "$QDIR" "$NEUTRAL"' EXIT
awk -v dir="$QDIR" '
  /^## Q[0-9]+[[:space:]]*$/ { n=$2; sub(/^Q/,"",n); f=dir "/" n ".q"; printf "" > f; inq=1; next }
  /^## / { inq=0 }
  inq && /^Expected:/ { inq=0; next }
  inq { print >> f }
' "$GOLDEN"

{
  echo "# Golden run $STAMP — $NAME"
  echo
} > "$OUT"

for n in $(ls "$QDIR" | sed 's/\.q$//' | sort -n); do
  QUESTION="$(cat "$QDIR/$n.q")"
  PROMPT="You are starting a fresh session. The following is the only context you have:

$ORIENTATION

Answer the question below using only that context. If it cannot be answered from it, say so.

Question: $QUESTION"
  # Isolation flags, so answers do not depend on the machine:
  #   --setting-sources ""        no user/project/local settings, hence no
  #                               SessionStart hook (orientation would double)
  #   --tools ""                  no tools; answer from the prompt only
  #   --disable-slash-commands    no skills
  #   --strict-mcp-config + empty --mcp-config   no MCP servers
  #   --no-session-persistence    leave no session on disk
  # Run from a neutral cwd so no CLAUDE.md is discovered.
  if ANSWER="$(cd "$NEUTRAL" && $TMO claude -p "$PROMPT" --model "${SQUAD_LORE_MODEL:-haiku}" \
      --setting-sources "" --tools "" --disable-slash-commands \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --no-session-persistence 2>/dev/null </dev/null)" && [ -n "$ANSWER" ]; then
    :
  else
    ANSWER="(error) claude -p failed"
  fi
  { echo "## Q$n"; echo "$ANSWER"; echo; } >> "$OUT"
done

echo "Run stored: $OUT"

if [ -z "$PREV" ]; then
  echo "No baseline: this is the first run, nothing to diff."
  exit 0
fi

section() { # file n -> normalized section body
  awk -v want="## Q$2" '
    $0 == want { on=1; next }
    /^## Q[0-9]+[[:space:]]*$/ { on=0 }
    on { print }
  ' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

echo "Diff against $(basename "$PREV"):"
CHANGED=0; SAME=0; ERRORS=0
for n in $(ls "$QDIR" | sed 's/\.q$//' | sort -n); do
  if [ "$(section "$OUT" "$n")" = "(error) claude -p failed" ]; then
    echo "  Q$n: error"; ERRORS=$((ERRORS + 1))
  elif [ "$(section "$OUT" "$n")" = "$(section "$PREV" "$n")" ]; then
    echo "  Q$n: unchanged"; SAME=$((SAME + 1))
  else
    echo "  Q$n: changed"; CHANGED=$((CHANGED + 1))
  fi
done
echo "$CHANGED changed / $SAME unchanged / $ERRORS errors"
exit 0
