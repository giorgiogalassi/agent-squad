#!/usr/bin/env bash
# Tests #467: squad_vault_wt skips a lore/* branch whose PR was closed
# without merging (next suffix, based on origin/main), keeps an open-PR branch, and
# behaves as before without gh. Fixture vault + bare origin, fake `gh` by PR state.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-vault-closed-pr TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/gh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
SAFE_PATH="$PATH"
export GHLOG="$TMP/gh.log"; : > "$GHLOG"

# Fake gh: the first branch's PR state comes from $GHSTATE (open|closed|none); -N branches have no PR.
cat > "$TMP/gh/gh" <<'GH'
#!/bin/sh
echo "$*" >> "$GHLOG"
state=""; head=""
while [ $# -gt 0 ]; do [ "$1" = --state ] && state="$2"; [ "$1" = --head ] && head="$2"; shift; done
case "$head" in *-2|*-3) exit 0 ;; esac
[ "$state" = "$GHSTATE" ] && echo 7
exit 0
GH
chmod +x "$TMP/gh/gh"

D="$(date +%Y-%m-%d)"
mkenv() {  # mkenv <n>: vault with origin and a session worktree for project p holding a commit
  V="$TMP/$1/vault"; mkdir -p "$V"
  git init -q --bare -b main "$TMP/$1/origin.git"
  git -C "$V" init -q -b main; git -C "$V" remote add origin "$TMP/$1/origin.git"
  echo seed > "$V/seed.md"; git -C "$V" add -A; git -C "$V" commit -qm init; git -C "$V" push -q origin main
  git -C "$V" worktree add -q -b "lore/p-$D" "$V/.claude/worktrees/lore-p-$D" main
  ( cd "$V/.claude/worktrees/lore-p-$D" && echo rejected > r.md && git add r.md && git commit -qm rejected )
}
resolve() {  # resolve <gh-on-path:0|1>
  local pth="$SAFE_PATH"; [ "$1" = 1 ] && pth="$TMP/gh:$SAFE_PATH"
  PATH="$pth" bash -c '. "$1/claude/hooks/squad-common.sh"; squad_public_name() { printf p; }; squad_vault_level() { :; }; squad_vault_wt "$2" p' _ "$REPO_ROOT" "$V" 2>"$TMP/err"
}

mkenv closed; export GHSTATE=closed
o="$(resolve 1)"
check "closed unmerged PR: next suffix" "$V/.claude/worktrees/lore-p-$D-2" "$o"
check "new branch has none of the rejected commits" "0" "$(git -C "$V" rev-list --count origin/main..lore/p-$D-2)"
[ -d "$V/.claude/worktrees/lore-p-$D" ] && git -C "$V" show-ref -q --verify "refs/heads/lore/p-$D" && ok "old branch and worktree left in place" || bad "old branch/worktree removed"
check "one stderr notice naming the branch" "1" "$(grep -c "lore/p-$D " "$TMP/err")"
o2="$(resolve 1)"
check "second resolve reuses the new branch" "$V/.claude/worktrees/lore-p-$D-2" "$o2"

mkenv open; export GHSTATE=open
check "open PR: branch reused" "$V/.claude/worktrees/lore-p-$D" "$(resolve 1)"

mkenv nogh; export GHSTATE=closed
check "no gh: branch reused, no error" "$V/.claude/worktrees/lore-p-$D" "$(resolve 0)"
[ ! -s "$TMP/err" ] && ok "no gh: nothing on stderr" || bad "no gh: stderr [$(cat "$TMP/err")]"

# squad_vault_finish after a closed-PR resolve: b is neither pushed nor re-PR'd nor
# dropped; b-2 (with a commit) is pushed and gets its PR. The notice appears once.
mkenv fin; export GHSTATE=closed
printf '{"vault_main": "pr"}\n' > "$V/lore-config.json"
resolve 1 >/dev/null
( cd "$V/.claude/worktrees/lore-p-$D-2" && echo new > n.md && git add n.md && git commit -qm new )
: > "$GHLOG"
fin() { PATH="$TMP/gh:$SAFE_PATH" bash -c '. "$1/claude/hooks/squad-common.sh"; squad_vault_finish "$2"' _ "$REPO_ROOT" "$V" 2>"$TMP/ferr"; }
fin
check "finish: no PR create for the closed branch" "0" "$(grep -c "pr create --head lore/p-$D --" "$GHLOG")"
check "finish: PR create for the new branch" "1" "$(grep -c "pr create --head lore/p-$D-2 " "$GHLOG")"
git -C "$V" show-ref -q --verify "refs/remotes/origin/lore/p-$D-2" && ok "finish: new branch pushed" || bad "finish: new branch not pushed"
git -C "$V" show-ref -q --verify "refs/remotes/origin/lore/p-$D" && bad "finish: closed branch pushed" || ok "finish: closed branch not pushed"
[ -d "$V/.claude/worktrees/lore-p-$D" ] && git -C "$V" show-ref -q --verify "refs/heads/lore/p-$D" && ok "finish: closed branch kept" || bad "finish: closed branch dropped"
check "no second notice at finish or on later calls" "0" "$(grep -c "lore/p-$D " "$TMP/ferr")"
resolve 1 >/dev/null
check "later resolve is silent" "0" "$(grep -c 'closed without merging' "$TMP/err")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
