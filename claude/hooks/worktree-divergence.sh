#!/usr/bin/env bash
# worktree-divergence.sh -- round preflight for `claude -w` worktree sessions:
# fetch, compare HEAD with origin/<branch> and with the base, fast-forward when
# safe. Contract: SCRIPT_CONTRACT.md. Bash 3.2; no jq, no gh calls.
#
# Usage: worktree-divergence.sh check [--base <base>] [--no-ff]
#   Operates on the cwd's repository (a linked worktree). --base defaults to
#   the base lore-orient.sh resolved at session start (open PR, then
#   progress.txt, then main) and stored in <git-dir>/squad-base; main when
#   that file is absent. --no-ff only reports. (The former --expect-head /
#   --expect-base flags are gone: no coordinator template exists since #295;
#   the hook note asks Claude to report head before -> after and base head.)
#   The fetch is bounded (SQUAD_FETCH_TIMEOUT, default 8s) and never prompts.
#
# Output: OUTCOME (applied = fast-forwarded | unchanged), CHANGED, BRANCH, BASE,
#   HEAD_BEFORE, HEAD_AFTER, BASE_HEAD, ORIGIN_STATE (in-sync|behind|ahead|
#   diverged|no-upstream), ORIGIN_AHEAD, ORIGIN_BEHIND (commits HEAD has /
#   lacks versus origin/<branch>), BASE_AHEAD (commits origin/<base> has that
#   HEAD lacks), BASE_BEHIND, DIRTY (yes|no), FAST_FORWARDED (yes|no).
# Exit: 0 ok (incl. behind-but-dirty: reported, nothing moved), 2 usage,
#   10 stop and ask (diverged, detached HEAD), 20 fetch/git failure.
#   Keys are emitted before exit 10 so the round report can still state heads.
# Never merges, resets, stashes or checks out: only `merge --ff-only`.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

[ "${1:-}" = check ] || squad_fail 2 "usage: worktree-divergence.sh check [--base <base>] [--no-ff]"
shift
BASE=""; FF=1
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || squad_fail 2 "--base requires a value"; BASE="$2"; shift 2 ;;
    --no-ff) FF=0; shift ;;
    *) squad_fail 2 "unknown argument '$1'" ;;
  esac
done
case "$BASE" in -*) squad_fail 2 "invalid base name '$BASE'" ;; esac

G() { git -C "$PWD" "$@"; }
G rev-parse --git-dir >/dev/null 2>&1 || squad_fail 20 "not inside a git repository"
G remote get-url origin >/dev/null 2>&1 || squad_fail 20 "no 'origin' remote configured"
BRANCH="$(G symbolic-ref -q --short HEAD 2>/dev/null || true)"
HEAD_BEFORE="$(G rev-parse HEAD 2>/dev/null)" || squad_fail 20 "cannot read HEAD"

# Bounded, non-interactive fetch: timeout/gtimeout when present, else
# background + watchdog kill (same pattern as lore-nudge.sh).
export GIT_TERMINAL_PROMPT=0
BOUND="${SQUAD_FETCH_TIMEOUT:-8}"
TO="$(command -v timeout || command -v gtimeout || true)"
if [ -n "$TO" ]; then
  "$TO" "$BOUND" git -C "$PWD" fetch -q origin >/dev/null 2>&1 </dev/null || squad_fail 20 "git fetch origin failed or timed out"
else
  git -C "$PWD" fetch -q origin >/dev/null 2>&1 </dev/null &
  FPID=$!
  ( sleep "$BOUND"; kill "$FPID" 2>/dev/null ) >/dev/null 2>&1 &
  WPID=$!
  wait "$FPID" 2>/dev/null; FRC=$?
  pkill -P "$WPID" 2>/dev/null; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
  [ "$FRC" -eq 0 ] || squad_fail 20 "git fetch origin failed or timed out"
fi

if [ -z "$BASE" ]; then
  BASE="$(head -n 1 "$(G rev-parse --absolute-git-dir)/squad-base" 2>/dev/null)"
  case "$BASE" in ""|-*) BASE=main ;; esac
fi

DIRTY=no
[ -n "$(G status --porcelain --untracked-files=no 2>/dev/null)" ] && DIRTY=yes

BASE_HEAD=""; BASE_AHEAD=0; BASE_BEHIND=0
if G rev-parse -q --verify "refs/remotes/origin/$BASE" >/dev/null 2>&1; then
  BASE_HEAD="$(G rev-parse "refs/remotes/origin/$BASE")"
  BASE_AHEAD="$(G rev-list --count "HEAD..refs/remotes/origin/$BASE")"
  BASE_BEHIND="$(G rev-list --count "refs/remotes/origin/$BASE..HEAD")"
fi

STATE=no-upstream; O_AHEAD=0; O_BEHIND=0; FFD=no
if [ -n "$BRANCH" ] && G rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
  O_AHEAD="$(G rev-list --count "refs/remotes/origin/$BRANCH..HEAD")"
  O_BEHIND="$(G rev-list --count "HEAD..refs/remotes/origin/$BRANCH")"
  if [ "$O_AHEAD" -gt 0 ] && [ "$O_BEHIND" -gt 0 ]; then STATE=diverged
  elif [ "$O_BEHIND" -gt 0 ]; then STATE=behind
  elif [ "$O_AHEAD" -gt 0 ]; then STATE=ahead
  else STATE=in-sync; fi
  if [ "$STATE" = behind ] && [ "$DIRTY" = no ] && [ "$FF" = 1 ]; then
    if G merge -q --ff-only "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
      FFD=yes; O_BEHIND=0; STATE=in-sync
    else
      squad_fail 20 "fast-forward to origin/$BRANCH failed"
    fi
  fi
fi
HEAD_AFTER="$(G rev-parse HEAD)"

if [ "$FFD" = yes ]; then squad_emit OUTCOME applied; squad_emit CHANGED yes
else squad_emit OUTCOME unchanged; squad_emit CHANGED no; fi
squad_emit BRANCH "$BRANCH"
squad_emit BASE "$BASE"
squad_emit HEAD_BEFORE "$HEAD_BEFORE"
squad_emit HEAD_AFTER "$HEAD_AFTER"
squad_emit BASE_HEAD "$BASE_HEAD"
squad_emit ORIGIN_STATE "$STATE"
squad_emit ORIGIN_AHEAD "$O_AHEAD"
squad_emit ORIGIN_BEHIND "$O_BEHIND"
squad_emit BASE_AHEAD "$BASE_AHEAD"
squad_emit BASE_BEHIND "$BASE_BEHIND"
squad_emit DIRTY "$DIRTY"
squad_emit FAST_FORWARDED "$FFD"

[ -n "$BRANCH" ] || squad_fail 10 "detached HEAD: no branch to compare with origin"
[ "$STATE" != diverged ] || squad_fail 10 "branch $BRANCH has diverged from origin/$BRANCH ($O_AHEAD ahead, $O_BEHIND behind): stop and ask, do not merge blindly"
exit 0
