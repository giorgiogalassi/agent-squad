#!/usr/bin/env bash
# session-summary.sh — read-only summary of a squad session for one project.
#
# A human runs this on demand to see "what happened" without opening
# session.log, progress.txt, and the vault's git history by hand. It is
# a script, not a hook: nothing in claude/ or codex/ invokes it
# automatically, so it lives in scripts/ alongside squad-lint.sh
# (#118/#140) rather than in claude/hooks or codex/hooks.
#
# Strictly read-only: this script never writes, moves, or deletes
# anything under the vault or the workspace. It only reads
# session.log, progress.txt, and the vault's own git history (via
# `git --no-optional-locks`, which skips even the opportunistic index
# refresh `git status`/`git log` would otherwise perform).
#
# Paths are resolved via path-resolve.sh, never re-derived. Because
# this script lives outside claude/hooks and codex/hooks (it is not a
# hook), it looks for path-resolve.sh in, in order: this repo's own
# claude/hooks/ or codex/hooks/ copy (so it works from a checkout with
# nothing installed), then the installed ~/.claude/hooks/ and
# ~/.codex/hooks/ copies. First one found wins.
#
# Single copy, no codex mirror: this script never touches claude/ or
# codex/ skill/agent prose, only vault state plus path-resolve.sh's
# KEY=VALUE stdout contract, which is identical on both platforms. A
# per-platform mirror would duplicate logic with nothing to diverge on.
#
# Each of the three inputs (session.log, progress.txt, vault git
# history) degrades independently: a missing file, or a vault that is
# not a git repository, prints a one-line "not available" notice for
# that section instead of failing the whole summary.
#
# Usage: scripts/session-summary.sh [--project <name>] [--lines <n>]
#   --project <name>  Override the resolved display name (useful when
#                      the vault has no lore-config.json mapping yet).
#   --lines <n>       Number of trailing session.log / progress.txt /
#                      git log entries to show verbatim. Default 10.

set -uo pipefail

PROJECT_OVERRIDE=""
TAIL_LINES=10

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT_OVERRIDE="$2"
      shift 2
      ;;
    --lines)
      TAIL_LINES="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------
# Resolve path-resolve.sh: prefer a copy checked into this repo, then
# fall back to an installed one. Never re-derive the algorithm inline.
# ---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PATH_RESOLVE=""
for candidate in \
  "$REPO_ROOT/claude/hooks/path-resolve.sh" \
  "$REPO_ROOT/codex/hooks/path-resolve.sh" \
  "$HOME/.claude/hooks/path-resolve.sh" \
  "$HOME/.codex/hooks/path-resolve.sh"
do
  if [ -x "$candidate" ] || [ -f "$candidate" ]; then
    PATH_RESOLVE="$candidate"
    break
  fi
done

if [ -z "$PATH_RESOLVE" ]; then
  echo "session-summary: cannot find path-resolve.sh (checked repo claude/codex hooks and ~/.claude, ~/.codex hooks); cannot resolve paths without it." >&2
  exit 2
fi

# Parse KEY=VALUE lines individually rather than eval'ing them (#112
# hardening — a vault path with shell metacharacters must not execute).
VAULT_PATH=""
PROJECT_ROOT=""
DISPLAY_NAME=""
while IFS='=' read -r key value; do
  case "$key" in
    VAULT_PATH) VAULT_PATH="$value" ;;
    PROJECT_ROOT) PROJECT_ROOT="$value" ;;
    DISPLAY_NAME) DISPLAY_NAME="$value" ;;
  esac
done < <(bash "$PATH_RESOLVE")

if [ -z "$VAULT_PATH" ]; then
  echo "session-summary: path-resolve.sh returned no VAULT_PATH; cannot continue." >&2
  exit 2
fi

DISPLAY="$PROJECT_OVERRIDE"
if [ -z "$DISPLAY" ]; then
  DISPLAY="$DISPLAY_NAME"
fi
if [ -z "$DISPLAY" ] && [ -n "$PROJECT_ROOT" ]; then
  DISPLAY="$(basename "$PROJECT_ROOT")"
fi
if [ -z "$DISPLAY" ]; then
  echo "session-summary: could not resolve a project display name (no lore-config.json mapping, no --project, no PROJECT_ROOT to fall back to)." >&2
  exit 2
