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

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
