#!/usr/bin/env bash
# Lore SessionEnd checkpoint. Keeps status.md from going stale without
# depending on `lore start`. Never blocks session exit: every failure
# prints one line and exits 0.
#
# - Linked worktree session: append ONE checkpoint line for the branch,
#   never rebuild (only the main checkout rebuilds).
# - Main checkout session: apply Lore's staleness rule (a checkpoint newer
#   than Last updated, or Last updated older than 7 days). Stale -> headless
#   `claude -p` reconstruct of status.md from git evidence. Fresh -> no write.
#
# Claude Code gives SessionEnd hooks a shared 1.5 s budget, so the foreground
# part only does file edits and git reads; the model rebuild is spawned
# detached (re-running this script with --rebuild) and logs to
# <vault>/projects/<name>/.lore-checkpoint.log. A mkdir lock allows one rebuild
# per project.
#
# Entry point for other writers (Cody, Ralph): `lore-checkpoint.sh --note "<line>"`
# inserts a line inside `## Last checkpoint` (3-line cap). Never `>>` status.md:
# the last section is `## Context refs`, so appended lines land outside it.
#
# Model: SQUAD_LORE_MODEL (default haiku). Commits the vault if it is a git repo.
#
# Install (Claude Code): copy to ~/.claude/hooks/lore-checkpoint.sh, chmod +x,
# and add to ~/.claude/settings.json:
#   { "hooks": { "SessionEnd": [ { "hooks": [
#     { "type": "command", "command": "~/.claude/hooks/lore-checkpoint.sh" } ] } ] } }
# Optional: add "timeout": <seconds> to the hook entry to raise the 1.5 s budget.

# Recursion guard: the headless `claude -p` below is itself a session and may
# fire SessionEnd; it runs with SQUAD_LORE_HOOK=1 so that nested run exits here.
[ -n "${SQUAD_LORE_HOOK:-}" ] && exit 0

bail() { echo "lore-checkpoint: $1"; exit 0; }

MODE=hook; NOTE=""
case "${1:-}" in
  --note) MODE=note; NOTE="${2:-}"; [ -n "$NOTE" ] || bail "--note needs a line, skipped" ;;
  --rebuild) MODE=rebuild ;;
esac
SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Hook input: JSON on stdin; `cwd` is the session's working directory.
INPUT=""
[ "$MODE" = hook ] && INPUT="$(cat 2>/dev/null)"
CWD=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
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
[ -f "$STATUS" ] || bail "no status.md for $DISPLAY, skipped"

TOP="$(git rev-parse --show-toplevel 2>/dev/null)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
SHA="$(git rev-parse --short HEAD 2>/dev/null)"
NOW="$(date "+%Y-%m-%d %H:%M")"

