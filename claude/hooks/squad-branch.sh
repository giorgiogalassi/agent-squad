#!/usr/bin/env bash
# squad-branch.sh -- branch checkout mechanics for Cody (create vs continue).
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq, no gh calls.
#
# Usage:
#   squad-branch.sh create   <branch> --base <base>
#   squad-branch.sh continue <branch> --base <base>
#
# Fetch (both verbs), mode-dependent (TRACKER_MODE from squad_resolve):
#   origin remote present: `git fetch origin` (quiet). On failure: detached ->
#     one stderr warning, continue with local refs; connected -> exit 20.
#   no origin remote: detached -> continue silently with local refs;
#     connected -> exit 20 naming the missing remote.
# Base resolution (both modes): origin/<base> if it exists, else local <base>
# if it exists, else exit 10. BASE_REF reports which one was used. Detached
# stacks never push, so a local-only base is normal there.
#   create:   no local <branch> -> create it from BASE_REF (no upstream
#             set) and check it out: applied. Local <branch> already checked
#             out in this worktree -> unchanged. Local <branch> exists but is
#             not checked out -> check it out: applied. An existing local
#             branch is accepted whatever its merge-base with origin/<base>
#             is; topology is the caller's concern, not this script's.
#   continue: check out the existing local <branch>: applied (unchanged if
#             already checked out). No local branch but origin/<branch>
#             exists -> create a tracking local branch: applied. Neither
#             -> exit 10.
# A branch checked out in ANOTHER worktree is detected with
# `git worktree list --porcelain` before any checkout: exit 10, the stderr
# line names that worktree path. Never uses checkout -f, stash or reset.
# Operates on the cwd's repository (may be a linked worktree) with plain git
# commands; never derives the project root from `git rev-parse --show-toplevel`.
#
# Output: OUTCOME (applied|unchanged), CHANGED (yes|no), BRANCH, BASE,
# BASE_REF (origin/<base>|<base>), HEAD_SHA.
# Exit: 0 ok, 2 usage, 10 precondition (base/branch missing, checked out
# elsewhere, checkout blocked), 20 fetch/io failure (connected mode only for
# fetch problems). Git exit codes are
# never passed through.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
[ -n "$VERB" ] || squad_fail 2 "usage: squad-branch.sh create|continue <branch> --base <base>"
shift
case "$VERB" in create|continue) ;; *) squad_fail 2 "unknown verb '$VERB'" ;; esac

BRANCH=""; BASE=""
[ $# -ge 1 ] || squad_fail 2 "$VERB requires a branch name"
BRANCH="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || squad_fail 2 "--base requires a value"
      BASE="$2"; shift 2 ;;
    *) squad_fail 2 "unknown argument '$1'" ;;
  esac
done
[ -n "$BASE" ] || squad_fail 2 "$VERB requires --base"
case "$BRANCH" in -*) squad_fail 2 "invalid branch name '$BRANCH'" ;; esac
case "$BASE" in -*) squad_fail 2 "invalid base name '$BASE'" ;; esac
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || squad_fail 2 "invalid branch name '$BRANCH'"

G() { git -C "$PWD" "$@"; }

G rev-parse --git-dir >/dev/null 2>&1 || squad_fail 20 "not inside a git repository"
squad_resolve || squad_fail_incident squad-branch 20 "cannot resolve tracker mode"

if G remote get-url origin >/dev/null 2>&1; then
  if ! G fetch -q origin >/dev/null 2>&1; then
    if [ "$TRACKER_MODE" = connected ]; then
      squad_fail_incident squad-branch 20 "git fetch origin failed"
    fi
    echo "squad-branch: git fetch origin failed; continuing with local refs" >&2
  fi
elif [ "$TRACKER_MODE" = connected ]; then
  squad_fail 20 "no 'origin' remote configured (required in connected mode)"
fi

if G rev-parse -q --verify "refs/remotes/origin/$BASE" >/dev/null 2>&1; then
  BASE_REF="origin/$BASE"
elif G rev-parse -q --verify "refs/heads/$BASE" >/dev/null 2>&1; then
  BASE_REF="$BASE"
else
  squad_fail 10 "base $BASE not found locally or on origin"
fi

CURRENT="$(G symbolic-ref -q --short HEAD 2>/dev/null || true)"
HAVE_LOCAL=0
G rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1 && HAVE_LOCAL=1

finish() {  # finish <outcome> <changed>
  local sha
  sha="$(G rev-parse HEAD 2>/dev/null)" || squad_fail_incident squad-branch 20 "cannot read HEAD"
  squad_emit OUTCOME "$1"; squad_emit CHANGED "$2"
  squad_emit BRANCH "$BRANCH"; squad_emit BASE "$BASE"
  squad_emit BASE_REF "$BASE_REF"; squad_emit HEAD_SHA "$sha"
  exit 0
}

if [ "$HAVE_LOCAL" = 1 ] && [ "$CURRENT" = "$BRANCH" ]; then
  finish unchanged no
fi

# Checked out in another worktree? (This worktree's branch was handled above.)
if [ "$HAVE_LOCAL" = 1 ]; then
  WT_PATH=""; OTHER=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) WT_PATH="${line#worktree }" ;;
      "branch refs/heads/$BRANCH") OTHER="$WT_PATH" ;;
    esac
  done <<EOF2
$(G worktree list --porcelain 2>/dev/null)
EOF2
  [ -z "$OTHER" ] || squad_fail 10 "branch '$BRANCH' is checked out in another worktree: $OTHER"
fi

if [ "$HAVE_LOCAL" = 1 ]; then
  G checkout -q "$BRANCH" >/dev/null 2>&1 || squad_fail 10 "cannot check out '$BRANCH' (local changes in the way?)"
  finish applied yes
fi

if [ "$VERB" = create ]; then
  G checkout -q --no-track -b "$BRANCH" "$BASE_REF" >/dev/null 2>&1 \
    || squad_fail 10 "cannot create '$BRANCH' from $BASE_REF"
  finish applied yes
fi

# continue, no local branch
G rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1 \
  || squad_fail 10 "branch '$BRANCH' does not exist locally or on origin"
G checkout -q --track -b "$BRANCH" "origin/$BRANCH" >/dev/null 2>&1 \
  || squad_fail 10 "cannot create tracking branch '$BRANCH'"
finish applied yes
