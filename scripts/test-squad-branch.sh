#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-branch.sh. Plain bash 3.2; no bats, no jq.
#
# Usage: scripts/test-squad-branch.sh [path/to/squad-branch.sh]
#   An override path runs the same suite against a deliberately broken copy
#   (its directory must hold squad-common.sh and path-resolve.sh siblings).
#
# Every invocation asserts each stdout line matches ^[A-Z_]+=. The gh shim is
# first on PATH for every call; its log must stay empty (no gh calls).
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
SUT="${1:-$REPO_ROOT/claude/hooks/squad-branch.sh}"
[ -f "$SUT" ] || { echo "error: $SUT not found" >&2; exit 2; }
SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"; SUT_NAME="$(basename "$SUT")"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-branch.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

mkdir -p "$TMPROOT/hooks" "$TMPROOT/shimbin"
cp "$SUT_DIR/$SUT_NAME" "$SUT_DIR/squad-common.sh" "$SUT_DIR/path-resolve.sh" "$TMPROOT/hooks/" 2>/dev/null \
  || { echo "error: override dir lacks squad-common.sh/path-resolve.sh" >&2; exit 2; }
ln -s "$REPO_ROOT/scripts/gh-shim/gh" "$TMPROOT/shimbin/gh"
export GH_SHIM_LOG="$TMPROOT/gh.log"; : > "$GH_SHIM_LOG"

