#!/usr/bin/env bash
# Tests for claude/hooks/squad-fix-parse.sh (typed fix-round responses). Bash 3.2.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$REPO_ROOT/claude/hooks/squad-fix-parse.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-fix-parse
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
# run <name> <expected exit> <expected stdout> <input text> <parser args...>
run() {
  local name="$1" want="$2" wout="$3" text="$4" out rc; shift 4
  printf '## Fix responses\n%s' "$text" > "$TMPROOT/in.txt"
  out="$(bash "$P" --input "$TMPROOT/in.txt" "$@" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$wout" ] || printf '%s\n' "$out" | grep -qxF -- "$wout"; }; then ok "$name"
  else bad "$name (exit $rc, want $want; out: $(printf '%s' "$out" | tr '\n' ' '))"; fi
}
T=$'B1: FIX\nB2: CONTEST src/a.sh:12\n'
run "fix and contest: exit 0" 0 "" "$T" --open B1,B2
run "FIXES=B1" 0 "FIXES=B1" "$T" --open B1,B2
run "CONTESTS=B2" 0 "CONTESTS=B2" "$T" --open B1,B2
run "escalation listed" 0 "ESCALATIONS=B2" $'B1: FIX\nB2: ESCALATE needs a human\n' --open B1,B2
run "empty lists allowed" 0 "CONTESTS=" $'B1: FIX\n' --open B1
run "upheld may be FIX" 0 "FIXES=B2" $'B2: FIX\n' --open B2 --upheld B2
run "upheld may be ESCALATE" 0 "ESCALATIONS=B2" $'B2: ESCALATE no\n' --open B2 --upheld B2
run "missing: exit 10" 10 "MISSING=B2" $'B1: FIX\n' --open B1,B2
run "unknown ID: exit 10" 10 "" $'B1: FIX\nB3: FIX\n' --open B1
run "duplicate ID: exit 10" 10 "" $'B1: FIX\nB1: FIX\n' --open B1
run "contest on upheld: exit 10" 10 "" $'B2: CONTEST src/a.sh:1\n' --open B2 --upheld B2
run "no colon: exit 10" 10 "" $'B1 fix\n' --open B1
run "contest without evidence: exit 10" 10 "" $'B1: CONTEST\n' --open B1
run "lowercase verb accepted" 0 "FIXES=B1" $'B1: fix\n' --open B1
run "unknown verb: exit 10" 10 "" $'B1: frobbed\n' --open B1
run "unindented prose in section: exit 10" 10 "" $'B1: FIX\nSome prose here\n' --open B1
run "star marker contested" 0 "CONTESTS=B2" $'B1: FIX\n* B2: contested src/a.sh:3\n' --open B1,B2
run "FIXES alias" 0 "FIXES=B1" $'B1: FIXES\n' --open B1
run "premise escalate (#459)" 0 "ESCALATIONS=B1" $'B1: ESCALATE premise P2 — claim no longer holds\n' --open B1
run "escalated: colon text" 0 "ESCALATIONS=B1" $'B1: ESCALATED: needs human\n' --open B1
run "contested without text: exit 10" 10 "" $'B1: CONTESTED.\n' --open B1
run "fixing is not FIX" 10 "" $'B1: FIXING\n' --open B1
REPLY=$'- B1: FIXED. Step 3 reads `last` from the row first...\n  Step 4 wording is gone...\n- B2: FIXED. `open` and `upheld` are persisted...\n- B3: FIXED. Dropped the clause...\n'
run "natural reply parses" 0 "FIXES=B1,B2,B3" "$REPLY" --open B1,B2,B3
run "prose line: exit 10" 10 "" $'Done.\nB1: FIX\n' --open B1
run "OUTCOME/CHANGED on exit 0" 0 "OUTCOME=unchanged" $'B1: FIX\n' --open B1
run "CHANGED=no on exit 0" 0 "CHANGED=no" $'B1: FIX\n' --open B1
run "OUTCOME on exit 10" 10 "OUTCOME=unchanged" $'B3: FIX\n' --open B1
run "stray B-line: exit 10" 10 "" $'B1: FIX\nB2 maybe later\n' --open B1
printf '## Fix responses\nB2: CONTEST x:1\n' > "$TMPROOT/up.txt"
bash "$P" --input "$TMPROOT/up.txt" --open B1,B2 --upheld B2 2>&1 >/dev/null | grep -q FINDING_UPHELD && ok "contest on upheld reports upheld" || bad "contest on upheld reports upheld"
# Realistic full summary around the block; prose outside the section is ignored.
FULL=$'Plan done.\nB9: this prose line looks like an ID but is outside\n\nDone.\nPR: #493 -- [485] typed fix responses\nBranch: 485-x\nCommit: abc\nTests: passed\nNotes: see below\n\n## Fix responses\nB1: FIX\nB2: CONTEST claude/a.md:3\n\n## Appendix\nB7: ignored after next heading\n'
printf '%s' "$FULL" > "$TMPROOT/full.txt"
out="$(bash "$P" --input "$TMPROOT/full.txt" --open B1,B2 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 'CONTESTS=B2' && ok "full summary around block" || bad "full summary around block (rc $rc)"
printf 'Done.\nB1: FIX\n' > "$TMPROOT/nosec.txt"
err="$(bash "$P" --input "$TMPROOT/nosec.txt" --open B1 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 10 ] && printf '%s' "$err" | grep -q 'Fix responses' && ok "missing section: exit 10 with reason" || bad "missing section (rc $rc)"
printf '## Fix responses\nB1: FIX\n' | bash "$P" --input - --open B1 >/dev/null 2>&1 && ok "stdin input" || bad "stdin input"
bash "$P" --open B1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "no --input: exit 2" || bad "no --input: exit 2"
bash "$P" --input "$TMPROOT/in.txt" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no --open: exit 2" || bad "no --open: exit 2"
bash "$P" --input "$TMPROOT/none" --open B1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing file: exit 2" || bad "missing file: exit 2"
bash "$P" --input "$TMPROOT/in.txt" --open X1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "bad open ID: exit 2" || bad "bad open ID: exit 2"
bash "$P" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown flag: exit 2" || bad "unknown flag: exit 2"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
