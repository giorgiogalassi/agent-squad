#!/usr/bin/env bash
# Tests for claude/hooks/worktree-divergence.sh and worktree-prompt-check.sh
# using a local bare origin. Plain bash 3.2.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$REPO_ROOT/claude/hooks/worktree-divergence.sh"
HOOK="$REPO_ROOT/claude/hooks/worktree-prompt-check.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-worktree-divergence
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
GIT="git -c user.name=T -c user.email=t@example.com"
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
run() { OUT="$(cd "$WT" && bash "$SUT" check "$@" 2>"$TMPROOT/err")"; RC=$?; ERR="$(cat "$TMPROOT/err")"; }

N=0
setup() {  # origin with main + feat; WT = worktree on feat; OTHER = second clone
  N=$((N+1)); D="$TMPROOT/f$N"; mkdir -p "$D"
  $GIT init -q --bare "$D/origin.git"
  $GIT clone -q "$D/origin.git" "$D/project" 2>/dev/null
  P="$D/project"
  $GIT -C "$P" checkout -q -b main
  echo a > "$P/a"; $GIT -C "$P" add a; $GIT -C "$P" commit -q -m init
  $GIT -C "$P" push -q origin main
  $GIT -C "$P" checkout -q -b feat; echo f > "$P/f"; $GIT -C "$P" add f
  $GIT -C "$P" commit -q -m feat; $GIT -C "$P" push -q origin feat
  $GIT -C "$P" checkout -q main
  mkdir -p "$P/.claude/worktrees"
  WT="$P/.claude/worktrees/feat"
  $GIT -C "$P" worktree add -q "$WT" feat
  $GIT clone -q -b feat "$D/origin.git" "$D/other" 2>/dev/null; O="$D/other"
}
push_other() {  # push_other <branch> <file>
  $GIT -C "$O" checkout -q "$1" 2>/dev/null || $GIT -C "$O" checkout -q -b "$1" "origin/$1"
  echo x > "$O/$2"; $GIT -C "$O" add "$2"; $GIT -C "$O" commit -q -m "$2"; $GIT -C "$O" push -q origin "$1"
}

setup
run --base main
check "in sync: rc/state/ff" "0/in-sync/no" "$RC/$(key ORIGIN_STATE)/$(key FAST_FORWARDED)"
check "in sync: head before=after" "$(key HEAD_BEFORE)" "$(key HEAD_AFTER)"
check "base head reported" "$($GIT -C "$P" rev-parse origin/main)" "$(key BASE_HEAD)"

# remote push between rounds -> detected and fast-forwarded
push_other feat g.txt
BEFORE="$($GIT -C "$WT" rev-parse HEAD)"
run --base main
check "remote push: ff rc/outcome" "0/applied/yes" "$RC/$(key OUTCOME)/$(key FAST_FORWARDED)"
check "remote push: head before reported" "$BEFORE" "$(key HEAD_BEFORE)"
check "remote push: head after = origin" "$($GIT -C "$WT" rev-parse origin/feat)" "$(key HEAD_AFTER)"
[ -f "$WT/g.txt" ] && ok "remote push: worktree updated" || bad "worktree not updated"

# behind + dirty tree -> reported, not moved
push_other feat h.txt
echo dirty >> "$WT/f"
run --base main
check "dirty behind: rc/state/ff/dirty" "0/behind/no/yes" "$RC/$(key ORIGIN_STATE)/$(key FAST_FORWARDED)/$(key DIRTY)"
check "dirty behind: head unmoved" "$(key HEAD_BEFORE)" "$(key HEAD_AFTER)"
$GIT -C "$WT" checkout -q -- f
run --base main --no-ff
check "--no-ff: reports behind, no move" "0/behind/no" "$RC/$(key ORIGIN_STATE)/$(key FAST_FORWARDED)"

# diverged -> stop (exit 10), heads still reported, no merge
echo local > "$WT/l.txt"; $GIT -C "$WT" add l.txt; $GIT -C "$WT" commit -q -m local
LOCAL="$($GIT -C "$WT" rev-parse HEAD)"
run --base main
check "diverged: rc/state" "10/diverged" "$RC/$(key ORIGIN_STATE)"
check "diverged: head untouched" "$LOCAL" "$($GIT -C "$WT" rev-parse HEAD)"
case "$ERR" in *diverged*) ok "diverged: stderr reason" ;; *) bad "diverged stderr: $ERR" ;; esac
check "diverged: heads still emitted" "$LOCAL" "$(key HEAD_BEFORE)"

