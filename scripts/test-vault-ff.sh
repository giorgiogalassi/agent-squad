#!/usr/bin/env bash
# Tests #460: SessionStart fast-forwards a PR-mode vault checkout (squad_vault_ff via
# lore-orient.sh), and vault-check.sh reads INDEX.md and the mapping through the read
# owners. Plain bash 3.2; every vault is a fixture under the test temp dir.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-vault-ff
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in [$3])" ;; *) ok "$1" ;; esac; }

export SQUAD_INCIDENTS=off GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset SECOND_BRAIN_PATH SQUAD_VAULT_PATH SQUAD_PROJECT_ROOT
mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{lore,vault-check.sh,decisions-lint.sh,lore-orient.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
H="$TMPROOT/hooks"

# mkfix <name> <mode>: bare origin + vault checkout (clean, on main, initial commit)
# + a second clone used to push commits to origin.
mkfix() {
  local n="$1" mode="$2" d="$TMPROOT/$1"
  mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/vault" 2>/dev/null
  git -C "$d/vault" checkout -q -b main 2>/dev/null
  mkdir -p "$d/vault/projects/p"
  printf '{"vault_main":"%s","projects":{}}\n' "$mode" > "$d/vault/lore-config.json"
  echo init > "$d/vault/projects/p/status.md"
  git -C "$d/vault" add -A; git -C "$d/vault" commit -q -m init
  git -C "$d/vault" push -q -u origin main 2>/dev/null
  git clone -q "$d/origin.git" "$d/other" 2>/dev/null
  echo "$d"
}
# advance <fixdir>: two commits on origin/main.
advance() {
  echo a > "$1/other/a.md"; git -C "$1/other" add -A; git -C "$1/other" commit -q -m a
  echo b > "$1/other/b.md"; git -C "$1/other" add -A; git -C "$1/other" commit -q -m b
  git -C "$1/other" push -q origin main 2>/dev/null
}
# session <fixdir>: run the SessionStart orientation; stderr goes to $d/err.
session() {
  ( cd "$TMPROOT" && SECOND_BRAIN_PATH="$1/vault" bash "$H/lore-orient.sh" >/dev/null 2>"$1/err" </dev/null )
}

# 1. clean checkout on main, origin ahead: fast-forwarded.
d="$(mkfix ff pr)"; advance "$d"
session "$d"
check "pr mode, clean: main equals origin/main" "$(git -C "$d/origin.git" rev-parse main)" "$(git -C "$d/vault" rev-parse main)"
check "pr mode, clean: no notice" "" "$(cat "$d/err")"

# 2. dirty checkout: untouched, one notice.
d="$(mkfix dirty pr)"; advance "$d"
echo changed >> "$d/vault/projects/p/status.md"
head0="$(git -C "$d/vault" rev-parse HEAD)"; st0="$(git -C "$d/vault" status --porcelain)"; wt0="$(cat "$d/vault/projects/p/status.md")"
session "$d"
check "dirty: HEAD unchanged" "$head0" "$(git -C "$d/vault" rev-parse HEAD)"
check "dirty: status unchanged" "$st0" "$(git -C "$d/vault" status --porcelain)"
check "dirty: working tree unchanged" "$wt0" "$(cat "$d/vault/projects/p/status.md")"
has "dirty: stderr names the skipped fast-forward" "fast-forward skipped" "$(cat "$d/err")"
check "dirty: exactly one notice" 1 "$(grep -c . "$d/err")"

# 3. other branch: nothing moves.
d="$(mkfix other pr)"; advance "$d"
git -C "$d/vault" checkout -q -b lore/someone-else
head0="$(git -C "$d/vault" rev-parse HEAD)"
session "$d"
check "other branch: HEAD unchanged" "$head0" "$(git -C "$d/vault" rev-parse HEAD)"
check "other branch: still on it" "lore/someone-else" "$(git -C "$d/vault" symbolic-ref --short HEAD)"
check "other branch: main not moved" "$head0" "$(git -C "$d/vault" rev-parse main)"
has "other branch: notice" "fast-forward skipped" "$(cat "$d/err")"

# 4. diverged: untouched, one notice.
d="$(mkfix div pr)"; advance "$d"
echo local > "$d/vault/local.md"; git -C "$d/vault" add -A; git -C "$d/vault" commit -q -m local
head0="$(git -C "$d/vault" rev-parse HEAD)"
session "$d"
check "diverged: HEAD unchanged" "$head0" "$(git -C "$d/vault" rev-parse HEAD)"
has "diverged: notice" "diverged" "$(cat "$d/err")"

# 5. direct and local-only: no ff attempted.
d="$(mkfix direct direct)"; advance "$d"; head0="$(git -C "$d/vault" rev-parse HEAD)"
session "$d"
check "direct: HEAD unchanged" "$head0" "$(git -C "$d/vault" rev-parse HEAD)"
check "direct: no notice" "" "$(cat "$d/err")"
d="$(mkfix lo local-only)"; advance "$d"; head0="$(git -C "$d/vault" rev-parse HEAD)"
session "$d"
check "local-only: HEAD unchanged" "$head0" "$(git -C "$d/vault" rev-parse HEAD)"

# 6. vault-check reads INDEX.md and the mapping through the session worktree.
d="$(mkfix vc pr)"; v="$d/vault"
cat > "$d/other/lore-config.json" <<'CFG'
{"vault_main":"pr","projects":{"/p":"p"}}
CFG
cat > "$d/other/INDEX.md" <<'IDX'
# Index

## Projects

| Project | Status | Last updated |
|---------|--------|--------------|
| [[projects/p/status\|p]] | active | 2026-10-25 |
IDX
git -C "$d/other" add -A; git -C "$d/other" commit -q -m idx; git -C "$d/other" push -q origin main 2>/dev/null
git -C "$v" fetch -q origin
mkdir -p "$v/.claude/worktrees"
git -C "$v" worktree add -q -b lore/p-2026-11-04 "$v/.claude/worktrees/lore-p-2026-11-04" origin/main
check "vc fixture: checkout is behind and lacks INDEX.md" "no" "$([ -f "$v/INDEX.md" ] && echo yes || echo no)"
out="$(bash "$H/vault-check.sh" check --vault "$v" --project p --vault-wide 2>&1)"
lacks "vault-check: no INDEX_FILE=missing" "INDEX_FILE=missing" "$out"
lacks "vault-check: no VAULT_PROJECT_UNMAPPED" "VAULT_PROJECT_UNMAPPED" "$out"
# Without the session worktree the same checkout does report both (the check is real).
git -C "$v" worktree remove --force "$v/.claude/worktrees/lore-p-2026-11-04"
out="$(bash "$H/vault-check.sh" check --vault "$v" --project p --vault-wide 2>&1)"
has "vault-check: stale checkout alone reports INDEX_FILE=missing" "INDEX_FILE=missing" "$out"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
