#!/usr/bin/env bash
# Tests the write policy (#400): chisel.writes in chisel-config.json, enforced
# in the tracker and vcs facades. One allowed and one refused case per policy
# verb, the provider defaults, squad-pr-desc.sh without description-set, the
# escalate path without comment, and the validator. Plain bash 3.2; jq needed.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
TRK="$REPO_ROOT/claude/hooks/squad-tracker.sh"
VCS="$REPO_ROOT/claude/hooks/squad-vcs.sh"
PRD="$REPO_ROOT/claude/hooks/squad-pr-desc.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-writes
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
command -v jq >/dev/null 2>&1 || { echo "skip - jq missing"; exit 0; }

# gh stub: logs the argv, succeeds, prints a PR URL / body.
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >> "$GHLOG"
case "$*" in "pr create"*) echo "https://example.test/pr/9" ;; "pr view"*) echo "- old line" ;; esac
exit 0
STUB
chmod +x "$BIN/gh"
export GHLOG="$TMPROOT/gh.log"

# setcfg <jq filter> [jq args...]: edit the fixture's chisel-config.json.
setcfg() { local f="$1"; shift; jq "$@" "$f" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"; }
# fixture <tracker|-> <vcs|-> <writes-json|->; sets P, V, CFG
fixture() {
  local out; out="$(TMPDIR="$TMPROOT" "$MK" connected)" || return 1
  P="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"; V="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  CFG="$V/projects/fixture/.squad/chisel-config.json"
  if [ "$1" != - ]; then setcfg '.chisel.tracker = $t' --arg t "$1"; fi
  if [ "$2" != - ]; then setcfg '.chisel.vcs = $t' --arg t "$2"; fi
  if [ "$3" != - ]; then setcfg '.chisel.writes = $w' --argjson w "$3"; fi
  rm -rf "$TMPROOT/fake"; : > "$GHLOG"
}
run() { (cd "$P" && SECOND_BRAIN_PATH="$V" SQUAD_FAKE_TRACKER_DIR="$TMPROOT/fake" PATH="$BIN:$PATH" "$@" 2>"$TMPROOT/err"); }
key() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

# trk_case <verb-label> <writes-json> <expected rc> <facade args...>
trk_case() {
  local label="$1" w="$2" want="$3" out rc; shift 3
  fixture fake - -
  run bash "$TRK" create --title seed >/dev/null
  setcfg '.chisel.writes = $w' --argjson w "$w"
  out="$(run bash "$TRK" "$@")"; rc=$?
  check "tracker $label: exit $want" "$want" "$rc"
  if [ "$want" = 20 ]; then
    check "tracker $label: REASON names verb and project" "policy: ${1} not allowed on fixture" "$(key "$out" REASON)"
  fi
}
ALL_T='{"tracker":["create","create-child","set-state","claim","label","comment"]}'
trk_case "create allowed" "$ALL_T" 0 create --title t
trk_case "create refused" '{"tracker":["comment"]}' 20 create --title t
trk_case "create-child allowed" "$ALL_T" 0 create-child 1 --title t --body b
trk_case "create-child refused" '{"tracker":["create"]}' 20 create-child 1 --title t --body b
trk_case "set-state allowed" "$ALL_T" 0 set-state 1 in-review
trk_case "set-state refused" '{"tracker":["claim"]}' 20 set-state 1 in-review
trk_case "claim allowed" "$ALL_T" 0 claim 1
trk_case "claim refused" '{"tracker":["set-state"]}' 20 claim 1
trk_case "label allowed" "$ALL_T" 0 label 1 --add x
trk_case "label refused" '{"tracker":["comment"]}' 20 label 1 --add x
trk_case "comment allowed" "$ALL_T" 0 comment 1 --body hi
trk_case "comment refused" '{"tracker":["create","label"]}' 20 comment 1 --body hi
trk_case "empty list refuses every write" '{"tracker":[]}' 20 label 1 --add x
trk_case "read verb never governed" '{"tracker":[]}' 0 get 1
fixture fake - '{"tracker":["create"]}'
run bash "$TRK" create --title seed >/dev/null
[ -z "$(grep -c COMMENT "$TMPROOT/fake/1.issue" 2>/dev/null | grep -v '^0$')" ] && ok "refused comment wrote nothing" || bad "comment reached the tracker"

# --- vcs verbs over the gh stub: refused = zero gh calls
vcs_case() {  # vcs_case <label> <writes-json> <expected rc> <args...>
  local label="$1" w="$2" want="$3" out rc; shift 3
  fixture - - "$w"
  out="$(run bash "$VCS" "$@")"; rc=$?
  check "vcs $label: exit $want" "$want" "$rc"
  if [ "$want" = 20 ]; then
    check "vcs $label: REASON names verb and project" "policy: ${1} not allowed on fixture" "$(key "$out" REASON)"
    [ ! -s "$GHLOG" ] && ok "vcs $label: zero gh calls" || bad "vcs $label: gh called: $(cat "$GHLOG")"
  else
    [ -s "$GHLOG" ] && ok "vcs $label: gh called" || bad "vcs $label: gh not called"
  fi
}
echo "body" > "$TMPROOT/body.md"
ALL_V='{"vcs":["branch","pr-create","description-set","comment","stack-init"]}'
vcs_case "pr-create allowed" "$ALL_V" 0 pr-create --head h --base b --title t --body x
vcs_case "pr-create refused" '{"vcs":["comment"]}' 20 pr-create --head h --base b --title t --body x
vcs_case "description-set allowed" "$ALL_V" 0 description-set 3 --body-file "$TMPROOT/body.md"
vcs_case "description-set refused" '{"vcs":["pr-create"]}' 20 description-set 3 --body-file "$TMPROOT/body.md"
vcs_case "comment allowed" "$ALL_V" 0 comment 3 --body hi
vcs_case "comment refused" '{"vcs":["pr-create","description-set"]}' 20 comment 3 --body hi
vcs_case "stack-init refused" '{"vcs":["pr-create"]}' 20 stack-init a b
fixture - - "$ALL_V"
run bash "$VCS" stack-init a b >/dev/null; rc=$?
case "$rc" in 0|10) ok "vcs stack-init allowed: reaches the adapter (exit $rc)" ;; *) bad "vcs stack-init allowed: exit $rc" ;; esac
fixture - - '{"vcs":[]}'
run bash "$VCS" description-get 3 >/dev/null; check "vcs read verb never governed" 0 "$?"
fixture - - '{"vcs":[]}'
run bash "$VCS" branch-exists main >/dev/null; rc=$?
case "$rc" in 0|1|10|20) ok "vcs branch-exists is not governed" ;; esac