GIT="git -c user.name=T -c user.email=t@example.com"
fixture() {  # fixture [--worktree]
  local out; out="$("$MK" connected "$@")" || return 1
  F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
  F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
  F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  F_WT="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')"
  FIXROOTS="$FIXROOTS $F_ROOT"
  # a pushed base branch "dev" one commit ahead of main
  $GIT -C "$F_PROJECT" checkout -q -b dev
  echo dev > "$F_PROJECT/dev.txt"
  $GIT -C "$F_PROJECT" add dev.txt
  $GIT -C "$F_PROJECT" commit -q -m dev
  $GIT -C "$F_PROJECT" push -q origin dev
  $GIT -C "$F_PROJECT" checkout -q main
  $GIT -C "$F_PROJECT" branch -q -D dev
}
# br <cwd> <args...>: sets RC, OUT, ERR; asserts stdout shape.
br() {
  local cwd="$1"; shift
  (cd "$cwd" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/shimbin:$PATH" \
    bash "$TMPROOT/hooks/$SUT_NAME" "$@" >"$TMPROOT/out" 2>"$TMPROOT/err")
  RC=$?; OUT="$(cat "$TMPROOT/out")"; ERR="$(cat "$TMPROOT/err")"
  if [ -n "$OUT" ] && printf '%s\n' "$OUT" | grep -qv '^[A-Z_][A-Z_]*='; then
    bad "stdout has non-KEY=value line: $(printf '%s' "$OUT" | grep -v '^[A-Z_][A-Z_]*=' | head -1)"
  else PASS=$((PASS+1)); fi
}
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
head_of() { $GIT -C "$1" rev-parse HEAD; }
cur() { $GIT -C "$1" symbolic-ref --short HEAD; }

# ---- create from origin/<base>
fixture
P="$F_PROJECT"
br "$P" create feat-a --base dev
check "create: rc/outcome/changed" "0/applied/yes" "$RC/$(key OUTCOME)/$(key CHANGED)"
check "create: BRANCH/BASE" "feat-a/dev" "$(key BRANCH)/$(key BASE)"
check "create: HEAD_SHA is origin/dev" "$($GIT -C "$P" rev-parse origin/dev)" "$(key HEAD_SHA)"
check "create: HEAD_SHA equals git rev-parse HEAD" "$(head_of "$P")" "$(key HEAD_SHA)"
check "create: branch checked out" "feat-a" "$(cur "$P")"

# ---- idempotent create
br "$P" create feat-a --base dev
check "create idempotent: rc/outcome/changed" "0/unchanged/no" "$RC/$(key OUTCOME)/$(key CHANGED)"

# ---- create when branch exists but is not checked out
$GIT -C "$P" checkout -q main
br "$P" create feat-a --base dev
check "create existing, not checked out: applied" "0/applied/yes/feat-a" "$RC/$(key OUTCOME)/$(key CHANGED)/$(cur "$P")"

# ---- continue existing
$GIT -C "$P" checkout -q main
br "$P" continue feat-a --base dev
check "continue existing: rc/outcome" "0/applied/yes/feat-a" "$RC/$(key OUTCOME)/$(key CHANGED)/$(cur "$P")"
br "$P" continue feat-a --base dev
check "continue already checked out: unchanged" "0/unchanged/no" "$RC/$(key OUTCOME)/$(key CHANGED)"

# ---- continue: missing branch
br "$P" continue nope --base dev
check "continue missing branch: exit 10" "10/" "$RC/$OUT"

# ---- continue: remote-only branch
$GIT -C "$P" push -q origin feat-a:remote-only
$GIT -C "$P" checkout -q main
br "$P" continue remote-only --base dev
check "continue remote-only: applied" "0/applied/yes/remote-only" "$RC/$(key OUTCOME)/$(key CHANGED)/$(cur "$P")"
check "continue remote-only: tracks origin" "origin" "$($GIT -C "$P" config branch.remote-only.remote)"

# ---- base missing
br "$P" create feat-b --base ghost
check "base missing (create): exit 10" "10/" "$RC/$OUT"
br "$P" continue feat-a --base ghost
check "base missing (continue): exit 10" "10/" "$RC/$OUT"
check "base missing: no branch created" "" "$($GIT -C "$P" branch --list feat-b)"

# ---- usage errors
br "$P"; check "no verb: exit 2" 2 "$RC"
br "$P" frob x --base dev; check "unknown verb: exit 2" 2 "$RC"
br "$P" create; check "no branch: exit 2" 2 "$RC"
br "$P" create feat-c; check "no --base: exit 2" 2 "$RC"
br "$P" create feat-c --base; check "--base without value: exit 2" 2 "$RC"

# ---- checked out in another worktree
fixture --worktree
P="$F_PROJECT"; W="$F_WT"
$GIT -C "$P" checkout -q main
BEFORE="$($GIT -C "$P" status --porcelain)|$(head_of "$P")|$(cur "$P")"
WBEFORE="$($GIT -C "$W" status --porcelain)|$(head_of "$W")|$(cur "$W")"
br "$P" continue fixture-wt --base main
check "other worktree (continue): exit 10" "10/" "$RC/$OUT"
case "$ERR" in *"$W"*) ok "other worktree: stderr names $W" ;; *) bad "other worktree: stderr lacks path: $ERR" ;; esac
br "$P" create fixture-wt --base main
check "other worktree (create): exit 10" "10/" "$RC/$OUT"
case "$ERR" in *"$W"*) ok "other worktree (create): stderr names path" ;; *) bad "stderr lacks path: $ERR" ;; esac
check "other worktree: project status unchanged" "$BEFORE" "$($GIT -C "$P" status --porcelain)|$(head_of "$P")|$(cur "$P")"
check "other worktree: worktree status unchanged" "$WBEFORE" "$($GIT -C "$W" status --porcelain)|$(head_of "$W")|$(cur "$W")"

# ---- invocation from a worktree cwd
br "$W" create feat-w --base main
check "worktree cwd: rc/outcome" "0/applied/yes/feat-w" "$RC/$(key OUTCOME)/$(key CHANGED)/$(cur "$W")"
check "worktree cwd: HEAD_SHA equals rev-parse HEAD there" "$(head_of "$W")" "$(key HEAD_SHA)"
check "worktree cwd: project checkout untouched" "main" "$(cur "$P")"
br "$W" create feat-w --base main
check "worktree cwd: idempotent" "0/unchanged" "$RC/$(key OUTCOME)"

# ---- fetch failure
$GIT -C "$P" remote set-url origin "$F_ROOT/does-not-exist.git"
br "$P" create feat-d --base main
check "fetch failure (create): exit 20" "20/" "$RC/$OUT"
br "$P" continue feat-w --base main
check "fetch failure (continue): exit 20" "20/" "$RC/$OUT"

check "no gh calls in any mode (shim log empty)" "" "$(cat "$GH_SHIM_LOG")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
