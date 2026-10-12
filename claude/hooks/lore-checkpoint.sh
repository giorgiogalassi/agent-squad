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
# Model: SQUAD_LORE_MODEL (default haiku). Commits the vault if it is a git repo.
#
# Install (Claude Code): copy to ~/.claude/hooks/lore-checkpoint.sh, chmod +x,
# and add to ~/.claude/settings.json:
#   { "hooks": { "SessionEnd": [ { "hooks": [
#     { "type": "command", "command": "~/.claude/hooks/lore-checkpoint.sh" } ] } ] } }

# Recursion guard: the headless `claude -p` below is itself a session and may
# fire SessionEnd; it runs with SQUAD_LORE_HOOK=1 so that nested run exits here.
[ -n "${SQUAD_LORE_HOOK:-}" ] && exit 0

bail() { echo "lore-checkpoint: $1"; exit 0; }

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Hook input: JSON on stdin; `cwd` is the session's working directory.
INPUT="$(cat 2>/dev/null)"
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
trap 'rm -f "$TMPC" "$TMPB"' EXIT

# --- Worktree session: checkpoint line only -------------------------------
if [ "$TOP" != "$ROOT" ]; then
  LINE="[$NOW] [claude-code] Session ended on worktree branch $BRANCH @ $SHA."
  # Idempotent: same branch at same commit already recorded -> nothing new.
  if grep -qF "worktree branch $BRANCH @ $SHA." "$STATUS" 2>/dev/null; then exit 0; fi
  if grep -q '^## Last checkpoint' "$STATUS"; then
    CPS="$( { section "$STATUS" "Last checkpoint" | grep '^\['; echo "$LINE"; } | tail -n 3)"
    printf '%s\n' "$CPS" > "$TMPC"
    replace_section "$STATUS" "Last checkpoint" "$TMPC" > "$STATUS.tmp.$$" \
      && mv "$STATUS.tmp.$$" "$STATUS" || { rm -f "$STATUS.tmp.$$"; bail "append failed"; }
  else
    printf '\n## Last checkpoint\n%s\n' "$LINE" >> "$STATUS" || bail "append failed"
  fi
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

PROMPT="Rebuild status.md from the evidence on stdin. Output ONLY the full file, no code fences, no commentary. Keep the exact schema: YAML front matter (title, tags [status, active], project), '# Status — <project>', 'Last updated: $NOW by claude-code', then sections Goal, Done (under 5 lines, distilled), Next (ACTION: / CONTEXT:), Blocked, Last checkpoint, Context refs. Total under 400 tokens. Mark inferences as inferred. Copy Blocked and Context refs from the existing file."

TMO=""
command -v timeout >/dev/null 2>&1 && TMO="timeout 90"
NEW="$(printf '%s' "$EVIDENCE" | SQUAD_LORE_HOOK=1 $TMO claude -p "$PROMPT" --model "${SQUAD_LORE_MODEL:-haiku}" 2>/dev/null)" \
  || bail "headless rebuild failed, status unchanged"

# Strip stray code fences, then validate shape and size (~4 chars/token: 400 tokens = 1600 bytes).
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
OUT="$STATUS.tmp.$$"
printf '%s\n' "$NEW" | sed "s/^Last updated:.*/Last updated: $NOW by claude-code/" > "$OUT.1"
replace_section "$OUT.1" Blocked "$TMPB" > "$OUT.2"
replace_section "$OUT.2" "Last checkpoint" "$TMPC" > "$OUT"
rm -f "$OUT.1" "$OUT.2"

if [ "$(wc -c < "$OUT" | tr -d ' ')" -gt 1600 ]; then
  rm -f "$OUT"; bail "rebuild over 400-token budget, status unchanged"
fi
mv "$OUT" "$STATUS" || { rm -f "$OUT"; bail "write failed"; }
commit_vault "rebuild status"
exit 0