# ahead of origin, base ahead
setup
push_other main m.txt
run --base main
check "base ahead: count" "1" "$(key BASE_AHEAD)"
check "base ahead: not merged" "in-sync/no" "$(key ORIGIN_STATE)/$(key FAST_FORWARDED)"
echo n > "$WT/n"; $GIT -C "$WT" add n; $GIT -C "$WT" commit -q -m n
run --base main
check "ahead of origin" "0/ahead/1" "$RC/$(key ORIGIN_STATE)/$(key ORIGIN_AHEAD)"

# base defaults to what lore-orient stored in <git-dir>/squad-base, else main
printf 'develop\n' > "$($GIT -C "$WT" rev-parse --absolute-git-dir)/squad-base"
run
check "stored base used" "develop" "$(key BASE)"
rm -f "$($GIT -C "$WT" rev-parse --absolute-git-dir)/squad-base"
run
check "default base is main (not origin/HEAD)" "main" "$(key BASE)"

# no upstream branch, usage, fetch failure, stdout contract
$GIT -C "$WT" checkout -q -b local-only
run --base main
check "no upstream" "0/no-upstream" "$RC/$(key ORIGIN_STATE)"
run --bogus
check "usage: exit 2" "2" "$RC"
$GIT -C "$P" remote set-url origin "$D/missing.git"
run --base main
check "fetch failure: exit 20" "20" "$RC"
check "fetch failure: empty stdout" "" "$OUT"

# fetch is bounded: a hanging git fetch is killed and reported as rc 20
setup
mkdir -p "$TMPROOT/shim"
REALGIT="$(command -v git)"
printf '#!/bin/sh\ncase " $* " in *" fetch "*) sleep 30 ;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$TMPROOT/shim/git"
chmod +x "$TMPROOT/shim/git"
T0=$(date +%s)
OUT="$(cd "$WT" && PATH="$TMPROOT/shim:$PATH" SQUAD_FETCH_TIMEOUT=1 bash "$SUT" check --base main 2>/dev/null)"; RC=$?
T1=$(date +%s)
check "slow fetch: rc 20" "20" "$RC"
[ $((T1 - T0)) -lt 15 ] && ok "slow fetch: bounded" || bad "slow fetch took $((T1 - T0))s"

# hook: silent outside a worktree, notes inside, routine note deduped, STOP repeated
setup
HOUT="$(cd "$P" && CLAUDE_PROJECT_DIR="$P" bash "$HOOK")"; check "hook: silent in main checkout" "" "$HOUT"
HOUT="$(cd /; CLAUDE_PROJECT_DIR="$TMPROOT" bash "$HOOK")"; check "hook: silent outside repo" "" "$HOUT"
HOUT="$(CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")"
case "$HOUT" in *"Worktree preflight"*in-sync*) ok "hook: note inside worktree" ;; *) bad "hook note: $HOUT" ;; esac
HOUT="$(CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")"; check "hook: deduped when unchanged" "" "$HOUT"
push_other feat z.txt
HOUT="$(CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")"
case "$HOUT" in *"Fast-forwarded"*) ok "hook: reports remote push" ;; *) bad "hook push: $HOUT" ;; esac
echo l > "$WT/l"; $GIT -C "$WT" add l; $GIT -C "$WT" commit -q -m l; push_other feat y.txt
HOUT="$(CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")"
case "$HOUT" in *STOP*) ok "hook: diverged says STOP" ;; *) bad "hook diverged: $HOUT" ;; esac
HOUT="$(CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")"
case "$HOUT" in *STOP*) ok "hook: STOP repeats on the next prompt" ;; *) bad "hook STOP not repeated: $HOUT" ;; esac
case "$HOUT" in *"head <before>"*) ok "hook: round-report rule in note" ;; *) bad "hook report rule: $HOUT" ;; esac

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
