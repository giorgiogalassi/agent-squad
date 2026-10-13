#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-labels.sh. Plain bash 3.2; no bats, no jq.
#
# Usage: scripts/test-squad-labels.sh [path/to/squad-labels.sh]
#   An override path runs the same suite against a deliberately broken copy
#   (its directory must hold squad-common.sh and path-resolve.sh siblings).
#
# Row ids, in LABEL_STATE_MACHINE.md table order of the rows the script
# performs (issue #218 will add these ids to the doc):
#   L1  Create   (Chisel, connected)  -> verb `ensure`
#   L2  Claim    (Cody, connected)    -> verb `claim`
#   L3  PR opens (Cody, connected)    -> verb `review`
#   L4  Escalate (Ralph, connected)   -> verb `escalate`
# Test names are prefixed with the id: "L2 claim: exact argv", "L3 illegal:
# ...", "L4 idempotent: ...". Detached cases are prefixed "D-".
#
# The connected stub logs only MUTATING calls to $GH_SHIM_LOG (one line per
# call, argv joined by spaces, same format as scripts/gh-shim/gh); reads go
# to $GH_READ_LOG. Detached cases use the real shim, whose log must stay empty.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
SUT="${1:-$REPO_ROOT/claude/hooks/squad-labels.sh}"
[ -f "$SUT" ] || { echo "error: $SUT not found" >&2; exit 2; }
SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"; SUT_NAME="$(basename "$SUT")"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-labels.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

mkdir -p "$TMPROOT/hooks" "$TMPROOT/stubbin" "$TMPROOT/shimbin"
cp "$SUT_DIR/$SUT_NAME" "$SUT_DIR/squad-common.sh" "$SUT_DIR/path-resolve.sh" "$TMPROOT/hooks/" 2>/dev/null \
  || { echo "error: override dir lacks squad-common.sh/path-resolve.sh" >&2; exit 2; }
ln -s "$REPO_ROOT/scripts/gh-shim/gh" "$TMPROOT/shimbin/gh"
cat > "$TMPROOT/stubbin/gh" <<'EOP'
#!/usr/bin/env bash
# Recording gh stub. Reads answer from GH_STUB_LABELS (issue labels) and
# GH_STUB_EXISTING (repo labels), both comma-separated.
line="gh"; for a in "$@"; do line="$line $a"; done
json_names() {
  local out="" n IFS=,
  for n in $1; do [ -n "$n" ] && out="$out${out:+,}{\"name\":\"$n\"}"; done
  printf '%s' "$out"
}
case "$1 $2" in
  "repo view") echo "$line" >> "$GH_READ_LOG"; echo '{"nameWithOwner":"fixture-owner/fixture-repo"}' ;;
  "issue view") echo "$line" >> "$GH_READ_LOG"; echo "{\"labels\":[$(json_names "${GH_STUB_LABELS:-}")]}" ;;
  "label list") echo "$line" >> "$GH_READ_LOG"; echo "[$(json_names "${GH_STUB_EXISTING:-}")]" ;;
  "issue edit"|"issue comment"|"label create") echo "$line" >> "$GH_SHIM_LOG"; exit "${GH_STUB_RC:-0}" ;;
  *) echo "$line" >> "$GH_SHIM_LOG"; exit 1 ;;
esac
EOP
chmod +x "$TMPROOT/stubbin/gh"
export GH_SHIM_LOG="$TMPROOT/writes.log" GH_READ_LOG="$TMPROOT/reads.log"

