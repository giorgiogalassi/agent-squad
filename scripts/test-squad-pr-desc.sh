#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-pr-desc.sh. Plain bash 3.2; no bats, no jq.
# Usage: scripts/test-squad-pr-desc.sh
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
SUT_DIR="$REPO_ROOT/claude/hooks"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-pr-desc.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

mkdir -p "$TMPROOT/stubbin" "$TMPROOT/shimbin"
ln -s "$REPO_ROOT/scripts/gh-shim/gh" "$TMPROOT/shimbin/gh"
# Recording gh stub: `pr view` answers $GH_STUB_BODY; `pr edit` logs argv and
# keeps the --body-file content in $GH_EDIT_BODY.
cat > "$TMPROOT/stubbin/gh" <<'EOP'
#!/usr/bin/env bash
line="gh"; for a in "$@"; do line="$line $a"; done
case "$1 $2" in
  "pr view") echo "$line" >> "$GH_READ_LOG"; printf '%s\n' "$GH_STUB_BODY" ;;
  "pr edit")
    echo "$line" >> "$GH_SHIM_LOG"
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$GH_EDIT_BODY"; shift; done
    exit "${GH_STUB_RC:-0}" ;;
  *) echo "$line" >> "$GH_SHIM_LOG"; exit 1 ;;
esac
EOP
chmod +x "$TMPROOT/stubbin/gh"
export GH_SHIM_LOG="$TMPROOT/writes.log" GH_READ_LOG="$TMPROOT/reads.log" GH_EDIT_BODY="$TMPROOT/edited.md"

fixture() {
  local out; out="$("$MK" "$@")" || return 1
  F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
  F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
  F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  FIXROOTS="$FIXROOTS $F_ROOT"
  : > "$GH_SHIM_LOG"; : > "$GH_READ_LOG"; rm -f "$GH_EDIT_BODY"
}
run() {  # run <bindir> <args...>
  local bindir="$1"; shift
  (cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$bindir:$PATH" \
    bash "$SUT_DIR/squad-pr-desc.sh" "$@" >"$TMPROOT/out" 2>"$TMPROOT/err")
  RC=$?; OUT="$(cat "$TMPROOT/out")"; ERR="$(cat "$TMPROOT/err")"
  if [ -n "$OUT" ] && printf '%s\n' "$OUT" | grep -Eqv '^[A-Z_]+='; then bad "stdout has non-KEY=value line"; else PASS=$((PASS+1)); fi
}
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

BLK="$TMPROOT/block.md"
write_block() { printf '%s\n' "$@" > "$BLK"; }
S="$TMPROOT/stubbin"
export GH_STUB_BODY='## Summary
- adds the foo flag
- no tests needed

Closes #1'

# P1 replace + add
fixture connected
write_block '## Summary' 'x' '' '## Description drift' '- line: - no tests needed' '  to: - tests added in foo.test' '- add: handles empty input' '' '## Observations' '- line: Closes #1'
run "$S" apply --block "$BLK" --pr 7
check "P1 connected: rc/outcome/counts" "0/applied/yes/1/1/0" "$RC/$(key OUTCOME)/$(key CHANGED)/$(key REPLACED)/$(key ADDED)/$(key MISSED)"
check "P1 connected: exactly one pr edit" "1" "$(wc -l < "$GH_SHIM_LOG" | tr -d ' ')"
check "P1 connected: body edited, text after section ignored" \
'## Summary
- adds the foo flag
- tests added in foo.test

Closes #1
- handles empty input' "$(cat "$GH_EDIT_BODY")"

# P2 none -> unchanged, no write
fixture connected
write_block '## Description drift' '- none: no claim touched: change limited to tests'
run "$S" apply --block "$BLK" --pr 7
check "P2 none: unchanged, no gh write" "0/unchanged/no/" "$RC/$(key OUTCOME)/$(key CHANGED)/$(cat "$GH_SHIM_LOG")"

# P3 missed line
fixture connected
write_block '## Description drift' '- line: - not in body' '  to: - whatever'
run "$S" apply --block "$BLK" --pr 7
check "P3 missed line: unchanged, MISSED=1, no write" "0/unchanged/1/" "$RC/$(key OUTCOME)/$(key MISSED)/$(cat "$GH_SHIM_LOG")"

# P4 idempotent re-run
fixture connected
write_block '## Description drift' '- add: adds the foo flag'
run "$S" apply --block "$BLK" --pr 7
check "P4 add already present: unchanged" "0/unchanged/0" "$RC/$(key OUTCOME)/$(key ADDED)"

# P5 invalid blocks
fixture connected
write_block '## Summary' 'no drift section'
run "$S" apply --block "$BLK" --pr 7
check "P5 missing section: rc 10, no gh" "10/" "$RC/$(cat "$GH_SHIM_LOG")$(cat "$GH_READ_LOG")"
write_block '## Description drift' 'prose only'
run "$S" apply --block "$BLK" --pr 7
check "P5 empty section: rc 10" "10" "$RC"

# P6 usage and gh failure
write_block '## Description drift' '- add: new bullet'
run "$S" apply --block "$BLK"
check "P6 connected without --pr: rc 2" "2" "$RC"
run "$S" bogus
check "P6 unknown verb: rc 2" "2" "$RC"
write_block '## Description drift' '- add: new bullet'
GH_STUB_RC=1 run "$S" apply --block "$BLK" --pr 7
check "P6 gh pr edit fails: rc 20" "20" "$RC"

# D- detached: zero gh calls, handoff lines, idempotent
fixture detached
write_block '## Description drift' '- line: - old' '  to: - new' '- add: extra'
HO="$TMPROOT/handoff.md"
run "$TMPROOT/shimbin" apply --block "$BLK" --issue 9 --handoff "$HO"
check "D-1 detached: rc/outcome/items" "0/recorded-local/yes/2" "$RC/$(key OUTCOME)/$(key CHANGED)/$(key ITEMS)"
check "D-1 detached: two checklist lines" "2" "$(grep -c '^- \[ \] PR description of 9' "$HO")"
check "D-1 detached: no gh call" "0" "$(wc -c < "$GH_SHIM_LOG" | tr -d ' ')"
run "$TMPROOT/shimbin" apply --block "$BLK" --issue 9 --handoff "$HO"
check "D-2 detached re-run: unchanged" "0/unchanged/no" "$RC/$(key OUTCOME)/$(key CHANGED)"
run "$TMPROOT/shimbin" apply --block "$BLK" --issue 9
check "D-3 detached without --handoff: rc 2" "2" "$RC"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
