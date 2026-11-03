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
# The issue ID is taken from HEAD's subject ([#N], [KEY-N]; a bare [N] becomes [#N]); no ID, a shared
# integration branch, or HEAD already on another branch means Cody committed nothing: no write.
#
# STATE: pr (open PR) | committed (connected, commit but no PR) |
#        detached (detached mode, commit ready for manual push).
# Writes: one `checkpoint` event (lore event, folded later; no commit); for STATE=pr also one
# progress.txt line `[#N] YYYY-MM-DD resolved. PR: #N (base: B). Notes: <subject>`
# (the `(base: ...)` token is what Reven reads). Both idempotent per sha / PR.
# Summary for Ralph 2b: <vault>/projects/<name>/<state_dir>/cody-checkpoint.env
# (KEY=value, overwritten each run, written directly, snapshot-committed by the fold). Log: .cody-checkpoint.log in the project dir.

[ -n "${SQUAD_LORE_HOOK:-}" ] && exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=squad-common.sh
. "$HOOK_DIR/squad-common.sh"

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
STATE_NAME="$(squad_state_name "$VAULT")"
LOG="$PROJ/.cody-checkpoint.log"
# The summary is working state: a PR-mode vault holds it in the session worktree
# (squad_vault_wroot), never in the vault checkout; Ralph reads it with
# `squad-progress.sh where --file env`. Refused (rc 10): direct-mode vault off its default branch.
ENVF="$PROJ/$STATE_NAME/cody-checkpoint.env"
if [ -d "$PROJ" ]; then
  _wr="$(squad_vault_wroot "$VAULT" "$DISPLAY" 2>/dev/null)"; _wrc=$?
  if [ "$_wrc" = 0 ] && [ -n "$_wr" ]; then ENVF="$_wr/projects/$DISPLAY/$STATE_NAME/cody-checkpoint.env"
  else ENVF=/dev/null; fi
fi
skip() { [ "$ENVF" = /dev/null ] || rm -f "$ENVF"; printf '[%s] %s\n' "$(date "+%Y-%m-%d %H:%M")" "$1" > "$LOG" 2>/dev/null; exit 0; }
[ -d "$PROJ" ] || exit 0

BRANCH="$(git branch --show-current 2>/dev/null)"
SHA="$(git rev-parse --short HEAD 2>/dev/null)"
SUBJECT="$(git log -1 --format=%s 2>/dev/null)"
[ -n "$BRANCH" ] && [ -n "$SHA" ] || skip "no branch or commit in $CWD"
case "$BRANCH" in main|master|develop|release/*|hotfix/*) skip "shared branch $BRANCH, nothing to record" ;; esac
ISSUE="$(printf '%s' "$SUBJECT" | sed -n -e 's/^\[\(#\{0,1\}[0-9][0-9]*\)\].*/\1/p' -e 's/^\[\([A-Za-z][A-Za-z0-9]*-[0-9][0-9]*\)\].*/\1/p')"
[ -n "$ISSUE" ] || skip "HEAD $SHA carries no issue ID, nothing to record"
# GitHub issues are always [#N]: a bare numeric [283] is normalised so progress.txt has one form.
ISSUE_BARE="$ISSUE"
case "$ISSUE" in [0-9]*) ISSUE="#$ISSUE" ;; "#"*) ISSUE_BARE="${ISSUE#\#}" ;; esac
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
TREE=clean; [ "${DIRTY:-0}" -gt 0 ] && TREE=dirty

# HEAD-moved check (no PR needed, so it runs before the `gh` call): Cody committed
# nothing when HEAD is already reachable from another branch (the stacked base,
# main, ...). This branch itself is excluded, with its own remote-tracking copies
# on any remote (refs/remotes/*/<branch>) and fetched pull refs (refs/remotes/*/pr/*).
# No branch-name vs subject-ID check: Ralph's detached chain branches carry several
# issues' commits under the lead issue's name.
_others="$(git for-each-ref --format='%(refname)' --contains HEAD refs/heads refs/remotes 2>/dev/null \
  | awk -v b="$BRANCH" '
      $0 == "refs/heads/" b { next }
      /^refs\/remotes\/[^\/]*\/pr\// { next }
      { rest = $0; if (sub(/^refs\/remotes\/[^\/]*\//, "", rest) && rest == b) next; print; exit }')"
[ -z "$_others" ] || skip "HEAD $SHA is already on ${_others#refs/}, nothing to record"

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

NOW="$(date "+%Y-%m-%d %H:%M")"
# A later commit on a branch whose PR is already recorded (fix round) is an update, not a new PR.
VERB_PR=opened
if [ "$STATE" = pr ] && [ -f "$PROJ/status.md" ] && grep -qF "PR #$PR opened. Branch: $BRANCH @" "$PROJ/status.md"; then VERB_PR=updated; fi
case "$STATE" in
  pr) LINE="[$NOW] [claude-code] PR #$PR $VERB_PR. Branch: $BRANCH @ $SHA. $SUBJECT" ;;
  detached) LINE="[$NOW] [claude-code] Branch $BRANCH ready for manual push @ $SHA. $SUBJECT" ;;
  *) LINE="[$NOW] [claude-code] Branch $BRANCH committed @ $SHA, no PR yet. $SUBJECT" ;;
esac

# Durable history is an event (folded into status.md later); nothing is committed here.
# A pending event for the same branch @ sha is not repeated either.
STATUS="$PROJ/status.md"
_evline="${LINE#\[$NOW\] \[claude-code\] }"
if ! grep -qF "$BRANCH @ $SHA" "$STATUS" 2>/dev/null \
   && ! grep -qF "$BRANCH @ $SHA" "$PROJ/$STATE_NAME/inbox"/*.ev 2>/dev/null; then
  SECOND_BRAIN_PATH="$VAULT" LORE_LOCK_WAIT=5 bash "$HOOK_DIR/lore" event --vault "$VAULT" --project "$DISPLAY" \
    --source claude-code --kind checkpoint --line "$_evline" >/dev/null 2>&1
fi

# Working state: the progress.txt line is written directly through squad-progress.sh
# (current copy, idempotent per issue and PR, off-default-branch rules); the fold commits it.
if [ "$STATE" = pr ] && [ -d "$PROJ/$STATE_NAME" ]; then
  bash "$HOOK_DIR/squad-progress.sh" append --issue "$ISSUE" \
    --line "$(date +%Y-%m-%d) resolved. PR: #$PR (base: $BASE). Notes: $SUBJECT" >/dev/null 2>&1 \
    || echo "cody-checkpoint: progress line not written" >&2
fi

if [ -d "$PROJ/$STATE_NAME" ] && [ "$ENVF" != /dev/null ]; then
  mkdir -p "$(dirname "$ENVF")"
  printf 'STATE=%s\nISSUE=%s\nBRANCH=%s\nSHA=%s\nTREE=%s\nPR=%s\nBASE=%s\nAT=%s\n' \
    "$STATE" "$ISSUE" "$BRANCH" "$SHA" "$TREE" "$PR" "$BASE" "$NOW" > "$ENVF"
fi
rm -f "$LOG"
exit 0
