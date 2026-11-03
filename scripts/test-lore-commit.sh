#!/usr/bin/env bash
# Tests claude/hooks/lore (#422): the lore dispatcher and its single vault
# committer, plus lint check 13 (nobody else commits to the vault).
# Plain bash 3.2; fixture vaults only.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-commit TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
export SQUAD_INCIDENTS=off
LORE="$REPO_ROOT/claude/hooks/lore"
[ -f "$LORE" ] || { bad "claude/hooks/lore exists"; echo "$PASS passed, $FAIL failed"; exit 1; }

mkvault() {  # mkvault <dir>
  mkdir -p "$1/projects/p"
  git -C "$1" init -q
  git -C "$1" config user.name t; git -C "$1" config user.email t@t
  echo seed > "$1/seed.md"; git -C "$1" add -A; git -C "$1" commit -qm init
}

# version verb
out="$(bash "$LORE" version)"; rc=$?
check "version exits 0" 0 "$rc"
has "version emits VERSION" "VERSION=" "$out"
bash "$LORE" nope >/dev/null 2>&1; check "unknown verb exits 2" 2 "$?"
bash "$LORE" commit --vault "$TMP" >/dev/null 2>&1; check "commit without paths exits 2" 2 "$?"

# plain commit
V="$TMP/v1"; mkvault "$V"
echo one > "$V/projects/p/a.md"
out="$(bash "$LORE" commit --vault "$V" --project p --message "[lore] test a" --paths projects/p/a.md 2>&1)"; rc=$?
check "commit exits 0" 0 "$rc"
has "commit emits applied" "OUTCOME=applied" "$out"
check "commit subject" "[lore] test a" "$(git -C "$V" log -1 --format=%s)"
check "lock released" "no" "$([ -e "$V/.git/lore.lock" ] && echo yes || echo no)"
out="$(bash "$LORE" commit --vault "$V" --project p --message "[lore] again" --paths projects/p/a.md 2>&1)"
has "nothing to commit is unchanged" "OUTCOME=unchanged" "$out"

# two commits started together
V="$TMP/v2"; mkvault "$V"
echo a > "$V/projects/p/a.md"; echo b > "$V/projects/p/b.md"
bash "$LORE" commit --vault "$V" --project p --message "[lore] A" --paths projects/p/a.md >/dev/null 2>"$TMP/e1" &
P1=$!
bash "$LORE" commit --vault "$V" --project p --message "[lore] B" --paths projects/p/b.md >/dev/null 2>"$TMP/e2" &
P2=$!
wait $P1; r1=$?; wait $P2; r2=$?
check "concurrent commits both exit 0" "0 0" "$r1 $r2"
check "both paths committed" "" "$(git -C "$V" status --porcelain)"
check "two commits on top of init" 3 "$(git -C "$V" rev-list --count HEAD)"
check "no index.lock error" 0 "$(cat "$TMP/e1" "$TMP/e2" | grep -c 'index.lock')"

# stale lock: dead pid
V="$TMP/v3"; mkvault "$V"
echo x > "$V/projects/p/a.md"
mkdir "$V/.git/lore.lock"
printf 'PID=999999\nAT=%s\n' "$(date +%s)" > "$V/.git/lore.lock/owner"
out="$(bash "$LORE" commit --vault "$V" --project p --message "[lore] stale" --paths projects/p/a.md 2>"$TMP/err")"; rc=$?
check "dead-pid lock: exit 0" 0 "$rc"
has "dead-pid lock: stderr notice" "stale" "$(cat "$TMP/err")"
check "dead-pid lock: committed" "[lore] stale" "$(git -C "$V" log -1 --format=%s)"

# stale lock: live pid but older than 10 minutes
V="$TMP/v4"; mkvault "$V"
echo x > "$V/projects/p/a.md"
sleep 30 & HOLDER=$!
mkdir "$V/.git/lore.lock"
printf 'PID=%s\nAT=%s\n' "$HOLDER" "$(( $(date +%s) - 700 ))" > "$V/.git/lore.lock/owner"
bash "$LORE" commit --vault "$V" --project p --message "[lore] old" --paths projects/p/a.md >/dev/null 2>"$TMP/err"; rc=$?
check "old lock: exit 0" 0 "$rc"
has "old lock: stderr notice" "stale" "$(cat "$TMP/err")"
check "old lock: committed" "[lore] old" "$(git -C "$V" log -1 --format=%s)"

