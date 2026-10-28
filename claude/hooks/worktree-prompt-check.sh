#!/usr/bin/env bash
# worktree-prompt-check.sh -- UserPromptSubmit hook. Inside a `claude -w` worktree
# session (a linked worktree under .claude/worktrees/) it runs the round
# preflight (worktree-divergence.sh) and prints a short note that Claude Code
# adds to the prompt context. Anywhere else it exits 0 silently after two
# local git calls (no fetch). The routine note is
# not repeated while unchanged; STOP / dirty-behind notes repeat on every prompt.
# Never blocks the prompt: always exits 0.

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || exit 0
GD="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
CD="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
[ "$(cd "$GD" && pwd -P)" != "$(cd "$CD" && pwd -P)" ] || exit 0
case "$(pwd -P)" in */.claude/worktrees/*) ;; *) exit 0 ;; esac

LOUD=0
OUT="$(bash "$(dirname "${BASH_SOURCE[0]}")/worktree-divergence.sh" check 2>&1)"; RC=$?
k() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
if [ "$RC" = 20 ]; then
  NOTE="Worktree preflight: could not fetch or compare with origin ($(printf '%s' "$OUT" | tail -1)). Heads are unverified."
else
  NOTE="Worktree preflight: head $(k HEAD_BEFORE | cut -c1-9) -> $(k HEAD_AFTER | cut -c1-9); origin/$(k BRANCH): $(k ORIGIN_STATE) (ahead $(k ORIGIN_AHEAD), behind $(k ORIGIN_BEHIND)); base $(k BASE) at $(k BASE_HEAD | cut -c1-9) (ahead $(k BASE_AHEAD), behind $(k BASE_BEHIND))."
  [ "$(k FAST_FORWARDED)" = yes ] && NOTE="$NOTE Fast-forwarded to origin."
  [ "$(k ORIGIN_STATE)" = behind ] && [ "$(k DIRTY)" = yes ] && { NOTE="$NOTE STOP: behind origin with a dirty tree, not moved. Ask the user before pulling, committing or pushing."; LOUD=1; }
  [ "$RC" = 10 ] && { NOTE="$NOTE STOP: diverged or detached. Do not merge or push; ask the user first."; LOUD=1; }
  [ "$(k BASE_AHEAD)" != 0 ] && NOTE="$NOTE Base is ahead; merge it only if the round's instructions say so."
  NOTE="$NOTE Start this round's report with: head <before> -> <after>, base head <sha>."
fi
[ "$RC" = 20 ] && LOUD=1
LAST="$GD/squad-divergence.last"
[ "$LOUD" = 0 ] && [ "$(cat "$LAST" 2>/dev/null)" = "$NOTE" ] && exit 0
printf '%s\n' "$NOTE" > "$LAST" 2>/dev/null
printf '%s\n' "$NOTE"
exit 0
