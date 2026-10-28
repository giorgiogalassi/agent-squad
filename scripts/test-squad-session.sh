#!/usr/bin/env bash
# Tests for claude/hooks/squad-session.sh. Plain bash 3.2; no bats, no jq.
# Usage: scripts/test-squad-session.sh
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$REPO_ROOT/claude/hooks/squad-session.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-session
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
run() { OUT="$("$SUT" "$@" 2>"$TMPROOT/err")"; RC=$?; ERR="$(cat "$TMPROOT/err")"; }
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

D="$TMPROOT/state"
# Pick a base unlikely to be in use.
B=48200

run port --owner a --dir "$D" --base $B --slots 5
check "port a rc" 0 "$RC"; PA="$(key PORT)"
check "port a is base" "$B" "$PA"
run port --owner b --dir "$D" --base $B --slots 5
PB="$(key PORT)"
check "port b differs from a (no manual step)" "yes" "$([ -n "$PB" ] && [ "$PA" != "$PB" ] && echo yes || echo no)"
run port --owner a --dir "$D" --base $B --slots 5
check "port a idempotent" "$PA" "$(key PORT)"
check "port a idempotent outcome" "unchanged" "$(key OUTCOME)"

# A port that something listens on is skipped.
if command -v python3 >/dev/null 2>&1; then
  python3 -c "
import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$((B+10)))); s.listen(1); print('up',flush=True); time.sleep(20)" > "$TMPROOT/py.out" 2>/dev/null &
  PYPID=$!
  i=0; while [ ! -s "$TMPROOT/py.out" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  run port --owner c --dir "$TMPROOT/s2" --base $((B+10)) --slots 3
  check "busy port skipped" "$((B+11))" "$(key PORT)"
  kill "$PYPID" 2>/dev/null; wait "$PYPID" 2>/dev/null
fi

run port --owner d --dir "$TMPROOT/s3" --base $B --slots 1
run port --owner e --dir "$TMPROOT/s3" --base $B --slots 1
check "exhausted rc" 10 "$RC"
run release --owner d --dir "$TMPROOT/s3"
check "release changed" "yes" "$(key CHANGED)"
run port --owner e --dir "$TMPROOT/s3" --base $B --slots 1
check "port reusable after release" "$B" "$(key PORT)"
# Stale port claim expires.
printf 'ghost\t1\n' > "$TMPROOT/s3/ports/$B"
run port --owner f --dir "$TMPROOT/s3" --base $B --slots 1 --ttl 60
check "stale port claim taken over" "$B" "$(key PORT)"

# profile
run profile --owner a --scratch "$TMPROOT/scratch"
check "profile dir" "$TMPROOT/scratch/playwright-profile" "$(key PROFILE_DIR)"
check "profile dir exists" "yes" "$([ -d "$TMPROOT/scratch/playwright-profile" ] && echo yes || echo no)"

# browser lock
run browser-lock status --owner a --dir "$D"
check "lock free" "free" "$(key LOCK)"
run browser-lock acquire --owner a --dir "$D"
check "acquire a" "acquired" "$(key LOCK)"
run browser-lock acquire --owner b --dir "$D"
check "acquire b held rc" 10 "$RC"
check "acquire b held key" "held" "$(key LOCK)"
check "acquire b held owner" "a" "$(key LOCK_OWNER)"
run browser-lock acquire --owner a --dir "$D"
check "acquire a idempotent rc" 0 "$RC"
run browser-lock release --owner b --dir "$D"
check "release by non-owner unchanged" "no" "$(key CHANGED)"
run browser-lock acquire --owner b --dir "$D"
check "still held after foreign release" 10 "$RC"
run browser-lock release --owner a --dir "$D"
check "release a" "yes" "$(key CHANGED)"
run browser-lock acquire --owner b --dir "$D"
check "acquire b after release" "acquired" "$(key LOCK)"
printf 'b\t1\n' > "$D/browser.lock"
run browser-lock acquire --owner a --dir "$D" --ttl 60
check "stale lock expires" "acquired" "$(key LOCK)"
run release --owner a --dir "$D"
check "release drops held lock" "free" "$(run browser-lock status --owner a --dir "$D"; key LOCK)"

# usage
run bogus;                          check "unknown verb rc" 2 "$RC"
run port --dir "$D";                check "missing owner rc" 2 "$RC"
run port --owner 'a b' --dir "$D";  check "bad owner rc" 2 "$RC"
run port --owner a --base x;        check "bad base rc" 2 "$RC"
run browser-lock nope --owner a;    check "bad lock sub rc" 2 "$RC"

# --worktrees prunes claims whose worktree dir is gone (never the caller's own).
W="$TMPROOT/wts"; mkdir -p "$W/live"
run port --owner k1-live --dir "$TMPROOT/s9" --base $B --slots 5 --worktrees "$W"
run port --owner k1-gone --dir "$TMPROOT/s9" --base $B --slots 5
check "gone owner holds second port" "$((B+1))" "$(key PORT)"
run port --owner k2-other --dir "$TMPROOT/s9" --base $B --slots 5
check "other repo owner holds third port" "$((B+2))" "$(key PORT)"
run port --owner k1-new --dir "$TMPROOT/s9" --base $B --slots 5 --worktrees "$W"
check "orphan claim of same repo pruned and port reused" "$((B+1))" "$(key PORT)"
check "live claim kept" "k1-live" "$(cut -f1 "$TMPROOT/s9/ports/$B")"
check "other repo claim kept" "k2-other" "$(cut -f1 "$TMPROOT/s9/ports/$((B+2))")"
run profile --owner a --scratch "$TMPROOT/scr"; check "profile first CHANGED" yes "$(key CHANGED)"
run profile --owner a --scratch "$TMPROOT/scr"; check "profile again CHANGED" no "$(key CHANGED)"
# Stale takeover leaves no .stale files behind.
mkdir -p "$TMPROOT/s9/ports"; printf 'old\t1\n' > "$TMPROOT/s9/ports/$((B+20))"
run port --owner z --dir "$TMPROOT/s9" --base $((B+20)) --slots 1 --ttl 10
check "stale claim taken over" "$((B+20))" "$(key PORT)"
check "no stale leftovers" "0" "$(ls "$TMPROOT/s9/ports" | grep -c "stale\|take")"

# .take mutex TTL: fresh mutex makes the loser back off; stale one is cleared.
T="$TMPROOT/s10"; mkdir -p "$T/ports"
printf 'old\t1\n' > "$T/ports/$B"; mkdir "$T/ports/$B.take"
run port --owner t1 --dir "$T" --base $B --slots 1 --ttl 10
check "fresh .take: loser backs off" 10 "$RC"
touch -t 200001010000 "$T/ports/$B.take"
run port --owner t1 --dir "$T" --base $B --slots 1 --ttl 10
check "stale .take cleared, takeover succeeds" "$B" "$(key PORT)"
check "mutex dir removed after takeover" no "$([ -d "$T/ports/$B.take" ] && echo yes || echo no)"
printf 'old\t1\n' > "$T/browser.lock"; mkdir "$T/browser.lock.take"
run browser-lock acquire --owner t2 --dir "$T"
check "lock: fresh .take backs off" 10 "$RC"
touch -t 200001010000 "$T/browser.lock.take"
run browser-lock acquire --owner t2 --dir "$T"
check "lock: stale .take cleared" acquired "$(key LOCK)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
