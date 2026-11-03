#!/usr/bin/env bash
# Tests claude/hooks/squad-progress.sh (#370): Ralph's idempotent progress.txt,
# session.log and ralph-run.md writes, direct and PR-mode vaults. Working state is
# written directly and never committed by the writer (#424): the fold snapshots it;
# session.log lines are events.
# Plain bash 3.2; fixture vaults with a bare origin; never touches ~/second-brain.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-progress
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

export SQUAD_INCIDENTS=off GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{squad-progress.sh,squad-incidents.sh,squad-common.sh,lore} "$TMPROOT/hooks/"
cat > "$TMPROOT/hooks/path-resolve.sh" <<'EOP'
#!/usr/bin/env bash
[ "${1:-}" = "--state-name" ] && { echo .squad; exit 0; }
echo "VAULT_PATH=$SECOND_BRAIN_PATH"; echo "PROJECT_ROOT=$PWD"
echo "DISPLAY_NAME=proj"; echo "SQUAD_DIR=$SECOND_BRAIN_PATH/projects/proj/.squad"
echo "TRACKER_MODE=connected"; echo "STATE_DIR=$SECOND_BRAIN_PATH/projects/proj/.squad"
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
fold() {  # fold <vault>: the fold SessionStart/SessionEnd would run
  SECOND_BRAIN_PATH="$1" bash "$TMPROOT/hooks/lore" fold --vault "$1" >/dev/null 2>&1
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
check "direct: written, not committed" "1 init" "$(git -C "$V" status --porcelain | wc -l | tr -d ' ') $(git -C "$V" log --format=%s | tr '\n' ' ' | sed 's/ $//')"
check "direct: tail readable at once" 1 "$(tail -n 1 "$P" | grep -c '^\[#5\] resolved')"
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
sp "$V" log --line 'start'; check "log without --source: exit 2" 2 "$RC"
sp "$V" log --source forge --line 'start -- batch: [#5], branch: b'
check "log: applied" "OUTCOME=applied CHANGED=yes" "$(printf '%s' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
[ -f "$V/projects/proj/.squad/session.log" ] && bad "log: nothing in session.log before the fold" || ok "log: nothing in session.log before the fold"
check "log: one event in the inbox" 1 "$(ls "$V"/projects/proj/.squad/inbox/*.ev | wc -l | tr -d ' ')"
fold "$V"
check "direct: log line carries the caller's source" 1 "$(cnt "$V/projects/proj/.squad/session.log" '^\[[0-9-]{10} [0-9:]{8}\] \[forge\] start -- batch')"
# the ID prefix is never doubled, whether or not the caller passes it
sp "$V" append --issue '#60' --line '[#60] with prefix'
sp "$V" append --issue '#61' --line 'no prefix'
check "append: passed prefix not doubled" 1 "$(cnt "$P" '^\[#60\] with prefix$')"
check "append: no prefix added once" 1 "$(cnt "$P" '^\[#61\] no prefix$')"
sp "$V" append --issue '#60' --line '[#60] with prefix'
check "append: prefixed repeat unchanged" unchanged "$(printf '%s\n' "$OUT" | sed -n 's/^OUTCOME=//p')"
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
check "direct: resume reads the counters before any fold" 1 "$(cnt "$R" '^\| #5 .*\| 1 \| 0 \|')"
fold "$V"
check "direct: fold snapshot-commits the working state" "" "$(git -C "$V" status --porcelain)"
sp "$V" append --issue; check "usage error: exit 2" 2 "$RC"
sp "$V" where --file run; check "direct: where is the vault file" "FILE=$R" "$(printf '%s\n' "$OUT" | sed -n 1p)"

# 2. PR-mode vault: working state is readable at once; the fold lands it on the lore branch.
mkvault p '{"vault_main": "pr"}'; V="$TMPROOT/p"; P="$V/projects/proj/.squad/progress.txt"
B="lore/proj-$(date +%Y-%m-%d)"
HEAD0="$(git -C "$V" rev-parse HEAD)"
sp "$V" run-write --from "$TMPROOT/run.md"
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: n'
sp "$V" run-row --issue '#5' --set Attempts=2 --set State=resolved
sp "$V" run-row --issue '#6' --set Attempts=1
sp "$V" log --source ralph --line 'start -- batch: [#5], branch: b'
check "pr: no commit by the writers" "$HEAD0" "$(git -C "$V" rev-parse HEAD)"
sp "$V" where --file run
F="$(printf '%s\n' "$OUT" | sed -n 's/^FILE=//p')"
check "pr: resume reads Attempts=2 before any fold" 1 "$(cnt "$F" '^\| #5 .*\| 2 \| 0 \|.*resolved')"
check "pr: second row update did not lose the first" 1 "$(cnt "$F" '^\| #6 .*\| 1 \| 0 \|')"
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: again'
check "pr: repeat is unchanged" unchanged "$(printf '%s\n' "$OUT" | sed -n 's/^OUTCOME=//p')"
fold "$V"
check "pr: main level with origin after the fold" "$(git -C "$V" rev-parse origin/main)" "$(git -C "$V" rev-parse main)"
check "pr: main clean after the fold" "" "$(git -C "$V" status --porcelain)"
check "pr: progress line on lore branch" 1 "$(git -C "$V" show "$B:projects/proj/.squad/progress.txt" | grep -c '^\[#5\] resolved')"
check "pr: session.log on lore branch" 1 "$(git -C "$V" show "$B:projects/proj/.squad/session.log" | grep -c '\[ralph\] start')"
check "pr: row update on the branch" "| #5 | 5-a | main | 2 | 0 | - | - | resolved |" "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep '^| #5 ')"
check "pr: ralph-run.md not on main" "no" "$([ -f "$V/projects/proj/.squad/ralph-run.md" ] && echo yes || echo no)"
sp "$V" where --file run
F="$(printf '%s\n' "$OUT" | sed -n 's/^FILE=//p')"
check "pr: after the fold where points into the lore worktree" 1 "$(printf '%s\n' "$F" | grep -c '/\.claude/worktrees/lore-proj-')"
check "pr: resume still reads the counters" 1 "$(cnt "$F" '^\| #5 .*\| 2 \| 0 \|')"
sp "$V" append --issue '#5' --line 'resolved. PR: #9 (base: main). Notes: n'
check "pr: repeat after the fold is unchanged (reads the branch copy)" unchanged "$(printf '%s\n' "$OUT" | sed -n 's/^OUTCOME=//p')"
sp "$V" run-status --value complete
sp "$V" run-row --issue '#6' --set Attempts=3
sp "$V" run-row --issue '#5' --set Attempts=4
sp "$V" where --file run; F="$(printf '%s\n' "$OUT" | sed -n 's/^FILE=//p')"
check "pr: edits after a fold build on the branch copy" 1 "$(cnt "$F" '^\| #6 .*\| 3 \| 0 \|')"
check "pr: status and rows together" 1 "$(cnt "$F" '^Status: complete$')"
fold "$V"
check "pr: second fold lands them" 1 "$(git -C "$V" show "$B:projects/proj/.squad/ralph-run.md" | grep -c '^| #5 .*| 4 |')"
check "pr: still level and clean" "" "$(git -C "$V" status --porcelain)"

# Values are data: backslashes stay literal, newlines are refused (exit 2).
sp "$V" run-row --issue '#6' --set 'State=a\nb\\c'
sp "$V" where --file run; F="$(printf '%s\n' "$OUT" | sed -n 's/^FILE=//p')"
check "run-row: backslashes stay literal" '| #6 | 6-b | 5-a | 3 | 0 | - | - | a\nb\\c |' "$(grep '^| #6 ' "$F")"
sp "$V" run-row --issue '#6' --set "State=x
y"
check "run-row: newline value is exit 2" 2 "$RC"
check "run-row: rows stay one line each" 1 "$(grep -c '^| #6 ' "$F")"
sp "$V" append --issue '#30' --line 'a\nb\\c'
sp "$V" where --file progress; F="$(printf '%s\n' "$OUT" | sed -n 's/^FILE=//p')"
check "append: backslashes stay literal" 1 "$(grep -cF '[#30] a\nb\\c' "$F")"
sp "$V" log --source forge --line 'x\ty\\z'
fold "$V"
check "log: backslashes stay literal" 1 "$(git -C "$V" show "$B:projects/proj/.squad/session.log" | grep -cF 'x\ty\\z')"

# Two writers: a line written on main (hook) before Ralph's append: both survive the fold.
printf '[#40] hook line\n' >> "$P"
sp "$V" append --issue '#41' --line 'ralph line'
fold "$V"
LP="$(git -C "$V" show "$B:projects/proj/.squad/progress.txt")"
check "race: hook line kept" 1 "$(printf '%s\n' "$LP" | grep -c '^\[#40\] hook line$')"
check "race: ralph line kept" 1 "$(printf '%s\n' "$LP" | grep -c '^\[#41\] ralph line$')"
check "race: earlier lines not duplicated" 1 "$(printf '%s\n' "$LP" | grep -c '^\[#5\] resolved')"

# 10. Vault checkout off its default branch (#422): another session's branch.
mkdir -p "$TMPROOT/bin"; printf '#!/bin/sh\nexit 0\n' > "$TMPROOT/bin/gh"; chmod +x "$TMPROOT/bin/gh"
PRCFG='{"vault_main": "pr"}'
D="$(date +%Y-%m-%d)"
mkvault o "$PRCFG"; V="$TMPROOT/o"; RUNREL=projects/proj/.squad/ralph-run.md
printf '%s\n' "$RUN" > "$V/$RUNREL"; git -C "$V" add -A; git -C "$V" commit -qm run; git -C "$V" push -q origin main 2>/dev/null
git -C "$V" switch -qc lore/other-2026-11-03
printf 'other session wip\n' >> "$V/projects/proj/.squad/progress.txt"   # dirty, same path
sp "$V" where --file run
WT="$V/.claude/worktrees/lore-proj-$D"
check "off main: where returns the session worktree path" "$WT/$RUNREL" "$(printf '%s\n' "$OUT" | sed -n 's/^FILE=//p')"
sp "$V" run-row --issue '#5' --set 'State=building'
check "off main: run-row applied" "OUTCOME=applied" "$(printf '%s\n' "$OUT" | sed -n 1p)"
sp "$V" where --file run
check "off main: row reads back from where's path" 1 "$(grep -c '^| #5 .*building' "$(printf '%s\n' "$OUT" | sed -n 's/^FILE=//p')")"
check "off main: row committed on the session branch" 1 "$(git -C "$V" show "lore/proj-$D:$RUNREL" | grep -c '^| #5 .*building')"
check "off main: checkout run file untouched" 0 "$(grep -c building "$V/$RUNREL")"
sp "$V" append --issue '#30' --line 'resolved. PR: #31 (base: main). Notes: n'
sp "$V" append --issue '#30' --line 'resolved. PR: #31 (base: main). Notes: n'
check "off main: append dedupes on the session copy" "unchanged" "$(printf '%s\n' "$OUT" | sed -n 's/^OUTCOME=//p')"
check "off main: other session's uncommitted edit survives" 1 "$(grep -c 'other session wip' "$V/projects/proj/.squad/progress.txt")"
check "off main: other session's edit not in our commit" 0 "$(git -C "$V" show "lore/proj-$D:projects/proj/.squad/progress.txt" | grep -c 'other session wip')"
check "off main: our line on the session branch" 1 "$(git -C "$V" show "lore/proj-$D:projects/proj/.squad/progress.txt" | grep -c '^\[#30\]')"
check "off main: our line not in the checkout" 0 "$(grep -c '^\[#30\]' "$V/projects/proj/.squad/progress.txt")"
check "off main: other branch has no new commit" "run" "$(git -C "$V" log -1 --format=%s lore/other-2026-11-03)"
# finish pushes the session branch although the checkout is off main
(PATH="$TMPROOT/bin:$PATH"; . "$TMPROOT/hooks/squad-common.sh"; squad_vault_finish "$V" >/dev/null 2>&1)
check "off main: finish pushed the session branch" 1 "$(git -C "$TMPROOT/o-origin.git" branch --list "lore/proj-$D" | wc -l | tr -d ' ')"
# direct mode off main: exit 10, never "applied"
mkvault od '{"vault_main": "direct"}'; V="$TMPROOT/od"; git -C "$V" switch -qc feature/x
sp "$V" append --issue '#40' --line 'resolved. PR: #41 (base: main). Notes: n'
check "off main direct: append exits 10" 10 "$RC"
check "off main direct: no applied outcome" 0 "$(printf '%s\n' "$OUT" | grep -c 'OUTCOME=applied')"
check "off main direct: nothing written" "" "$(git -C "$V" status --porcelain)"

echo "---"; echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]
