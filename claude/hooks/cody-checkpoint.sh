#!/usr/bin/env bash
# Cody SubagentStop checkpoint. Derives the status.md checkpoint line and the
# progress.txt line from git evidence when Cody finishes (or is stopped at
# maxTurns), so they no longer depend on Cody's prose remembering to write them.
#
# Registered by hooks/hooks.json as an async SubagentStop hook with matcher
# "cody|agent-squad:cody". It only records: it always exits 0 and never blocks the subagent
# from stopping. Hook input (JSON on stdin) is read for `cwd` and `agent_type`.
#
# Evidence, in the working directory (same checks as Ralph 2b):
#   branch, HEAD sha + subject, `status --porcelain`, and in connected mode an
#   open PR for the branch (`gh pr list --head`).
# The issue ID is taken from HEAD's subject ([#N] or [KEY-N]); no ID, or a
# shared integration branch, means Cody committed nothing: no write.
#
# STATE: pr (open PR) | committed (connected, commit but no PR) |
#        detached (detached mode, commit ready for manual push).
# Writes: one `lore-checkpoint.sh --note` line; for STATE=pr also one
# progress.txt line `[ID] resolved. PR: #N (base: B). Notes: <subject>`
# (the `(base: ...)` token is what Reven reads). Both idempotent per sha / PR.
# Summary for Ralph 2b: <vault>/projects/<name>/.squad/cody-checkpoint.env
# (KEY=value, overwritten each run, never committed). Log: .cody-checkpoint.log in the project dir.

[ -n "${SQUAD_LORE_HOOK:-}" ] && exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

INPUT="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
CWD=""; AGENT=""
{ IFS= read -r CWD; IFS= read -r AGENT; } < <(printf '%s' "$INPUT" | jq -r '(.cwd // ""), (.agent_type // "")' 2>/dev/null)
case "$AGENT" in ""|cody|*:cody) ;; *) exit 0 ;; esac
[ -z "$CWD" ] && CWD="$PWD"
cd "$CWD" 2>/dev/null || exit 0

while IFS='=' read -r _key _value; do
  case "$_key" in
    VAULT_PATH) VAULT="$_value" ;;
    PROJECT_ROOT) ROOT="$_value" ;;
    DISPLAY_NAME) DISPLAY="$_value" ;;
    TRACKER_MODE) TMODE="$_value" ;;
  esac
done < <("$HOOK_DIR/path-resolve.sh" 2>/dev/null)
[ -d "${VAULT:-}" ] && [ -n "${ROOT:-}" ] || exit 0
[ -z "${DISPLAY:-}" ] && DISPLAY="$(basename "$ROOT")"
PROJ="$VAULT/projects/$DISPLAY"
LOG="$PROJ/.cody-checkpoint.log"
ENVF="$PROJ/.squad/cody-checkpoint.env"
skip() { rm -f "$ENVF"; printf '[%s] %s\n' "$(date "+%Y-%m-%d %H:%M")" "$1" > "$LOG" 2>/dev/null; exit 0; }
[ -d "$PROJ" ] || exit 0

BRANCH="$(git branch --show-current 2>/dev/null)"
SHA="$(git rev-parse --short HEAD 2>/dev/null)"
SUBJECT="$(git log -1 --format=%s 2>/dev/null)"
[ -n "$BRANCH" ] && [ -n "$SHA" ] || skip "no branch or commit in $CWD"
case "$BRANCH" in main|master|develop|release/*|hotfix/*) skip "shared branch $BRANCH, nothing to record" ;; esac
ISSUE="$(printf '%s' "$SUBJECT" | sed -n 's/^\[\([^]]*\)\].*/\1/p')"
[ -n "$ISSUE" ] || skip "HEAD $SHA carries no issue ID, nothing to record"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
TREE=clean; [ "${DIRTY:-0}" -gt 0 ] && TREE=dirty