# --- defaults by provider
fixture - - -
run bash "$VCS" comment 3 --body hi >/dev/null; check "default github vcs: comment allowed" 0 "$?"
run bash "$VCS" pr-create --head h --base b --title t --body x >/dev/null; check "default github vcs: pr-create allowed" 0 "$?"
fixture jira bitbucket -
run bash "$TRK" comment 1 --body hi >/dev/null; check "default jira tracker: comment refused before any adapter" 20 "$?"
run bash "$VCS" comment 3 --body hi >/dev/null 2>&1; rc=$?
check "default bitbucket vcs: comment refused (policy 20 before adapter lookup)" 20 "$rc"
check "default bitbucket vcs: REASON" "policy: comment not allowed on fixture" "$(key "$(run bash "$VCS" comment 3 --body hi)" REASON)"
fixture jira bitbucket '{"tracker":["comment"],"vcs":["comment"]}'
out="$(run bash "$VCS" comment 3 --body hi)"; rc=$?
[ -z "$(key "$out" REASON)" ] && ok "bitbucket widened explicitly: comment passes the policy (adapter says $rc)" || bad "widened list still refused"

# --- squad-pr-desc.sh without description-set
cat > "$TMPROOT/block.md" <<'EOB'
## Description drift
- line: - old line
  to: - new line
EOB
fixture - - '{"vcs":["pr-create","comment"]}'
HO="$TMPROOT/handoff.md"; rm -f "$HO"
out="$(run bash "$PRD" apply --block "$TMPROOT/block.md" --pr 3 --issue 7 --handoff "$HO")"; rc=$?
check "pr-desc without description-set: exit 20" 20 "$rc"
check "pr-desc without description-set: OUTCOME refused" refused "$(key "$out" OUTCOME)"
check "pr-desc without description-set: REASON" "policy: description-set not allowed on fixture" "$(key "$out" REASON)"
grep -q 'PR description of 7: replace "- old line" with "- new line"' "$HO" 2>/dev/null && ok "pr-desc: handoff file written" || bad "pr-desc: handoff missing"
[ ! -s "$GHLOG" ] && ok "pr-desc: the PR was never touched" || bad "pr-desc: gh called: $(cat "$GHLOG")"
fixture - - '{"vcs":["description-set"]}'
run bash "$PRD" apply --block "$TMPROOT/block.md" --pr 3 >/dev/null; check "pr-desc with description-set: exit 0" 0 "$?"
grep -q '^gh pr edit 3' "$GHLOG" && ok "pr-desc with description-set: PR edited" || bad "pr-desc did not edit: $(cat "$GHLOG")"

# --- escalate without comment: label moves, the reason stays out of the tracker
fixture - - '{"tracker":["set-state","claim","label"]}'
cat > "$BIN/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >> "$GHLOG"
case "$*" in
  "repo view"*) echo '{"nameWithOwner":"o/r"}' ;;
  "issue view"*) echo '{"labels":[{"name":"in-progress"}]}' ;;
  "label list"*) echo '[{"name":"in-progress"},{"name":"in-review"},{"name":"blocked"}]' ;;
esac
exit 0
STUB
out="$(run bash "$TRK" set-state 5 blocked --reason "needs a human")"; rc=$?
check "escalate without comment: exit 0" 0 "$rc"
check "escalate without comment: COMMENT=skipped" skipped "$(key "$out" COMMENT)"
grep -q 'issue comment' "$GHLOG" && bad "escalate posted a comment" || ok "escalate without comment: no gh issue comment"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
