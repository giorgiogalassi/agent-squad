#!/usr/bin/env bash
# Lore SessionEnd checkpoint. Keeps status.md from going stale without
# depending on `lore start`. Never blocks session exit: every failure
# prints one line and exits 0.
#
# - Linked worktree session: append ONE checkpoint line for the branch,
#   never rebuild (only the main checkout rebuilds).
# - Main checkout session: apply Lore's staleness rule (a checkpoint newer
#   than Last updated, Last updated older than 7 days, or any LOCAL branch
#   with a commit after Last updated). Stale -> headless `claude -p`
#   reconstruct of status.md from git evidence. Fresh -> no write.
#   "Local branch" = refs/heads only (git log --branches): remote-tracking refs
#   and stash never count, so `git fetch` / `gh pr merge` trigger nothing.
#   Known limits: --since compares COMMITTER dates, not ref-move time, so a
#   rebase/cherry-pick that keeps old committer dates is missed; a worktree on
#   a detached HEAD has no branch ref and is invisible.
#
# Registered as an ASYNC SessionEnd hook ("async": true in hooks/hooks.json):
# Claude Code runs it in the background with no timeout, so the model rebuild
# runs inline and this script has no detach, lock or alarm layer. Async output
# is never shown, so a skipped or failed run leaves one line in
# <vault>/projects/<name>/.lore-checkpoint.log (overwritten each run).
#
# Entry point for other writers (Cody, Ralph): `lore-checkpoint.sh --note "<line>"`
# inserts a line inside `## Last checkpoint` (3-line cap). Never `>>` status.md:
# the last section is `## Context refs`, so appended lines land outside it.
# A note is ONE line starting with "[" (e.g. "[2026-10-12 15:00] [cody] msg"):
# other lines are dropped by the `^\[` filter, and a multi-line note counts
# against the 3-line cap.
#
# Denial pass: every SessionEnd also runs
# `lore-checkpoint.sh --incidents <transcript> <session_id> <project>` (before
# the status work) to scan the transcripts for permission/classifier denials
# and record them via squad-incidents.sh (source=transcript, kind=denial,
# dedupe_id=tool_use_id). It needs jq (skipped without) and never commits the vault.
#
# Decisions lint: every hook SessionEnd also runs decisions-lint.sh on
# decisions.md (inverse markers added, findings left in .decisions-lint for
# lore-orient.sh); see the block before the status work.
#
# Session log (#329): SessionEnd closes this session's open start lines through
# vault-check.sh's close_session_starts; see close_session_log below.
#
# INDEX sync (#328): on every exit past the status precondition the project's
# INDEX.md row (date, status) and the active project are updated through
# vault-check.sh's index_set_row / index_set_active; see sync_index below.
#
# Worktree session with a dirty tree: the checkpoint line is
# "uncommitted work on <branch>: N files" (no progress.txt line, never a commit).
#
# Model: SQUAD_LORE_MODEL (default haiku). Commits the vault if it is a git repo.
#
# Registered by the plugin's hooks/hooks.json (SessionEnd, async); no manual
# install step.

# Recursion guard: the headless `claude -p` below is itself a session and may
# fire SessionEnd; it runs with SQUAD_LORE_HOOK=1 so that nested run exits here.
[ -n "${SQUAD_LORE_HOOK:-}" ] && exit 0

LOG=""
bail() {
  echo "lore-checkpoint: $1"
  [ -n "$LOG" ] && printf '[%s] %s\n' "$(date "+%Y-%m-%d %H:%M")" "$1" > "$LOG" 2>/dev/null
  exit 0
}

MODE=hook; NOTE=""
case "${1:-}" in
  --note) MODE=note; NOTE="${2:-}"; [ -n "$NOTE" ] || bail "--note needs a line, skipped" ;;
  --incidents) MODE=incidents ;;
esac
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SELF="$HOOK_DIR/$(basename "${BASH_SOURCE[0]:-$0}")"