STATE=committed; PR=""; BASE=""
if [ "${TMODE:-detached}" = connected ]; then
  if command -v gh >/dev/null 2>&1; then
    row="$(gh pr list --head "$BRANCH" --state open --json number,baseRefName --jq '.[0] | select(. != null) | "\(.number) \(.baseRefName)"' 2>/dev/null)"
    PR="${row%% *}"; BASE="${row#* }"; [ -n "$PR" ] || BASE=""
  fi
  [ -n "$PR" ] && STATE=pr
else
  STATE=detached
fi

# HEAD-moved check: Cody committed nothing when HEAD already belongs to
# another branch or does not match the branch's own issue. Neither guard needs a
# PR (a branch with no commit cannot have one).
# (a) HEAD is reachable from any other local or remote branch (the stacked base,
#     main, ...), excluding this branch and its own origin/<branch>.
_others="$(git for-each-ref --format='%(refname)' --contains HEAD refs/heads refs/remotes 2>/dev/null \
  | grep -vxF -e "refs/heads/$BRANCH" -e "refs/remotes/origin/$BRANCH" | head -n 1)"
[ -z "$_others" ] || skip "HEAD $SHA is already on ${_others#refs/}, nothing to record"
# (b) the branch name starts with an issue ID (296-... or KEY-123-...) that differs
#     from the one in HEAD's subject (a stack tip commit such as [#293]).
_bid="$(printf '%s' "$BRANCH" | sed -n -e 's/^\([A-Z][A-Z0-9]*-[0-9][0-9]*\)\(-.*\)\{0,1\}$/\1/p' -e 's/^\([0-9][0-9]*\)\(-.*\)\{0,1\}$/\1/p' | head -n 1)"
if [ -n "$_bid" ] && [ "${ISSUE#\#}" != "$_bid" ]; then
  skip "HEAD $SHA is for [$ISSUE], branch $BRANCH is for $_bid, nothing to record"
fi

NOW="$(date "+%Y-%m-%d %H:%M")"
case "$STATE" in
  pr) LINE="[$NOW] [claude-code] PR #$PR opened. Branch: $BRANCH @ $SHA. $SUBJECT" ;;
  detached) LINE="[$NOW] [claude-code] Branch $BRANCH ready for manual push @ $SHA. $SUBJECT" ;;
  *) LINE="[$NOW] [claude-code] Branch $BRANCH committed @ $SHA, no PR yet. $SUBJECT" ;;
esac

STATUS="$PROJ/status.md"
if [ -f "$STATUS" ] && ! grep -qF "$BRANCH @ $SHA" "$STATUS"; then
  bash "$HOOK_DIR/lore-checkpoint.sh" --note "$LINE" >/dev/null 2>&1
fi

PROGRESS="$PROJ/.squad/progress.txt"
if [ "$STATE" = pr ] && [ -d "$PROJ/.squad" ] && ! { grep -F "[$ISSUE] " "$PROGRESS" 2>/dev/null | grep -qE "PR: #$PR( |$)"; }; then
  printf '[%s] resolved. PR: #%s (base: %s). Notes: %s\n' "$ISSUE" "$PR" "$BASE" "$SUBJECT" >> "$PROGRESS"
  if git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$VAULT" add "projects/$DISPLAY/.squad/progress.txt" >/dev/null 2>&1
    git -C "$VAULT" commit -q -m "lore: progress $DISPLAY" -- "projects/$DISPLAY/.squad/progress.txt" >/dev/null 2>&1 || true
  fi
fi

if [ -d "$PROJ/.squad" ]; then
  printf 'STATE=%s\nISSUE=%s\nBRANCH=%s\nSHA=%s\nTREE=%s\nPR=%s\nBASE=%s\nAT=%s\n' \
    "$STATE" "$ISSUE" "$BRANCH" "$SHA" "$TREE" "$PR" "$BASE" "$NOW" > "$ENVF"
fi
rm -f "$LOG"
exit 0