fi

SQUAD_DIR="$VAULT_PATH/projects/$DISPLAY/.squad"
SESSION_LOG="$SQUAD_DIR/session.log"
PROGRESS="$SQUAD_DIR/progress.txt"

echo "Session summary — $DISPLAY"
echo "Vault:   $VAULT_PATH"
echo "Squad:   $SQUAD_DIR"
echo

# ---------------------------------------------------------------------
# session.log: per-agent counts of start/end/other events, plus the
# last N lines verbatim.
# ---------------------------------------------------------------------
echo "== session.log =="
if [ -f "$SESSION_LOG" ]; then
  TOTAL=$(grep -c . "$SESSION_LOG" 2>/dev/null); TOTAL=${TOTAL:-0}
  echo "$TOTAL entries."
  echo
  echo "By agent:"
  grep -oE '\[[a-z][a-z0-9_-]*\]' "$SESSION_LOG" \
    | grep -vE '^\[[0-9]' \
    | sort | uniq -c | sort -rn \
    | awk '{printf "  %-6s %s\n", $1, $2}'
  echo
  echo "Last $TAIL_LINES entries:"
  tail -n "$TAIL_LINES" "$SESSION_LOG" | sed 's/^/  /'
else
  echo "not available: $SESSION_LOG does not exist."
fi
echo

# ---------------------------------------------------------------------
# progress.txt: counts by outcome (resolved / no-op / escalated /
# skipped / other), plus the last N lines verbatim.
# ---------------------------------------------------------------------
echo "== progress.txt =="
if [ -f "$PROGRESS" ]; then
  TOTAL=$(grep -c . "$PROGRESS" 2>/dev/null); TOTAL=${TOTAL:-0}
  ISSUE_LINES=$(grep -c '^\[#' "$PROGRESS" 2>/dev/null); ISSUE_LINES=${ISSUE_LINES:-0}
  ESCALATED=$(grep -c 'ESCALATED' "$PROGRESS" 2>/dev/null); ESCALATED=${ESCALATED:-0}
  NOOP=$(grep -c 'no-op' "$PROGRESS" 2>/dev/null); NOOP=${NOOP:-0}
  SKIPPED=$(grep -c 'SKIPPED' "$PROGRESS" 2>/dev/null); SKIPPED=${SKIPPED:-0}
  RESOLVED=$(grep -cE '^\[#[0-9]+\] .*resolved' "$PROGRESS" 2>/dev/null); RESOLVED=${RESOLVED:-0}
  # "resolved, no-op" and "resolved. PR:" both match RESOLVED above;
  # report no-op and escalated as sub-categories rather than double
  # counting against a separate "clean resolved" bucket.
  echo "$TOTAL lines ($ISSUE_LINES per-issue entries)."
  echo "  resolved (incl. no-op): $RESOLVED"
  echo "  no-op:                  $NOOP"
  echo "  escalated:              $ESCALATED"
  echo "  skipped:                $SKIPPED"
  echo
  echo "Last $TAIL_LINES entries:"
  tail -n "$TAIL_LINES" "$PROGRESS" | fold -s -w 100 | sed 's/^/  /'
else
  echo "not available: $PROGRESS does not exist."
fi
echo

# ---------------------------------------------------------------------
# Vault git history: read-only via --no-optional-locks (skips even the
# opportunistic index refresh git would otherwise perform). Degrades
# to a notice if the vault is not a git repository.
# ---------------------------------------------------------------------
echo "== vault git history =="
if git --no-optional-locks -C "$VAULT_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Last $TAIL_LINES commits (whole vault):"
  git --no-optional-locks -C "$VAULT_PATH" log -n "$TAIL_LINES" --format='  %h %ad %s' --date=short 2>/dev/null
  echo
  UNCOMMITTED=$(git --no-optional-locks -C "$VAULT_PATH" status --porcelain -- "projects/$DISPLAY" 2>/dev/null)
  if [ -n "$UNCOMMITTED" ]; then
    echo "Uncommitted changes under projects/$DISPLAY (live state, not yet in vault history):"
    echo "$UNCOMMITTED" | sed 's/^/  /'
  else
    echo "No uncommitted changes under projects/$DISPLAY."
  fi
else
  echo "not available: $VAULT_PATH is not a git repository."
fi