# --- Denial pass (detached) ------------------------------------------------
# Auto-mode classifier denial; user rejections ("The user doesn't want...") do not match.
DENIAL_PATTERN="Permission for this action was denied by the Claude Code auto mode classifier"
SQUAD_PATHS='claude/skills|claude/agents|claude/hooks|\.claude/hooks/squad-|\.squad/'

# scan_transcript <jsonl> <component> <all|squad>: record denials. For "squad",
# only denials whose tool input references squad paths count.
scan_transcript() {
  local file="$1" comp="$2" scope="$3" id tool reason pat=""
  [ -f "$file" ] || return 0
  [ "$scope" = squad ] && pat="$SQUAD_PATHS"
  # The squad-path filter runs inside jq and every emitted field is non-empty:
  # tab is IFS whitespace, so an empty field would collapse and shift columns.
  jq -R -s -r --arg pat "$DENIAL_PATTERN" --arg sq "$pat" '
    def txt: if (.content | type) == "array" then ([.content[]? | .text? // ""] | join(" ")) else (.content // "" | tostring) end;
    split("\n") | map(fromjson? // empty) as $l
    | ([$l[] | .message.content? | arrays | .[] | select(.type == "tool_use")
        | {key: .id, value: {name: .name, input: (.input | tojson)}}] | from_entries) as $uses
    | $l[] | .message.content? | arrays | .[]
    | select(.type == "tool_result" and .is_error == true)
    | select(txt | startswith($pat))
    | select($sq == "" or (($uses[.tool_use_id].input // "") | test($sq)))
    | [.tool_use_id, ($uses[.tool_use_id].name // "tool"),
       (txt | capture("Reason: (?<r>\\[[^\\]]*\\])").r // "(no reason given)")] | @tsv' "$file" 2>/dev/null \
  | while IFS="$(printf '\t')" read -r id tool reason; do
      [ -n "$id" ] || continue
      bash "$HOOK_DIR/squad-incidents.sh" record --session "$INC_SESSION" --project "$INC_PROJECT" \
        --source transcript --kind denial --component "$comp" \
        --reason "$tool denied $reason" --dedupe-id "$id" >/dev/null 2>&1
    done
}

if [ "$MODE" = incidents ]; then
  INC_TRANSCRIPT="${2:-}"; INC_SESSION="${3:-}"; INC_PROJECT="${4:-}"
  command -v jq >/dev/null 2>&1 || bail "jq missing, denial pass skipped"
  [ -f "$INC_TRANSCRIPT" ] || bail "no transcript, denial pass skipped"
  scan_transcript "$INC_TRANSCRIPT" main squad
  SUBDIR="$(dirname "$INC_TRANSCRIPT")/$INC_SESSION/subagents"
  if [ -n "$INC_SESSION" ] && [ -d "$SUBDIR" ]; then
    for sub in "$SUBDIR"/agent-*.jsonl; do
      [ -f "$sub" ] || continue
      kind="$(jq -r '.agentType // empty' "${sub%.jsonl}.meta.json" 2>/dev/null)"
      scan_transcript "$sub" "${kind:-subagent}" all
    done
  fi
  exit 0
fi

# Hook input: JSON on stdin; `cwd` is the session's working directory.
INPUT=""
[ "$MODE" = hook ] && INPUT="$(cat 2>/dev/null)"
CWD=""; TRANSCRIPT=""; SESSION_ID=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  { IFS= read -r CWD; IFS= read -r TRANSCRIPT; IFS= read -r SESSION_ID; } < <(printf '%s' "$INPUT" \
    | jq -r '(.cwd // ""), (.transcript_path // ""), (.session_id // "")' 2>/dev/null)
fi
[ -z "$CWD" ] && CWD="$PWD"
cd "$CWD" 2>/dev/null || bail "cannot enter $CWD, skipped"

[ -x "$HOOK_DIR/path-resolve.sh" ] || bail "path-resolve.sh missing, skipped"
while IFS='=' read -r _key _value; do
  case "$_key" in
    VAULT_PATH) VAULT="$_value" ;;
    PROJECT_ROOT) ROOT="$_value" ;;
    DISPLAY_NAME) DISPLAY="$_value" ;;
  esac
done < <("$HOOK_DIR/path-resolve.sh")

[ -d "${VAULT:-}" ] || bail "no vault, skipped"
[ -n "${ROOT:-}" ] || bail "not a git project, skipped"
[ -z "${DISPLAY:-}" ] && DISPLAY="$(basename "$ROOT")"
STATUS="$VAULT/projects/$DISPLAY/status.md"

[ "$MODE" = hook ] && LOG="$VAULT/projects/$DISPLAY/.lore-checkpoint.log"

# Denial pass: every session end (main checkout and worktrees), independent of
# the status rebuild below.
if [ "$MODE" = hook ] && [ -n "$TRANSCRIPT" ] && command -v jq >/dev/null 2>&1; then
  bash "$SELF" --incidents "$TRANSCRIPT" "$SESSION_ID" "$DISPLAY" >/dev/null 2>&1 </dev/null
fi

# Decisions lint (#327), every hook SessionEnd, before the status work so a
# missing status.md does not skip it. Adds the inverse marker for entries
# carrying Supersedes: (deterministic, never rewrites text) and leaves the
# remaining findings in <project>/.decisions-lint for the next SessionStart
# (lore-orient.sh prints them). decisions.md is committed when it differs from
# HEAD, so "new entry" means new since the last lint.
if [ "$MODE" = hook ] && [ -f "$VAULT/projects/$DISPLAY/decisions.md" ] && [ -x "$HOOK_DIR/decisions-lint.sh" ]; then
  _df="$VAULT/projects/$DISPLAY/decisions.md"
  _dl="$VAULT/projects/$DISPLAY/.decisions-lint"
  # Report first (new-only is relative to HEAD), then fix and commit.
  bash "$HOOK_DIR/decisions-lint.sh" check "$_df" --new-only 2>/dev/null \
    | grep -v '^DECISIONS_MISSING_INVERSE=' > "$_dl.tmp"
  bash "$HOOK_DIR/decisions-lint.sh" fix "$_df" >/dev/null 2>&1
  if [ -s "$_dl.tmp" ]; then mv "$_dl.tmp" "$_dl"; else rm -f "$_dl.tmp" "$_dl"; fi
  if git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1 \
     && [ -n "$(git -C "$VAULT" status --porcelain -- "projects/$DISPLAY/decisions.md" 2>/dev/null)" ]; then
    git -C "$VAULT" add "projects/$DISPLAY/decisions.md" >/dev/null 2>&1
    _id=""
    git -C "$VAULT" config user.name >/dev/null 2>&1 || _id="$_id -c user.name=lore"
    git -C "$VAULT" config user.email >/dev/null 2>&1 || _id="$_id -c user.email=lore@localhost"
    # shellcheck disable=SC2086
    git -C "$VAULT" $_id commit -q -m "lore: decisions lint $DISPLAY" -- "projects/$DISPLAY/decisions.md" >/dev/null 2>&1 || true
  fi
fi

# Session log (#329), every hook SessionEnd, before the status work: closes the
# start lines of THIS session. Ownership rule (start lines carry no session
# id): the start is dated at or after the first timestamp of this session's
# transcript and names this session's branch ("branch: <b>"). Without a
# transcript timestamp or a branch nothing is closed here (vault-check --fix
# still closes past-day orphans). Same function as `lore check --fix`
# (vault-check.sh, sourced in a subshell: it sets -u); skill-closed sessions
# are already paired, so no duplicate end is written. Only session.log is
# committed, by pathspec, and only when it changed.
close_session_log() {
  local log="$VAULT/projects/$DISPLAY/.squad/session.log" first epoch since br n _id=""
  [ -f "$log" ] && [ -f "$HOOK_DIR/vault-check.sh" ] && [ -f "$TRANSCRIPT" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  first="$(jq -r '.timestamp // empty' "$TRANSCRIPT" 2>/dev/null | head -n 1)"
  [ -n "$first" ] || return 0
  epoch="$(date -d "$first" +%s 2>/dev/null || TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${first%%.*}" +%s 2>/dev/null)"
  [ -n "$epoch" ] || return 0
  since="$(date -d "@$epoch" "+%Y-%m-%d %H:%M" 2>/dev/null || date -r "$epoch" "+%Y-%m-%d %H:%M" 2>/dev/null)"
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$since" ] && [ -n "$br" ] && [ "$br" != HEAD ] || return 0
  n="$( . "$HOOK_DIR/vault-check.sh" >/dev/null 2>&1; close_session_starts "$log" "$since" "$br" 2>/dev/null )"
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 0
  if git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$VAULT" add "projects/$DISPLAY/.squad/session.log" >/dev/null 2>&1
    git -C "$VAULT" config user.name >/dev/null 2>&1 || _id="$_id -c user.name=lore"
    git -C "$VAULT" config user.email >/dev/null 2>&1 || _id="$_id -c user.email=lore@localhost"
    # shellcheck disable=SC2086
    git -C "$VAULT" $_id commit -q -m "lore: session log $DISPLAY" -- "projects/$DISPLAY/.squad/session.log" >/dev/null 2>&1 || true
  fi
}
[ "$MODE" = hook ] && close_session_log

[ -f "$STATUS" ] || bail "no status.md for $DISPLAY, skipped"
# Past the preconditions: drop a stale log; any later bail rewrites it.
[ -n "$LOG" ] && rm -f "$LOG"

TOP="$(git rev-parse --show-toplevel 2>/dev/null)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
SHA="$(git rev-parse --short HEAD 2>/dev/null)"
NOW="$(date "+%Y-%m-%d %H:%M")"

commit_vault() {
  if [ -d "$VAULT/.git" ] || git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$VAULT" add "projects/$DISPLAY/status.md" >/dev/null 2>&1
    # No git identity (fresh CI runner, bare machine) would make the commit fail
    # silently; fall back to a fixed one only when none is configured.
    _id=""
    git -C "$VAULT" config user.name >/dev/null 2>&1 || _id="$_id -c user.name=lore"
    git -C "$VAULT" config user.email >/dev/null 2>&1 || _id="$_id -c user.email=lore@localhost"
    # shellcheck disable=SC2086
    git -C "$VAULT" $_id commit -q -m "lore: $1 $DISPLAY" -- "projects/$DISPLAY/status.md" >/dev/null 2>&1 || true
  fi
}

# section <file> <heading>: body of a section. Inner blank lines are kept;
# only the heading line and trailing blank lines are trimmed.
section() {
  awk -v h="## $2" '
    /^## / { if (on) exit; if (index($0, h) == 1) on = 1; next }
    on { if ($0 == "") { blanks++; next }
         while (blanks > 0) { print ""; blanks-- }
         print }' "$1"
}
# replace_section <file> <heading> <body-file>: swap a section's body, keep the blank line before the next heading.
replace_section() {
  awk -v h="## $2" -v bf="$3" '
    function dump(f,  l) { while ((getline l < f) > 0) print l; close(f) }
    /^## / { if (skip) print ""; skip = 0
      if (index($0, h) == 1) { print; dump(bf); skip = 1; next } }
    !skip { print }' "$1"
}
# next_items: one Next item per output line (an ACTION: line joined with the
# lines under it by a unit separator), trailing blanks stripped; each line
# before the first ACTION: is an item of its own.
next_items() {
  awk '{ sub(/[ \t]+$/, "") }
       /^ACTION:/ { if (item != "") print item; item = $0; next }
       $0 == "" { next }
       item == "" { print; next }
       { item = item "\037" $0 }
       END { if (item != "") print item }'
}
TMPC="$(mktemp)"; TMPB="$(mktemp)"

# INDEX sync (#328), on every exit past the status precondition (a rebuild, a
# checkpoint line, or nothing to write): the project's INDEX row takes
# status.md's Last updated date and status, a missing row is added, and the
# project becomes the active one. Same functions as `lore check --fix`
# (vault-check.sh, sourced in a subshell: it sets -u). Only INDEX.md is
# committed, by pathspec, so unrelated vault changes are never swept in.
sync_index() {
  local idx="$VAULT/INDEX.md" upd st r1 r2 _id=""
  [ -f "$idx" ] && [ -f "$STATUS" ] && [ -f "$HOOK_DIR/vault-check.sh" ] || return 0
  upd="$(sed -n 's/^Last updated: \([0-9-]*\).*/\1/p' "$STATUS" | head -n 1)"
  [ -n "$upd" ] || return 0
  st=active; grep -q '^tags:.*paused' "$STATUS" && st=paused
  r1="$( . "$HOOK_DIR/vault-check.sh" >/dev/null 2>&1; index_set_row "$idx" "$DISPLAY" "$st" "$upd" 1 2>/dev/null )"
  r2="$( . "$HOOK_DIR/vault-check.sh" >/dev/null 2>&1; index_set_active "$idx" "$DISPLAY" "$upd" 2>/dev/null )"
  [ -n "$r1$r2" ] || return 0
  if git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$VAULT" add INDEX.md >/dev/null 2>&1
    git -C "$VAULT" config user.name >/dev/null 2>&1 || _id="$_id -c user.name=lore"
    git -C "$VAULT" config user.email >/dev/null 2>&1 || _id="$_id -c user.email=lore@localhost"
    # shellcheck disable=SC2086
    git -C "$VAULT" $_id commit -q -m "lore: index $DISPLAY" -- INDEX.md >/dev/null 2>&1 || true
  fi
}
trap 'rm -f "$TMPC" "$TMPB"; [ "$MODE" = incidents ] || sync_index' EXIT

# add_checkpoint <line>: insert inside ## Last checkpoint, keep the last 3.
# Also moves stray dated "[...]" lines found under ## Context refs (appended
# there by plain `>>` writers) into the section.
add_checkpoint() {
  local strays out="$STATUS.tmp.$$"
  # Stray = line starting with "[YYYY-MM-DD"; wikilinks "[[...]]" never match.
  strays="$(section "$STATUS" "Context refs" | grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}')"
  if ! grep -q '^## Last checkpoint' "$STATUS"; then
    # Missing section: insert before ## Context refs (it must stay last), else append.
    if grep -q '^## Context refs' "$STATUS"; then
      awk '/^## Context refs/ && !done { print "## Last checkpoint"; done = 1 } { print }' "$STATUS" > "$out.i" \
        && mv "$out.i" "$STATUS" || { rm -f "$out.i"; return 1; }
    else
      printf '\n## Last checkpoint\n' >> "$STATUS" || return 1
    fi
  fi
  # Existing + strays sorted by the leading [timestamp] (stable), so a repaired
  # old stray cannot evict a newer real checkpoint; the new line goes last.
  { { section "$STATUS" "Last checkpoint" | grep '^\['; [ -n "$strays" ] && printf '%s\n' "$strays"; } \
      | sort -s -t']' -k1,1
    [ -n "${1:-}" ] && printf '%s\n' "$1"; } | tail -n 3 > "$TMPC"
  if [ -n "$strays" ]; then
    awk '/^## /{ctx = (index($0, "## Context refs") == 1)}
         !(ctx && /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {print}' "$STATUS" > "$out.s" \
      && replace_section "$out.s" "Last checkpoint" "$TMPC" > "$out" || { rm -f "$out" "$out.s"; return 1; }
    rm -f "$out.s"
  else
    replace_section "$STATUS" "Last checkpoint" "$TMPC" > "$out" || { rm -f "$out"; return 1; }
  fi
  mv "$out" "$STATUS"
}

if [ "$MODE" = note ]; then
  add_checkpoint "$NOTE" || bail "append failed"
  commit_vault "checkpoint"
  exit 0
fi

# --- Worktree session: checkpoint line only -------------------------------
if [ "$TOP" != "$ROOT" ]; then
  DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${DIRTY:-0}" -gt 0 ]; then
    # Work stopped before a commit: record it, never commit it.
    LINE="[$NOW] [claude-code] uncommitted work on $BRANCH: $DIRTY files"
    if grep -qF "uncommitted work on $BRANCH: $DIRTY files" "$STATUS" 2>/dev/null; then exit 0; fi
  else
    LINE="[$NOW] [claude-code] Session ended on worktree branch $BRANCH @ $SHA."
    # Idempotent: same branch at same commit already recorded -> nothing new.
    if grep -qF "worktree branch $BRANCH @ $SHA." "$STATUS" 2>/dev/null; then exit 0; fi
  fi
  add_checkpoint "$LINE" || bail "append failed"
  commit_vault "checkpoint"
  exit 0
fi

# --- Main checkout: staleness rule ----------------------------------------
UPDATED="$(sed -n 's/^Last updated: \([0-9-]* [0-9:]*\).*/\1/p' "$STATUS" | head -n 1)"
LATEST_CP="$(sed -n '/^## Last checkpoint/,/^## /p' "$STATUS" \
  | sed -n 's/^\[\([0-9-]* [0-9:]*\)\].*/\1/p' | sort | tail -n 1)"
WEEK_AGO="$(date -v-7d "+%Y-%m-%d %H:%M" 2>/dev/null || date -d "7 days ago" "+%Y-%m-%d %H:%M" 2>/dev/null)"

STALE=0
if [ -z "$UPDATED" ]; then STALE=1
elif [ -n "$LATEST_CP" ] && [[ "$LATEST_CP" > "$UPDATED" ]]; then STALE=1
elif [ -n "$WEEK_AGO" ] && [[ "$UPDATED" < "$WEEK_AGO" ]]; then STALE=1
elif [ -n "$(git log --branches --oneline --since="$UPDATED" -1 2>/dev/null)" ]; then STALE=1
fi
# Repair strays on every main-checkout exit (cheap awk, no model).
if section "$STATUS" "Context refs" | grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
  add_checkpoint "" && commit_vault "repair checkpoint"
fi
[ "$STALE" = "1" ] || exit 0
# No commits since Last updated -> a model call would add nothing.
if [ -n "$UPDATED" ] && [ -z "$(git log --branches --oneline --since="$UPDATED" -1 2>/dev/null)" ]; then exit 0; fi

# --- Rebuild (inline: the hook is async) -----------------------------------
command -v claude >/dev/null 2>&1 || bail "claude CLI not found, skipped"

SINCE="${UPDATED:-7 days ago}"
# Local branches (refs/heads) with a commit since Last updated, newest first,
# with their tips: work done on worktree branches is invisible to HEAD's log.
TOUCHED=""
for _b in $(git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads 2>/dev/null | head -n 10); do
  _t="$(git log -1 --since="$SINCE" --format='%h %s' "refs/heads/$_b" 2>/dev/null)"
  [ -n "$_t" ] && TOUCHED="$TOUCHED$_b @ $_t
"
done
EVIDENCE="Branch: $BRANCH
Now: $NOW
Git log since '$SINCE':
$(git log --oneline --since="$SINCE" -20 2>/dev/null)
Local branches touched since '$SINCE' (branch @ tip):
$TOUCHED
Recent commits:
$(git log --oneline -10 2>/dev/null)

Existing status.md:
$(cat "$STATUS")"

PROMPT="Rebuild status.md from the evidence on stdin. Output ONLY the full file, no code fences, no commentary. Keep the exact schema: YAML front matter (title, tags [status, active], project), '# Status — <project>', 'Last updated: $NOW by claude-code', then sections Goal, Done (under 5 lines, distilled), Next (ACTION: / CONTEXT:), Blocked, Last checkpoint, Context refs. Goal and Done together under 400 tokens. Mark inferences as inferred. Copy Blocked and Context refs from the existing file. Next: if the existing Next has ACTION: lines, copy each ACTION: line with the lines under it verbatim, in order; you may only delete a whole item the evidence shows is done; never add, reword or merge items. If the existing Next has no ACTION: line, write one ACTION: and one CONTEXT: line."

NEW="$(printf '%s' "$EVIDENCE" | SQUAD_LORE_HOOK=1 claude -p "$PROMPT" --model "${SQUAD_LORE_MODEL:-haiku}" 2>/dev/null)" \
  || bail "headless rebuild failed, status unchanged"

# Strip stray code fences, then validate shape. Size is measured on the
# model-authored sections only (~4 chars/token: 400 tokens = 1600 bytes);
# measuring the whole file bailed on every run, since Blocked/checkpoints/refs
# are copied verbatim and alone can exceed the cap.
NEW="$(printf '%s\n' "$NEW" | sed '/^```/d')"
printf '%s\n' "$NEW" | head -n 1 | grep -q '^---$' || bail "rebuild output invalid, status unchanged"
for h in '^# Status' '^Last updated:' '^## Goal' '^## Done' '^## Next' '^## Blocked' '^## Last checkpoint' '^## Context refs'; do
  printf '%s\n' "$NEW" | grep -q "$h" || bail "rebuild output missing section, status unchanged"
done

# Deterministic enforcement: Blocked and Context refs verbatim from the old file, Last
# checkpoint = last 3 existing lines, Last updated stamped here. No rebuild
# checkpoint line is added: it would read as newer than Last updated.
section "$STATUS" Blocked > "$TMPB"
TMPR="$TMPB.r"; section "$STATUS" "Context refs" > "$TMPR"
# Intentional: under Last checkpoint only lines starting with "[" are kept;
# any other text in that section is dropped.
section "$STATUS" "Last checkpoint" | grep '^\[' | tail -n 3 > "$TMPC"
# Next is remove-only once it holds ACTION items: every item (an ACTION: line
# plus the lines under it) must be copied verbatim from the old Next, so a
# rebuild can drop finished items but never lose, reword or invent one. Only
# an ACTION-less Next is model-authored, and then it counts toward the budget.
printf '%s\n' "$NEW" > "$TMPB.n"
BUDGETED="Goal Done"
if section "$STATUS" Next | grep -q '^ACTION:'; then
  section "$STATUS" Next | next_items > "$TMPB.o"
  section "$TMPB.n" Next | next_items | while IFS= read -r _item; do
    grep -qxF -- "$_item" "$TMPB.o" || { echo x; break; }
  done | grep -q x && { rm -f "$TMPB.n" "$TMPB.o" "$TMPR"; bail "rebuild rewrote a Next item, status unchanged"; }
  rm -f "$TMPB.o"
else
  BUDGETED="Goal Done Next"
fi
MODEL_BYTES="$(for h in $BUDGETED; do section "$TMPB.n" "$h"; done | wc -c | tr -d ' ')"
rm -f "$TMPB.n"
[ "$MODEL_BYTES" -gt 1600 ] && bail "rebuild over 400-token budget ($BUDGETED), status unchanged"
OUT="$STATUS.tmp.$$"
printf '%s\n' "$NEW" | sed "s/^Last updated:.*/Last updated: $NOW by claude-code/" > "$OUT.1"
replace_section "$OUT.1" Blocked "$TMPB" > "$OUT.2"
replace_section "$OUT.2" "Last checkpoint" "$TMPC" > "$OUT.3"
replace_section "$OUT.3" "Context refs" "$TMPR" > "$OUT"
rm -f "$OUT.1" "$OUT.2" "$OUT.3" "$TMPR"

mv "$OUT" "$STATUS" || { rm -f "$OUT"; bail "write failed"; }
commit_vault "rebuild status"
exit 0