fixture() {  # fixture <connected|detached> [--labels-custom]
  local out; out="$("$MK" "$@")" || return 1
  F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
  F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
  F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  FIXROOTS="$FIXROOTS $F_ROOT"
  : > "$GH_SHIM_LOG"; : > "$GH_READ_LOG"
}
# lab <bindir> <args...>: sets RC, OUT, ERR; asserts stdout shape.
lab() {
  local bindir="$1"; shift
  (cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$bindir:$PATH" \
    bash "$TMPROOT/hooks/$SUT_NAME" "$@" >"$TMPROOT/out" 2>"$TMPROOT/err")
  RC=$?; OUT="$(cat "$TMPROOT/out")"; ERR="$(cat "$TMPROOT/err")"
  if [ -n "$OUT" ] && printf '%s\n' "$OUT" | grep -qv '^[A-Z_]*='; then
    bad "stdout has non-KEY=value line: $(printf '%s' "$OUT" | grep -v '^[A-Z_]*=' | head -1)"
  else PASS=$((PASS+1)); fi
}
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
writes() { cat "$GH_SHIM_LOG"; }
R="-R fixture-owner/fixture-repo"
C=stubbin

# ---- L1 ensure
fixture connected
GH_STUB_EXISTING="in-progress" lab "$TMPROOT/$C" ensure
check "L1 ensure: rc" 0 "$RC"
check "L1 ensure: creates only missing labels (exact argv)" \
"gh label create needs-review $R
gh label create in-review $R
gh label create blocked $R" "$(writes)"
check "L1 ensure: outcome" "applied/yes" "$(key OUTCOME)/$(key CHANGED)"
: > "$GH_SHIM_LOG"
GH_STUB_EXISTING="needs-review,in-progress,in-review,blocked" lab "$TMPROOT/$C" ensure
check "L1 idempotent: ensure" "0/unchanged/no/" "$RC/$(key OUTCOME)/$(key CHANGED)/$(writes)"
fixture connected --labels-custom
GH_STUB_EXISTING="" lab "$TMPROOT/$C" ensure
check "L1 custom: ensure uses wip, skips review_label none" \
"gh label create wip $R
gh label create in-review $R
gh label create blocked $R" "$(writes)"

# ---- L2 claim
fixture connected
GH_STUB_LABELS="needs-review" lab "$TMPROOT/$C" claim --issue 7
check "L2 claim: rc/outcome" "0/applied/yes/7" "$RC/$(key OUTCOME)/$(key CHANGED)/$(key ISSUE)"
check "L2 claim: exact argv" "gh issue edit 7 $R --add-assignee @me --add-label in-progress" "$(writes)"
check "L2 claim: label sets" "needs-review|needs-review,in-progress" "$(key FROM_LABELS)|$(key TO_LABELS)"
: > "$GH_SHIM_LOG"
GH_STUB_LABELS="in-progress" lab "$TMPROOT/$C" claim --issue 7
check "L2 idempotent: claim" "0/unchanged/no/" "$RC/$(key OUTCOME)/$(key CHANGED)/$(writes)"
GH_STUB_LABELS="in-review" lab "$TMPROOT/$C" claim --issue 7
check "L2 illegal: claim from in-review" "10/" "$RC/$(writes)"
GH_STUB_RC=4 GH_STUB_LABELS="" lab "$TMPROOT/$C" claim --issue 7
check "L2 gh write failure maps to 20" 20 "$RC"
: > "$GH_SHIM_LOG"
lab "$TMPROOT/$C" claim; check "L2 claim without --issue is usage error" 2 "$RC"
fixture connected --labels-custom
GH_STUB_LABELS="" lab "$TMPROOT/$C" claim --issue 7
check "L2 custom: argv uses wip" "gh issue edit 7 $R --add-assignee @me --add-label wip" "$(writes)"

# ---- L3 review
fixture connected
GH_STUB_LABELS="in-progress,needs-review" lab "$TMPROOT/$C" review --issue 7
check "L3 review: rc/outcome" "0/applied/yes" "$RC/$(key OUTCOME)/$(key CHANGED)"
check "L3 review: exact argv" "gh issue edit 7 $R --remove-label in-progress --add-label in-review
gh issue edit 7 $R --remove-label needs-review" "$(writes)"
check "L3 review: label sets" "needs-review,in-progress|in-review" "$(key FROM_LABELS)|$(key TO_LABELS)"
: > "$GH_SHIM_LOG"
GH_STUB_LABELS="in-review" lab "$TMPROOT/$C" review --issue 7
check "L3 idempotent: review" "0/unchanged/no/" "$RC/$(key OUTCOME)/$(key CHANGED)/$(writes)"
GH_STUB_LABELS="" lab "$TMPROOT/$C" review --issue 7
check "L3 illegal: review with neither in-progress nor in-review" "10/" "$RC/$(writes)"
fixture connected --labels-custom
GH_STUB_LABELS="wip" lab "$TMPROOT/$C" review --issue 7
check "L3 custom: wip swap, no review_label removal" "gh issue edit 7 $R --remove-label wip --add-label in-review" "$(writes)"

# ---- L4 escalate
fixture connected
GH_STUB_LABELS="in-progress,needs-review" lab "$TMPROOT/$C" escalate --issue 7 --reason "3 failed attempts"
check "L4 escalate: rc/outcome" "0/applied/yes" "$RC/$(key OUTCOME)/$(key CHANGED)"
check "L4 escalate: exact argv" "gh issue edit 7 $R --remove-label in-progress --add-label blocked
gh issue comment 7 $R --body 3 failed attempts" "$(writes)"
: > "$GH_SHIM_LOG"
GH_STUB_LABELS="blocked" lab "$TMPROOT/$C" escalate --issue 7 --reason x
check "L4 idempotent: escalate" "0/unchanged/no/" "$RC/$(key OUTCOME)/$(key CHANGED)/$(writes)"
GH_STUB_LABELS="" lab "$TMPROOT/$C" escalate --issue 7 --reason x
check "L4 illegal: escalate without in-progress" "10/" "$RC/$(writes)"
lab "$TMPROOT/$C" escalate --issue 7; check "L4 escalate without --reason is usage error" 2 "$RC"
fixture connected --labels-custom
GH_STUB_LABELS="wip" lab "$TMPROOT/$C" escalate --issue 7 --reason r
check "L4 custom: argv uses wip" "gh issue edit 7 $R --remove-label wip --add-label blocked
gh issue comment 7 $R --body r" "$(writes)"

# ---- detached: zero gh calls, one handoff line per verb
fixture detached
H="$TMPROOT/handoff.md"; : > "$H"
dcase() {  # dcase <expected-line> <verb args...>
  local want="$1"; shift
  lab "$TMPROOT/shimbin" "$@" --handoff "$H"
  check "D-$1 first call recorded-local" "0/recorded-local/yes" "$RC/$(key OUTCOME)/$(key CHANGED)"
  check "D-$1 line appended" "$want" "$(tail -1 "$H")"
  check "D-$1 HANDOFF_LINE" "$want" "$(key HANDOFF_LINE)"
  lab "$TMPROOT/shimbin" "$@" --handoff "$H"
  check "D-$1 second call unchanged" "0/unchanged/no" "$RC/$(key OUTCOME)/$(key CHANGED)"
}
dcase "- [ ] Move PROJ-7 to In Progress" claim --issue PROJ-7
dcase "- [ ] Move 7 to In Review" review --issue 7
dcase "- [ ] Move 7 to Blocked, comment: stuck after 3" escalate --issue 7 --reason "stuck after 3"
check "D- handoff has exactly three lines" 3 "$(wc -l < "$H" | tr -d ' ')"
lab "$TMPROOT/shimbin" ensure
check "D-ensure no-op" "0/unchanged/no" "$RC/$(key OUTCOME)/$(key CHANGED)"
for v in "claim --issue 7" "review --issue 7" "escalate --issue 7 --reason r"; do
  # shellcheck disable=SC2086
  lab "$TMPROOT/shimbin" $v
  check "D-$v without --handoff is usage error" 2 "$RC"
done
check "D- shim log empty (zero gh calls)" "" "$(cat "$GH_SHIM_LOG")"
fixture detached --labels-custom
lab "$TMPROOT/shimbin" claim --issue 9 --handoff "$TMPROOT/h2.md"
check "D-custom fixture still records" "0/recorded-local" "$RC/$(key OUTCOME)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
