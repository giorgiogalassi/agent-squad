#!/usr/bin/env bash
# Tier-1 tests for source-side incident capture (squad_incident in
# squad-common.sh, called from squad-labels.sh / squad-branch.sh).
# Plain bash 3.2. SQUAD_INCIDENTS_FILE always points at a temp file.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-incident-capture.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

# Repo hooks copied side by side (incidents store resolved via own dir).
mkdir -p "$TMPROOT/hooks" "$TMPROOT/stubbin" "$TMPROOT/shimbin"
cp "$REPO_ROOT"/claude/hooks/*.sh "$REPO_ROOT"/claude/hooks/*.py "$TMPROOT/hooks/" 2>/dev/null
ln -s "$REPO_ROOT/scripts/gh-shim/gh" "$TMPROOT/shimbin/gh"
cat > "$TMPROOT/stubbin/gh" <<'EOP'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo '{"nameWithOwner":"o/r"}' ;;
  "issue view") echo "{\"labels\":[{\"name\":\"${GH_STUB_LABELS:-}\"}]}" ;;
  "issue edit"|"issue comment") exit "${GH_STUB_RC:-0}" ;;
  *) exit 1 ;;
esac
EOP
chmod +x "$TMPROOT/stubbin/gh"
export GH_SHIM_LOG="$TMPROOT/gh.log"; : > "$GH_SHIM_LOG"

N=0
newstore() { N=$((N+1)); export SQUAD_INCIDENTS_FILE="$TMPROOT/store$N.tsv"; : > "$SQUAD_INCIDENTS_FILE"; }
rows() { wc -l < "$SQUAD_INCIDENTS_FILE" | tr -d ' '; }
fixture() {
  local out; out="$("$MK" "$@")" || return 1
  F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
  F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
  F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  FIXROOTS="$FIXROOTS $F_ROOT"
}
lab() {  # lab <bindir> <args...>: sets RC, OUT
  local bindir="$1"; shift
  OUT="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$bindir:$PATH" \
    bash "$TMPROOT/hooks/squad-labels.sh" "$@" 2>/dev/null)"; RC=$?
}
col() { awk -F'\t' -v c="$1" 'END{print $c}' "$SQUAD_INCIDENTS_FILE"; }

# 1. review on a never-claimed issue -> one failure row
fixture connected; newstore
GH_STUB_LABELS="" lab "$TMPROOT/stubbin" review --issue 7
check "review never-claimed: exit 10" 10 "$RC"
check "review never-claimed: one row" 1 "$(rows)"
check "review never-claimed: source/kind/component" "script/failure/squad-labels" "$(col 4)/$(col 5)/$(col 6)"

# 2. detached refused write (exit 20 from squad_gh_write) -> store unchanged
fixture detached; newstore
( . "$TMPROOT/hooks/squad-common.sh"; TRACKER_MODE=detached; squad_gh_write issue edit 1 ) >/dev/null 2>&1
check "detached refusal: rc path ran, store unchanged" 0 "$(rows)"
lab "$TMPROOT/shimbin" claim --issue 7 --handoff "$TMPROOT/h.md"
check "detached claim: store unchanged" 0 "$(rows)"
mkdir -p "$TMPROOT/hdir"
lab "$TMPROOT/shimbin" claim --issue 7 --handoff "$TMPROOT/hdir"
check "detached unwritable handoff: exit 20" 20 "$RC"
check "detached unwritable handoff: store unchanged" 0 "$(rows)"

# 3. usage errors -> store unchanged
fixture connected; newstore
lab "$TMPROOT/stubbin" claim
check "usage error: exit 2" 2 "$RC"
lab "$TMPROOT/stubbin" bogus
check "unknown verb: exit 2" 2 "$RC"
check "usage errors: store unchanged" 0 "$(rows)"

# 3b. routine preconditions are not recorded
GH_STUB_LABELS="in-review" lab "$TMPROOT/stubbin" claim --issue 7
check "claim from in-review: exit 10" 10 "$RC"
GH_STUB_LABELS="" lab "$TMPROOT/stubbin" escalate --issue 7 --reason x
check "escalate without in-progress: exit 10" 10 "$RC"
check "routine preconditions: store unchanged" 0 "$(rows)"

# 3c. a gh write failure (exit 20) is recorded
GH_STUB_RC=4 GH_STUB_LABELS="" lab "$TMPROOT/stubbin" claim --issue 7
check "gh write failure: exit 20" 20 "$RC"
check "gh write failure: one failure row" "1/failure" "$(rows)/$(col 5)"

# 4. escalate success -> escalation row
fixture connected; newstore
GH_STUB_LABELS="in-progress" lab "$TMPROOT/stubbin" escalate --issue 7 --reason "3 failed attempts"
check "escalate: exit 0" 0 "$RC"
check "escalate: one escalation row" "1/escalation/squad-labels" "$(rows)/$(col 5)/$(col 6)"
GH_STUB_LABELS="blocked" lab "$TMPROOT/stubbin" escalate --issue 7 --reason x
check "escalate idempotent: no new row" 1 "$(rows)"

# 5. unwritable store: stdout and exit identical to recording off
fixture connected
export SQUAD_INCIDENTS_FILE="$TMPROOT/nodir/deeper/x.tsv"
GH_STUB_LABELS="" lab "$TMPROOT/stubbin" review --issue 7; A="$RC|$OUT"
SQUAD_INCIDENTS=off GH_STUB_LABELS="" lab "$TMPROOT/stubbin" review --issue 7; B="$RC|$OUT"
check "unwritable store: same stdout and rc as off" "$B" "$A"
GH_STUB_LABELS="in-progress" lab "$TMPROOT/stubbin" escalate --issue 7 --reason r; A="$RC|$OUT"
SQUAD_INCIDENTS=off GH_STUB_LABELS="in-progress" lab "$TMPROOT/stubbin" escalate --issue 7 --reason r; B="$RC|$OUT"
check "unwritable store: escalate same stdout and rc" "$B" "$A"

# 6. helper works with VAULT_PATH unset (falls back via SECOND_BRAIN_PATH)
newstore
( unset VAULT_PATH; . "$TMPROOT/hooks/squad-common.sh"; set -e
  squad_incident squad-test 20 "early failure" ) >"$TMPROOT/o" 2>&1
check "helper: silent, safe under set -e" "" "$(cat "$TMPROOT/o")"
check "helper: row written with VAULT_PATH unset" "1/squad-test" "$(rows)/$(col 6)"
( unset VAULT_PATH; . "$TMPROOT/hooks/squad-common.sh"; squad_incident c 1 r; echo "rc=$?" ) | grep -q '^rc=0$' \
  && ok "helper: returns 0" || bad "helper: returns 0"

# 7. squad-branch: git fetch failure recorded; usage error not
fixture connected; newstore
( cd "$F_PROJECT" && git remote remove origin 2>/dev/null; git remote add origin /nonexistent/repo.git
  SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/shimbin:$PATH" bash "$TMPROOT/hooks/squad-branch.sh" create b1 --base main >/dev/null 2>&1 )
check "branch fetch failure: exit 20 recorded" "1/squad-branch" "$(rows)/$(col 6)"
newstore
( cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" bash "$TMPROOT/hooks/squad-branch.sh" create >/dev/null 2>&1 )
check "branch usage error: not recorded" 0 "$(rows)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
