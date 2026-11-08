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
  printf '%s' "$text" > "$TMPROOT/in.txt"
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
run "lowercase verb: exit 10" 10 "" $'B1: fix\n' --open B1
run "prose line: exit 10" 10 "" $'Done.\nB1: FIX\n' --open B1
printf 'B1: FIX\n' | bash "$P" --input - --open B1 >/dev/null 2>&1 && ok "stdin input" || bad "stdin input"
bash "$P" --open B1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "no --input: exit 2" || bad "no --input: exit 2"
bash "$P" --input "$TMPROOT/in.txt" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no --open: exit 2" || bad "no --open: exit 2"
bash "$P" --input "$TMPROOT/none" --open B1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing file: exit 2" || bad "missing file: exit 2"
bash "$P" --input "$TMPROOT/in.txt" --open X1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "bad open ID: exit 2" || bad "bad open ID: exit 2"
bash "$P" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown flag: exit 2" || bad "unknown flag: exit 2"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
