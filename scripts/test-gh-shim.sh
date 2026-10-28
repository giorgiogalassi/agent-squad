#!/usr/bin/env bash
# Tests scripts/gh-shim/gh and scripts/fixtures/make-fixture.sh.
# Plain bash + git + coreutils; no bats, no jq.
set -u
# Never write the real vault incident store.
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM_DIR="$REPO_ROOT/scripts/gh-shim"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
PR="$REPO_ROOT/claude/hooks/path-resolve.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-gh-shim
FIXROOTS=""

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

export GH_SHIM_LOG="$TMPROOT/gh.log"
: > "$GH_SHIM_LOG"
GH="$SHIM_DIR/gh"

# expect_ok <name> args...; expect_rej <name> args...
expect_ok() {
  local n="$1"; shift
  if "$GH" "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n (exit non-zero)"; fi
}
expect_rej() {
  local n="$1"; shift
  local before; before="$(grep -c '^REJECTED ' "$GH_SHIM_LOG")"
  "$GH" "$@" >/dev/null 2>&1; local rc=$?
  local after; after="$(grep -c '^REJECTED ' "$GH_SHIM_LOG")"
  if [ "$rc" = 1 ] && [ "$after" = $((before+1)) ]; then ok "$n"; else bad "$n (rc=$rc)"; fi
}

expect_ok "issue view accepted" issue view 1
grep -q '^gh issue view 1$' "$GH_SHIM_LOG" && ok "issue view logged" || bad "issue view logged"
expect_ok "issue list" issue list
expect_ok "pr view" pr view 3
expect_ok "pr list" pr list
expect_ok "pr checks" pr checks 3
expect_ok "pr diff" pr diff 3
expect_ok "project view" project view 1 --owner x
expect_ok "label list" label list
expect_ok "auth status" auth status
expect_ok "--version" --version
expect_ok "api -X GET" api repos/x/y -X GET
expect_ok "api --method GET" api repos/x/y --method GET
case "$("$GH" repo view --json nameWithOwner)" in
  *'"nameWithOwner":"'*/*'"'*) ok "repo view has nameWithOwner" ;;
  *) bad "repo view has nameWithOwner" ;;
esac

expect_rej "api graphql rejected" api graphql -f "query=mutation { x }"
expect_rej "api graphql -X GET rejected" api graphql -X GET
expect_rej "api -f without -X GET rejected" api repos/x/y -f a=b
expect_rej "api -F without -X GET rejected" api repos/x/y -F a=b
expect_rej "api -X POST rejected" api repos/x/y -X POST
expect_rej "issue edit rejected" issue edit 1 --add-label x
expect_rej "pr create rejected" pr create --title t
expect_rej "no args rejected" 

calls=21
n="$(wc -l < "$GH_SHIM_LOG" | tr -d ' ')"
[ "$n" = "$calls" ] && ok "log is one line per call ($n)" || bad "log lines=$n expected $calls"
"$GH" issue view 2 "multi
line" >/dev/null
n2="$(wc -l < "$GH_SHIM_LOG" | tr -d ' ')"
[ "$n2" = $((calls+1)) ] && ok "multiline arg stays one line" || bad "multiline arg split log"

# --- fixture smoke tests ---
smoke() { # <name> <mode> <flags...>
  local name="$1" mode="$2"; shift 2
  local out; out="$("$BASH" "$MK" "$mode" "$@")" || { bad "$name: make-fixture failed"; return; }
  local root proj wt vault sbp
  root="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
  proj="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
  wt="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')"
  vault="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  sbp="$(printf '%s\n' "$out" | sed -n 's/^SECOND_BRAIN_PATH=//p')"
  FIXROOTS="$FIXROOTS $root"
  [ "$sbp" = "$vault" ] && [ -d "$proj" ] && ok "$name: output keys" || bad "$name: output keys"
  git -C "$proj" ls-remote origin 2>/dev/null | grep -q 'refs/heads/main$' \
    && ok "$name: origin lists main" || bad "$name: origin lists main"
  local got
  got="$(cd "$proj" && SECOND_BRAIN_PATH="$vault" "$BASH" "$PR" 2>/dev/null | sed -n 's/^TRACKER_MODE=//p')"
  # connected needs jq (path-resolve falls back to detached without it)
  if [ "$mode" = connected ] && ! command -v jq >/dev/null 2>&1; then
    ok "$name: TRACKER_MODE skipped (jq absent)"
  else
    [ "$got" = "$mode" ] && ok "$name: TRACKER_MODE=$mode in PROJECT" || bad "$name: TRACKER_MODE=$got"
  fi
  if [ -n "$wt" ]; then
    got="$(cd "$wt" && SECOND_BRAIN_PATH="$vault" "$BASH" "$PR" 2>/dev/null | sed -n 's/^TRACKER_MODE=//p')"
    if [ "$mode" = connected ] && ! command -v jq >/dev/null 2>&1; then
      ok "$name: worktree TRACKER_MODE skipped (jq absent)"
    else
      [ "$got" = "$mode" ] && ok "$name: TRACKER_MODE=$mode in WORKTREE" || bad "$name: worktree TRACKER_MODE=$got"
    fi
  fi
  LAST_VAULT="$vault"
}

smoke "connected" connected
smoke "detached+worktree" detached --worktree
smoke "connected+worktree" connected --worktree
smoke "custom labels" connected --labels-custom
grep -q '"in_progress": "wip"' "$LAST_VAULT/projects/fixture/.squad/chisel-config.json" \
  && grep -q '"review_label": "none"' "$LAST_VAULT/projects/fixture/.squad/chisel-config.json" \
  && ok "custom labels written" || bad "custom labels written"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