commit_vault() {
  if [ -d "$VAULT/.git" ] || git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$VAULT" add "projects/$DISPLAY/status.md" >/dev/null 2>&1
    git -C "$VAULT" commit -q -m "lore: $1 $DISPLAY" >/dev/null 2>&1 || true
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
TMPC="$(mktemp)"; TMPB="$(mktemp)"
LOCK="$VAULT/projects/$DISPLAY/.lore-rebuild.lock"
trap 'rm -f "$TMPC" "$TMPB"; [ "${HOLD_LOCK:-}" = 1 ] && rmdir "$LOCK" 2>/dev/null' EXIT

# add_checkpoint <line>: insert inside ## Last checkpoint, keep the last 3.
# Also moves stray dated "[...]" lines found under ## Context refs (appended
# there by plain `>>` writers) into the section.
add_checkpoint() {
  local strays out="$STATUS.tmp.$$"
  strays="$(section "$STATUS" "Context refs" | grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}')"
  if ! grep -q '^## Last checkpoint' "$STATUS"; then
    printf '\n## Last checkpoint\n' >> "$STATUS" || return 1
  fi
  { section "$STATUS" "Last checkpoint" | grep '^\['; [ -n "$strays" ] && printf '%s\n' "$strays"
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
  LINE="[$NOW] [claude-code] Session ended on worktree branch $BRANCH @ $SHA."
  # Idempotent: same branch at same commit already recorded -> nothing new.
  if grep -qF "worktree branch $BRANCH @ $SHA." "$STATUS" 2>/dev/null; then exit 0; fi
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
fi
if [ "$MODE" = hook ]; then
  # Repair strays on every main-checkout exit (cheap awk, no model).
  if section "$STATUS" "Context refs" | grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
    add_checkpoint "" && commit_vault "repair checkpoint"
  fi
  [ "$STALE" = "1" ] || exit 0
  command -v claude >/dev/null 2>&1 || bail "claude CLI not found, skipped"
  # No commits since Last updated -> a model call would add nothing.
  if [ -n "$UPDATED" ] && [ -z "$(git log --oneline --since="$UPDATED" -1 2>/dev/null)" ]; then exit 0; fi
  # Fresh lock held -> a rebuild is already running (stale after 10 min).
  if [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then exit 0; fi
  # Detach fully: own session when possible, all stdio redirected, so Claude
  # Code is not kept waiting on an open pipe.
  LOG="$VAULT/projects/$DISPLAY/.lore-checkpoint.log"
  DETACH=""
  command -v setsid >/dev/null 2>&1 && DETACH="setsid"
  [ -z "$DETACH" ] && command -v perl >/dev/null 2>&1 && DETACH="perl -MPOSIX -e POSIX::setsid();exec(@ARGV) --"
  ( cd "$CWD" && $DETACH nohup bash "$SELF" --rebuild >"$LOG" 2>&1 </dev/null & ) >/dev/null 2>&1
  exit 0
fi

# --- Rebuild mode (detached) ----------------------------------------------
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; fi
mkdir "$LOCK" 2>/dev/null || bail "rebuild already running, skipped"
HOLD_LOCK=1
[ "$STALE" = "1" ] || exit 0
command -v claude >/dev/null 2>&1 || bail "claude CLI not found, skipped"

SINCE="${UPDATED:-7 days ago}"
EVIDENCE="Branch: $BRANCH
Now: $NOW
Git log since '$SINCE':
$(git log --oneline --since="$SINCE" -20 2>/dev/null)
Recent commits:
$(git log --oneline -10 2>/dev/null)

Existing status.md:
$(cat "$STATUS")"

PROMPT="Rebuild status.md from the evidence on stdin. Output ONLY the full file, no code fences, no commentary. Keep the exact schema: YAML front matter (title, tags [status, active], project), '# Status — <project>', 'Last updated: $NOW by claude-code', then sections Goal, Done (under 5 lines, distilled), Next (ACTION: / CONTEXT:), Blocked, Last checkpoint, Context refs. Goal, Done and Next together under 400 tokens. Mark inferences as inferred. Copy Blocked and Context refs from the existing file."

# Hard 90 s cap; macOS has no `timeout`, so fall back to a perl alarm.
TMO=""
if command -v timeout >/dev/null 2>&1; then TMO="timeout 90"
elif command -v perl >/dev/null 2>&1; then TMO="perl -e alarm(90);exec(@ARGV) --"; fi
NEW="$(printf '%s' "$EVIDENCE" | SQUAD_LORE_HOOK=1 $TMO claude -p "$PROMPT" --model "${SQUAD_LORE_MODEL:-haiku}" 2>/dev/null)" \
  || bail "headless rebuild failed, status unchanged"

# Strip stray code fences, then validate shape. Size is measured on the
# model-authored sections only (~4 chars/token: 400 tokens = 1600 bytes);
# measuring the whole file bailed on every run, since Blocked/checkpoints/refs
# are copied verbatim and alone can exceed the cap.
NEW="$(printf '%s\n' "$NEW" | sed '/^```/d')"
printf '%s\n' "$NEW" | head -n 1 | grep -q '^---$' || bail "rebuild output invalid, status unchanged"
for h in '^# Status' '^Last updated:' '^## Goal' '^## Done' '^## Next' '^## Blocked' '^## Last checkpoint'; do
  printf '%s\n' "$NEW" | grep -q "$h" || bail "rebuild output missing section, status unchanged"
done

# Deterministic enforcement: Blocked verbatim from the old file, Last
# checkpoint = last 3 existing lines, Last updated stamped here. No rebuild
# checkpoint line is added: it would read as newer than Last updated.
section "$STATUS" Blocked > "$TMPB"
# Intentional: under Last checkpoint only lines starting with "[" are kept;
# any other text in that section is dropped.
section "$STATUS" "Last checkpoint" | grep '^\[' | tail -n 3 > "$TMPC"
MODEL_BYTES="$( { for h in Goal Done Next; do printf '%s\n' "$NEW" > "$TMPB.n"; section "$TMPB.n" "$h"; done; } | wc -c | tr -d ' ')"
rm -f "$TMPB.n"
[ "$MODEL_BYTES" -gt 1600 ] && bail "rebuild over 400-token budget, status unchanged"
OUT="$STATUS.tmp.$$"
printf '%s\n' "$NEW" | sed "s/^Last updated:.*/Last updated: $NOW by claude-code/" > "$OUT.1"
replace_section "$OUT.1" Blocked "$TMPB" > "$OUT.2"
replace_section "$OUT.2" "Last checkpoint" "$TMPC" > "$OUT"
rm -f "$OUT.1" "$OUT.2"

mv "$OUT" "$STATUS" || { rm -f "$OUT"; bail "write failed"; }
commit_vault "rebuild status"
exit 0