# live lock under 10 minutes: bounded wait, exit 20, nothing committed
V="$TMP/v5"; mkvault "$V"
echo x > "$V/projects/p/a.md"
mkdir "$V/.git/lore.lock"
printf 'PID=%s\nAT=%s\n' "$HOLDER" "$(date +%s)" > "$V/.git/lore.lock/owner"
LORE_LOCK_WAIT=2 bash "$LORE" commit --vault "$V" --project p --message "[lore] blocked" --paths projects/p/a.md >/dev/null 2>"$TMP/err"; rc=$?
check "live lock: exit 20" 20 "$rc"
check "live lock: not committed" "init" "$(git -C "$V" log -1 --format=%s)"
check "live lock: lock kept" yes "$([ -d "$V/.git/lore.lock" ] && echo yes || echo no)"
kill "$HOLDER" 2>/dev/null

# ownerless lock (holder between mkdir and writing owner): not stale while fresh
V="$TMP/v6"; mkvault "$V"
echo x > "$V/projects/p/a.md"
mkdir "$V/.git/lore.lock"
LORE_LOCK_WAIT=2 bash "$LORE" commit --vault "$V" --project p --message "[lore] fresh" --paths projects/p/a.md >/dev/null 2>&1; rc=$?
check "fresh ownerless lock: exit 20" 20 "$rc"
check "fresh ownerless lock: kept" yes "$([ -d "$V/.git/lore.lock" ] && echo yes || echo no)"
touch -t 202001010000 "$V/.git/lore.lock"
bash "$LORE" commit --vault "$V" --project p --message "[lore] old ownerless" --paths projects/p/a.md >/dev/null 2>&1; rc=$?
check "old ownerless lock: broken, exit 0" 0 "$rc"
check "old ownerless lock: committed" "[lore] old ownerless" "$(git -C "$V" log -1 --format=%s)"

# break race: a waiter that observed a stale lock must not remove a fresh live lock swapped in meanwhile
V="$TMP/v7"; mkvault "$V"
echo x > "$V/projects/p/a.md"
sleep 30 & HOLDER2=$!
mkdir "$V/.git/lore.lock"
printf 'PID=999999\nAT=%s\n' "$(date +%s)" > "$V/.git/lore.lock/owner"
LORE_TEST_BREAK_DELAY=3 LORE_LOCK_WAIT=1 bash "$LORE" commit --vault "$V" --project p --message "[lore] race" --paths projects/p/a.md >/dev/null 2>"$TMP/err" &
WP=$!
sleep 1
rm -rf "$V/.git/lore.lock"; mkdir "$V/.git/lore.lock"
printf 'PID=%s\nAT=%s\n' "$HOLDER2" "$(date +%s)" > "$V/.git/lore.lock/owner"
wait $WP; rc=$?
check "break race: waiter times out (exit 20)" 20 "$rc"
check "break race: live holder's lock intact" "PID=$HOLDER2" "$(sed -n 1p "$V/.git/lore.lock/owner" 2>/dev/null)"
check "break race: not committed" "init" "$(git -C "$V" log -1 --format=%s)"
kill "$HOLDER2" 2>/dev/null

# one lock for every checkout of the vault (linked worktree)
V="$TMP/v8"; mkvault "$V"
# the worktree sits on the default branch (a direct-mode vault refuses other branches, #422)
dflt="$(git -C "$V" symbolic-ref --short HEAD)"; git -C "$V" switch -qc side
git -C "$V" worktree add -q "$TMP/v8wt" "$dflt"
mkdir -p "$TMP/v8wt/projects/p"; echo x > "$TMP/v8wt/projects/p/a.md"
mkdir "$V/.git/lore.lock"
sleep 30 & HOLDER3=$!
printf 'PID=%s\nAT=%s\n' "$HOLDER3" "$(date +%s)" > "$V/.git/lore.lock/owner"
LORE_LOCK_WAIT=1 bash "$LORE" commit --vault "$TMP/v8wt" --project p --message "[lore] wt" --paths projects/p/a.md >/dev/null 2>&1; rc=$?
check "linked worktree shares the main lock (exit 20)" 20 "$rc"
kill "$HOLDER3" 2>/dev/null; rm -rf "$V/.git/lore.lock"
bash "$LORE" commit --vault "$TMP/v8wt" --project p --message "[lore] wt" --paths projects/p/a.md >/dev/null 2>&1
check "linked worktree commits when free" "[lore] wt" "$(git -C "$TMP/v8wt" log -1 --format=%s)"
check "linked worktree leaves no lock in its own git dir" 0 "$(ls "$V/.git/worktrees/v8wt" | grep -c lore.lock)"

