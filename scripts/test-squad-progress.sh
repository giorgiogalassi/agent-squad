#!/usr/bin/env bash
# Tests claude/hooks/squad-progress.sh (#370): Ralph's idempotent progress.txt,
# session.log and ralph-run.md writes, direct and PR-mode vaults.
# Plain bash 3.2; fixture vaults with a bare origin; never touches ~/second-brain.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-progress.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

export SQUAD_INCIDENTS=off GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{squad-progress.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
cat > "$TMPROOT/hooks/path-resolve.sh" <<'EOP'
#!/usr/bin/env bash
echo "VAULT_PATH=$SECOND_BRAIN_PATH"; echo "PROJECT_ROOT=$PWD"
echo "DISPLAY_NAME=proj"; echo "SQUAD_DIR=$SECOND_BRAIN_PATH/projects/proj/.squad"
echo "TRACKER_MODE=connected"
EOP

mkvault() {  # mkvault <name> [config-json]
  git init -q --bare -b main "$TMPROOT/$1-origin.git"
  git init -q -b main "$TMPROOT/$1"
  mkdir -p "$TMPROOT/$1/projects/proj/.squad"
  printf '[#1] resolved. PR: #2 (base: main). Notes: x\n' > "$TMPROOT/$1/projects/proj/.squad/progress.txt"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$TMPROOT/$1/lore-config.json"
  git -C "$TMPROOT/$1" add -A && git -C "$TMPROOT/$1" commit -qm init
  git -C "$TMPROOT/$1" remote add origin "$TMPROOT/$1-origin.git"
  git -C "$TMPROOT/$1" push -q -u origin main 2>/dev/null
}
sp() {  # sp <vault> <args...>
  local v="$1"; shift
  (cd "$TMPROOT" && SECOND_BRAIN_PATH="$v" bash "$TMPROOT/hooks/squad-progress.sh" "$@" >"$TMPROOT/out" 2>"$TMPROOT/err")
  RC=$?; OUT="$(cat "$TMPROOT/out")"
  if [ -n "$OUT" ] && printf '%s\n' "$OUT" | grep -Eqv '^[A-Z_]+='; then bad "stdout has non-KEY=value line"; fi
}
cnt() { grep -cE "$2" "$1" 2>/dev/null; }
# The hook's own dedupe test (cody-checkpoint.sh), for the Ralph-then-hook order.
hook_would_skip() { grep -F "[$2] " "$1" 2>/dev/null | grep -qE "PR: #$3( |$)"; }
hook_append() { hook_would_skip "$1" "$2" "$3" || printf '[%s] resolved. PR: #%s (base: main). Notes: s\n' "$2" "$3" >> "$1"; }

RUN='Batch: [#5, #6]
Started: 2026-10-28 10:00
Status: running

| Issue | Branch | Base | Attempts | Rounds | Reviewed | Verdict | State |
|-------|--------|------|----------|--------|----------|---------|-------|
| #5 | 5-a | main | 0 | 0 | - | - | pending |
| #6 | 6-b | 5-a | 0 | 0 | - | - | pending |'
printf '%s\n' "$RUN" > "$TMPROOT/run.md"

# 1. Direct vault: append, dedupe in both orders, formats.
mkvault d; V="$TMPROOT/d"; P="$V/projects/proj/.squad/progress.txt"
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: n'
check "direct: append applied" "OUTCOME=applied CHANGED=yes" "$(printf '%s' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
check "direct: committed on main" "" "$(git -C "$V" status --porcelain)"
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: n'
check "direct: exact repeat unchanged" "unchanged" "$(printf '%s\n' "$OUT" | sed -n 's/^OUTCOME=//p')"
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: other text'
check "direct: same PR, other notes: still one line" 1 "$(cnt "$P" '^\[#5\] .*PR: #9')"
printf '[#7] 2026-10-27 resolved. PR: #11 (base: main). Notes: dated\n[8] resolved. PR: #12 (base: main). Notes: bare\n[#13] 2026-10-27 09:15 resolved. PR: #14. Notes: x\n' >> "$P"
sp "$V" append --issue '#7' --line 'resolved. PR: #11 (base: main). Notes: n'
sp "$V" append --issue '8' --line 'resolved. PR: #12 (base: main). Notes: n'
sp "$V" append --issue '#8' --line 'resolved. PR: #12 (base: main). Notes: n'
sp "$V" append --issue '#13' --line 'resolved. PR: #14 (base: main). Notes: n'
check "direct: dated/bare/timestamped lines dedupe" 3 "$(cnt "$P" '^\[#?(7|8|13)\] ')"
sp "$V" append --issue '#5' --line 'resolved. PR: #10 (base: main). Notes: new PR'
check "direct: different PR number appends" 1 "$(cnt "$P" 'PR: #10')"
sp "$V" append --issue '#50' --line 'resolved. PR: #9 (base: main). Notes: n'
check "direct: issue id is not a prefix match" 1 "$(cnt "$P" '^\[#50\]')"
# Ralph then hook, hook then Ralph.
sp "$V" append --issue '#20' --line 'resolved. PR: #21 (base: main). Notes: n'
hook_append "$P" '#20' 21
check "ralph then hook: one line" 1 "$(cnt "$P" '^\[#20\] .*PR: #21')"
hook_append "$P" '#22' 23
sp "$V" append --issue '#22' --line 'resolved. PR: #23 (base: main). Notes: n'
check "hook then ralph: one line" 1 "$(cnt "$P" '^\[#22\] .*PR: #23')"
printf '[#24] 2026-10-28 resolved. PR: #25 (base: main). Notes: new format' >> "$P"
sp "$V" append --issue '#24' --line 'resolved. PR: #25 (base: main). Notes: n'
check "new dated format without final newline dedupes" 1 "$(cnt "$P" '^\[#24\]')"
sp "$V" append --issue '#26' --line 'no-op note'
check "file without final newline: new line on its own line" 1 "$(cnt "$P" '^\[#26\] no-op note$')"
# log
sp "$V" log --line 'start -- batch: [#5], branch: b'
check "direct: log line format" 1 "$(cnt "$V/projects/proj/.squad/session.log" '^\[[0-9-]{10} [0-9:]{5}\] \[ralph\] start -- batch')"
# run state
sp "$V" run-write --from "$TMPROOT/run.md"; check "direct: run-write applied" 0 "$RC"
sp "$V" run-write --from "$TMPROOT/run.md"; check "direct: run-write repeat unchanged" unchanged "$(printf '%s\n' "$OUT" | sed -n 's/^OUTCOME=//p')"
sp "$V" run-row --issue '#5' --set Attempts=1 --set State=running
R="$V/projects/proj/.squad/ralph-run.md"
check "direct: run-row updates only the row" "| #5 | 5-a | main | 1 | 0 | - | - | running |" "$(grep '^| #5 ' "$R")"
check "direct: other row untouched" "| #6 | 6-b | 5-a | 0 | 0 | - | - | pending |" "$(grep '^| #6 ' "$R")"
sp "$V" run-row --issue '#9' --set State=x; check "run-row unknown issue: exit 10" 10 "$RC"
sp "$V" run-row --issue '#5' --set Nope=x; check "run-row unknown column: exit 10" 10 "$RC"
sp "$V" run-status --value complete; check "direct: run-status" 1 "$(cnt "$R" '^Status: complete$')"
check "direct: all committed on main" "" "$(git -C "$V" status --porcelain)"
sp "$V" append --issue; check "usage error: exit 2" 2 "$RC"
sp "$V" where --file run; check "direct: where is the vault file" "FILE=$R" "$(printf '%s\n' "$OUT" | sed -n 1p)"

# 2. PR-mode vault: everything lands on the lore branch, reads follow it.
mkvault p '{"vault_main": "pr"}'; V="$TMPROOT/p"; P="$V/projects/proj/.squad/progress.txt"
B="lore/proj-$(date +%Y-%m-%d)"
sp "$V" run-write --from "$TMPROOT/run.md"
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: n'
sp "$V" log --line 'start -- batch: [#5], branch: b'
check "pr: main clean" "" "$(git -C "$V" status --porcelain)"
check "pr: main level with origin" "$(git -C "$V" rev-parse origin/main)" "$(git -C "$V" rev-parse main)"
check "pr: progress line on lore branch" 1 "$(git -C "$V" show "$B:projects/proj/.squad/progress.txt" | grep -c '^\[#5\] resolved')"
check "pr: session.log on lore branch" 1 "$(git -C "$V" show "$B:projects/proj/.squad/session.log" | grep -c '\[ralph\] start')"
check "pr: ralph-run.md on lore branch" 1 "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep -c '^Status: running')"
check "pr: ralph-run.md not on main" "no" "$([ -f "$V/projects/proj/.squad/ralph-run.md" ] && echo yes || echo no)"
sp "$V" run-row --issue '#5' --set Attempts=2 --set State=resolved
check "pr: row update from the branch copy" "| #5 | 5-a | main | 2 | 0 | - | - | resolved |" "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep '^| #5 ')"
check "pr: other row survives" 1 "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep -c '^| #6 ')"
sp "$V" where --file run
F="$(printf '%s\n' "$OUT" | sed -n 's/^FILE=//p')"
check "pr: resumed read gets current run state" 1 "$(cnt "$F" '\| #5 .*resolved')"
check "pr: where points into the lore worktree" 1 "$(printf '%s\n' "$F" | grep -c '/\.claude/worktrees/lore-proj-')"
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: n'
check "pr: repeat is unchanged (reads the branch copy)" unchanged "$(printf '%s\n' "$OUT" | sed -n 's/^OUTCOME=//p')"
sp "$V" run-status --value complete
check "pr: run-status on branch" 1 "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep -c '^Status: complete')"
check "pr: still level and clean" "" "$(git -C "$V" status --porcelain)"
# Hook-written duplicate in PR mode: the hook appends to main's stale copy; Ralph's own line stays single.
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: again'
check "pr: no second line after repeat" 1 "$(git -C "$V" show "$B:projects/proj/.squad/progress.txt" | grep -c '^\[#5\] .*PR: #9')"

# Values are data: backslashes stay literal, newlines are refused (exit 2).
sp "$V" run-row --issue '#6' --set 'State=a\nb\\c'
check "run-row: backslashes stay literal" '| #6 | 6-b | 5-a | 0 | 0 | - | - | a\nb\\c |' "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep '^| #6 ')"
sp "$V" run-row --issue '#6' --set "State=x
y"
check "run-row: newline value is exit 2" 2 "$RC"
check "run-row: rows stay one line each" 1 "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep -c '^| #6 ')"
sp "$V" append --issue '#30' --line 'a\nb\\c'
check "append: backslashes stay literal" 1 "$(git -C "$V" show "$B:projects/proj/.squad/progress.txt" | grep -cF '[#30] a\nb\\c')"
sp "$V" log --line 'x\ty\\z'
check "log: backslashes stay literal" 1 "$(git -C "$V" show "$B:projects/proj/.squad/session.log" | grep -cF 'x\ty\\z')"

# Race: an async writer left an uncommitted line on vault main; both lines must reach the lore branch.
printf '[#40] hook line\n' >> "$P"
sp "$V" append --issue '#41' --line 'ralph line'
LP="$(git -C "$V" show "$B:projects/proj/.squad/progress.txt")"
check "race: hook line kept" 1 "$(printf '%s\n' "$LP" | grep -c '^\[#40\] hook line$')"
check "race: ralph line kept" 1 "$(printf '%s\n' "$LP" | grep -c '^\[#41\] ralph line$')"
check "race: earlier lines not duplicated" 1 "$(printf '%s\n' "$LP" | grep -c '^\[#5\] resolved')"

# merge-file failure must leave the vault copy intact and fail with exit 20 (no truncation).
mkdir -p "$TMPROOT/fakegit"
REALGIT="$(command -v git)"
cat > "$TMPROOT/fakegit/git" <<EOG
#!/bin/sh
for a in "\$@"; do [ "\$a" = merge-file ] && exit 255; done
exec "$REALGIT" "\$@"
EOG
chmod +x "$TMPROOT/fakegit/git"
printf '[#50] hook line 2\n' >> "$P"
BEFORE="$(cat "$P")"
(cd "$TMPROOT" && PATH="$TMPROOT/fakegit:$PATH" SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/squad-progress.sh" append --issue '#51' --line 'x' >"$TMPROOT/out" 2>"$TMPROOT/err"); RC=$?
check "merge failure: exit 20" 20 "$RC"
check "merge failure: vault copy intact" "$BEFORE" "$(cat "$P")"
check "merge failure: reason on stderr" 1 "$(grep -c 'merge' "$TMPROOT/err")"
check "merge failure: no temp files left" "" "$(ls "$(dirname "$P")" | grep -E '\.(m|base\.[0-9]+)$')"
git -C "$V" checkout -q -- "projects/proj/.squad/progress.txt" 2>/dev/null

# A dirty ralph-run.md on main must not duplicate rows: the lore copy wins, with a notice.
R="$V/projects/proj/.squad/ralph-run.md"
git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" > "$R"
git -C "$V" add "$R" && git -C "$V" commit -qm "seed run" # main tracks an older ralph-run.md
printf '%s\n' "$(cat "$R")" | sed -e 's/^Status:.*/Status: dirty/' -e 's/^\(| #6 .*| \)[^|]*|$/\1dirty |/' > "$R.x" && mv "$R.x" "$R"
sp "$V" run-row --issue '#6' --set 'State=merged'
check "run dirty: one row per issue" 1 "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep -c '^| #6 ')"
check "run dirty: row updated" 1 "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep -c '^| #6 .*merged')"
check "run dirty: notice on stderr" 1 "$(grep -c 'ralph-run.md' "$TMPROOT/err")"

echo "---"; echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]
