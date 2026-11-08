#!/usr/bin/env bash
# Tests the tracker/vcs facades (claude/hooks/squad-tracker.sh, squad-vcs.sh):
# provider selection from chisel-config.json, the fake adapter proving the
# facade contract, the detached write refusal, and the github adapters over
# the gh shim. Plain bash 3.2; jq needed only for the config edit.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
TRK="$REPO_ROOT/claude/hooks/squad-tracker.sh"
VCS="$REPO_ROOT/claude/hooks/squad-vcs.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-tracker
FIXROOTS=""
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
command -v jq >/dev/null 2>&1 || { echo "skip - jq missing"; exit 0; }

fixture() {  # fixture <mode> [tracker]; sets P, V
  local out cfg; out="$("$MK" "$1")" || return 1
  P="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"; V="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  FIXROOTS="$FIXROOTS $(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
  cfg="$V/projects/fixture/.squad/chisel-config.json"
  if [ -n "${2:-}" ]; then jq --arg t "$2" '.chisel.tracker = $t' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"; fi
}
run() { (cd "$P" && SECOND_BRAIN_PATH="$V" SQUAD_FAKE_TRACKER_DIR="$TMPROOT/fake" "$@" 2>"$TMPROOT/err"); }
key() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

# --- provider selection
fixture connected fake
out="$(cd "$P" && SECOND_BRAIN_PATH="$V" bash "$REPO_ROOT/claude/hooks/path-resolve.sh" 2>/dev/null)"
check "path-resolve exports TRACKER_PROVIDER from chisel.tracker" fake "$(key "$out" TRACKER_PROVIDER)"
check "path-resolve defaults VCS_PROVIDER to github" github "$(key "$out" VCS_PROVIDER)"

# --- fake adapter: the facade contract
out="$(run bash "$TRK" create --title "Container")"; rc=$?
check "create: exit 0" 0 "$rc"; PID="$(key "$out" ID)"; check "create: ID" 1 "$PID"
out="$(run bash "$TRK" create-child "$PID" --title "Child A" --body b)"; A="$(key "$out" ID)"
out="$(run bash "$TRK" create-child "$PID" --title "Child B" --body b --blocked-by "$A")"; B="$(key "$out" ID)"
out="$(run bash "$TRK" get "$B")"
check "get: TITLE" "Child B" "$(key "$out" TITLE)"
check "get: PARENT" "$PID" "$(key "$out" PARENT)"
check "get: BLOCKED_BY" "$A" "$(key "$out" BLOCKED_BY)"
check "get: STATE" open "$(key "$out" STATE)"
out="$(run bash "$TRK" batch "$PID")"
check "batch: both children in order" "$A $B" "$(printf '%s\n' "$out" | sed -n 's/^ID=//p' | tr '\n' ' ' | sed 's/ $//')"
run bash "$TRK" label "$A" --assign-me --add in-progress --add x >/dev/null; rc=$?
check "label add: exit 0" 0 "$rc"
check "label add: labels read back" "in-progress,x" "$(key "$(run bash "$TRK" get "$A")" LABELS)"
run bash "$TRK" label "$A" --remove x >/dev/null
check "label remove" "in-progress" "$(key "$(run bash "$TRK" get "$A")" LABELS)"
run bash "$TRK" comment "$A" --body hello >/dev/null; check "comment: exit 0" 0 "$?"
run bash "$TRK" get 999 >/dev/null; check "get unknown id: exit 10" 10 "$?"
run bash "$TRK" bogus >/dev/null; check "unknown verb: exit 10" 10 "$?"
run bash "$TRK" create >/dev/null; check "create without title: exit 2" 2 "$?"
run bash "$TRK" >/dev/null; check "no verb: exit 2" 2 "$?"

# --- detached: writes refused, reads allowed
fixture detached fake
rm -rf "$TMPROOT/fake"
run bash "$TRK" create --title t >/dev/null; check "detached create refused: exit 20" 20 "$?"
run bash "$TRK" label 1 --add x >/dev/null; check "detached label refused: exit 20" 20 "$?"
[ ! -e "$TMPROOT/fake/1.issue" ] && ok "detached create wrote nothing" || bad "detached create wrote an issue"

# --- missing adapter
fixture connected nosuch
run bash "$TRK" get 1 >/dev/null; check "unknown provider: exit 10" 10 "$?"

# --- github adapters over the gh shim (reads only; the shim rejects writes)
fixture connected
SHIM="$TMPROOT/shimbin"; mkdir -p "$SHIM"; ln -s "$REPO_ROOT/scripts/gh-shim/gh" "$SHIM/gh"
export GH_SHIM_LOG="$TMPROOT/gh.log"; : > "$GH_SHIM_LOG"
out="$(run env PATH="$SHIM:$PATH" bash "$TRK" labels 5)"; check "github labels: exit 0" 0 "$?"
grep -q '^gh repo view --json nameWithOwner' "$GH_SHIM_LOG" && grep -q '^gh issue view 5 -R stub-owner/stub-repo --json labels' "$GH_SHIM_LOG" \
  && ok "github labels: repo lookup then issue view with -R" || bad "github labels argv: $(cat "$GH_SHIM_LOG")"
: > "$GH_SHIM_LOG"
out="$(run env PATH="$SHIM:$PATH" bash "$VCS" pr-view 3 --field base)"
# the shim ignores -q and prints the whole stub JSON
case "$out" in BASE=*) ok "github pr-view base: BASE= line" ;; *) bad "github pr-view base ($out)" ;; esac
run env PATH="$SHIM:$PATH" bash "$VCS" available; check "github available" 0 "$?"
run env PATH="$SHIM:$PATH" bash "$VCS" auth-status; check "github auth-status" 0 "$?"
out="$(run env PATH="$SHIM:$PATH" bash "$VCS" description-get 3)"; check "github description-get" 0 "$?"
fixture detached
: > "$GH_SHIM_LOG"
run env PATH="$SHIM:$PATH" bash "$VCS" description-set 3 --body-file /dev/null >/dev/null; check "detached description-set refused: exit 20" 20 "$?"
[ ! -s "$GH_SHIM_LOG" ] && ok "detached description-set made zero gh calls" || bad "gh called in detached mode"
run bash "$VCS" bogus >/dev/null; check "vcs unknown verb: exit 10" 10 "$?"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