# release only our own lock
V="$TMP/v9"; mkvault "$V"
echo x > "$V/projects/p/a.md"
LORE_TEST_RELEASE_SWAP=1 bash "$LORE" commit --vault "$V" --project p --message "[lore] rel" --paths projects/p/a.md >/dev/null 2>&1
check "release keeps a newer holder's lock" "PID=424242" "$(sed -n 1p "$V/.git/lore.lock/owner" 2>/dev/null)"

# writers commit through lore: no direct commit in the scripts
for s in lore-decide lore-map vault-check batch-audit lore-journal-pointer vault-pr; do
  n="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/claude/hooks/$s.sh" | grep -cE 'squad_vault_commit|git .*(commit|push)')"
  check "$s.sh has no direct vault commit" 0 "$n"
  has "$s.sh calls lore commit" "lore" "$(grep -E 'lore" commit|LORE.* commit' "$REPO_ROOT/claude/hooks/$s.sh" | head -1)"
done

# lint check 13
fixture() {
  mkdir -p "$1/scripts"
  cp -R "$REPO_ROOT/claude" "$1/claude"
  cp "$REPO_ROOT/scripts/lint-allowlist-1b.txt" "$REPO_ROOT/scripts/test-squad-labels.sh" "$1/scripts/"
  cp -R "$REPO_ROOT/scripts/lib" "$1/scripts/lib"
  cp "$REPO_ROOT"/*.md "$1/" 2>/dev/null
  return 0
}
c13() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$1" 2>&1 | sed -n '/== 13/,/== summary/p'; }
fixture "$TMP/l1"
c13 "$TMP/l1" | grep -q '\[FAIL\]' && bad "pristine copy passes check 13" || ok "pristine copy passes check 13"
c13 "$TMP/l1" | grep -q '== 13' && ok "check 13 exists" || bad "check 13 exists"
fixture "$TMP/l2"
printf '#!/usr/bin/env bash\ngit -C "$VAULT" commit -q -m x -- f\n' > "$TMP/l2/claude/hooks/rogue.sh"
c13 "$TMP/l2" | grep -q 'rogue.sh' && ok "git commit against the vault is reported" || bad "git commit against the vault is reported"
bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$TMP/l2" >/dev/null 2>&1 && bad "rogue committer exits non-zero" || ok "rogue committer exits non-zero"
fixture "$TMP/l3"
printf '#!/usr/bin/env bash\nsquad_vault_commit "$V" p msg f\n' > "$TMP/l3/claude/hooks/rogue2.sh"
c13 "$TMP/l3" | grep -q 'rogue2.sh' && ok "squad_vault_commit caller is reported" || bad "squad_vault_commit caller is reported"

# vault checkout on another session's branch (#422): never commit there
D="$(date +%Y-%m-%d)"
mkvault_pr() {  # mkvault_pr <dir> <branch-to-checkout>
  mkvault "$1"; git -C "$1" branch -M main
  printf '{"vault_main": "pr"}\n' > "$1/lore-config.json"
  git -C "$1" add -A; git -C "$1" commit -qm cfg
  echo base > "$1/projects/p/progress.txt"; git -C "$1" add -A; git -C "$1" commit -qm prog
  git -C "$1" switch -qc "$2"
}
V="$TMP/o1"; mkvault_pr "$V" lore/other-2026-11-03
other="$(git -C "$V" rev-parse HEAD)"
echo more >> "$V/projects/p/progress.txt"
out="$(bash "$LORE" commit --vault "$V" --project p --message "[lore] off main" --paths projects/p/progress.txt 2>&1)"; rc=$?
check "off-main PR vault: exit 0" 0 "$rc"
check "off-main PR vault: checkout branch unchanged" "$other" "$(git -C "$V" rev-parse lore/other-2026-11-03)"
check "off-main PR vault: still on the other branch" "lore/other-2026-11-03" "$(git -C "$V" symbolic-ref --short HEAD)"
check "off-main PR vault: commit on the project session branch" "[lore] off main" "$(git -C "$V" log -1 --format=%s "lore/p-$D")"
check "off-main PR vault: session branch based on main" "prog" "$(git -C "$V" log -1 --skip=1 --format=%s "lore/p-$D")"
check "off-main PR vault: checkout working copy matches its branch" "" "$(git -C "$V" status --porcelain --untracked-files=no)"

V="$TMP/o2"; mkvault "$V"; git -C "$V" branch -M main
printf '{"vault_main": "direct"}\n' > "$V/lore-config.json"; git -C "$V" add -A; git -C "$V" commit -qm cfg
git -C "$V" switch -qc feature/x; head1="$(git -C "$V" rev-parse HEAD)"
echo x > "$V/projects/p/a.md"
bash "$LORE" commit --vault "$V" --project p --message "[lore] no" --paths projects/p/a.md >/dev/null 2>"$TMP/err"; rc=$?
check "off-main direct vault: exit 10" 10 "$rc"
has "off-main direct vault: reason names the branch" "feature/x" "$(cat "$TMP/err")"
check "off-main direct vault: no commit on the branch" "$head1" "$(git -C "$V" rev-parse HEAD)"
check "off-main direct vault: no lore branch" "" "$(git -C "$V" branch --list 'lore/*')"

# detect via pre-push hook evaluates the default branch, not the current one
V="$TMP/o3"; mkvault "$V"; git -C "$V" branch -M main
printf '#!/bin/sh\nwhile read l s r t; do [ "$r" = refs/heads/main ] && exit 1; done\nexit 0\n' > "$V/.git/hooks/pre-push"; chmod +x "$V/.git/hooks/pre-push"
git -C "$V" switch -qc lore/other-2026-11-03
echo x > "$V/projects/p/a.md"
bash "$LORE" commit --vault "$V" --project p --message "[lore] detect" --paths projects/p/a.md >/dev/null 2>&1; rc=$?
check "off-main detected PR vault: exit 0" 0 "$rc"
check "off-main detected PR vault: committed on session branch" "[lore] detect" "$(git -C "$V" log -1 --format=%s "lore/p-$D")"
check "off-main detected PR vault: other branch untouched" "init" "$(git -C "$V" log -1 --format=%s lore/other-2026-11-03)"

# on main: unchanged (PR mode commits on the session branch, direct on main)
V="$TMP/o4"; mkvault_pr "$V" main-tmp; git -C "$V" switch -q main
echo y >> "$V/projects/p/progress.txt"
bash "$LORE" commit --vault "$V" --project p --message "[lore] on main pr" --paths projects/p/progress.txt >/dev/null 2>&1
check "on main PR vault: session branch commit" "[lore] on main pr" "$(git -C "$V" log -1 --format=%s "lore/p-$D")"
check "on main PR vault: main untouched" "prog" "$(git -C "$V" log -1 --format=%s main)"
V="$TMP/o5"; mkvault "$V"; git -C "$V" branch -M main
echo y > "$V/projects/p/a.md"
bash "$LORE" commit --vault "$V" --project p --message "[lore] on main direct" --paths projects/p/a.md >/dev/null 2>&1
check "on main direct vault: commit on main" "[lore] on main direct" "$(git -C "$V" log -1 --format=%s main)"

# dirty checkout off main: the other session's edit survives and is not committed (#422)
V="$TMP/o6"; mkvault_pr "$V" lore/other-2026-11-03
echo "other wip" >> "$V/projects/p/progress.txt"        # other session's uncommitted edit
mkdir -p "$V/.claude/worktrees"
wt="$(. "$REPO_ROOT/claude/hooks/squad-common.sh"; squad_vault_wroot "$V" p)"
echo "ours" >> "$wt/projects/p/progress.txt"
bash "$LORE" commit --vault "$V" --project p --message "[lore] dirty" --paths projects/p/progress.txt >/dev/null 2>&1
check "dirty off-main: other session's edit survives" "other wip" "$(tail -1 "$V/projects/p/progress.txt")"
check "dirty off-main: their edit not in our commit" 0 "$(git -C "$V" show "lore/p-$D:projects/p/progress.txt" | grep -c 'other wip')"
check "dirty off-main: our edit committed" "ours" "$(git -C "$V" show "lore/p-$D:projects/p/progress.txt" | tail -1)"

# a vault whose default branch is not main/master still commits there (origin/HEAD)
V="$TMP/o7"; mkvault "$V"; git -C "$V" branch -M trunk
git init -q --bare -b trunk "$TMP/o7-origin.git"; git -C "$V" remote add origin "$TMP/o7-origin.git"
git -C "$V" push -q -u origin trunk 2>/dev/null; git -C "$V" remote set-head origin trunk >/dev/null 2>&1
echo y > "$V/projects/p/a.md"
bash "$LORE" commit --vault "$V" --project p --message "[lore] on trunk" --paths projects/p/a.md >/dev/null 2>&1; rc=$?
check "trunk default: exit 0" 0 "$rc"
check "trunk default: commit on trunk" "[lore] on trunk" "$(git -C "$V" log -1 --format=%s trunk)"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
