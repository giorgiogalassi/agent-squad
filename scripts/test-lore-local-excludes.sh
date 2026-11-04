#!/usr/bin/env bash
# Tests #455: local-only state (checkpoint log, .decisions-lint, sessions/, graph-cache.json,
# inbox) is excluded through the common .git/info/exclude, so the checkout and the session
# worktree stay clean; committed working state stays trackable. Fixture vaults, stub `lore` push, temp HOME.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-local-excludes TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1 (found [$2] in [$3])" ;; *) ok "$1" ;; esac; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
export SQUAD_INCIDENTS=off HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Hooks copy whose `lore` records `push` and delegates everything else to the real one.
H="$TMP/hooks"; mkdir -p "$H" "$TMP/fakebin"
cp "$REPO_ROOT"/claude/hooks/* "$H/" 2>/dev/null
mv "$H/lore" "$H/lore-real"
CALLS="$TMP/lore-calls"
cat > "$H/lore" <<STUB
#!/bin/sh
if [ "\$1" = push ]; then echo "\$*" >> "$CALLS"; exit 0; fi
exec bash "$H/lore-real" "\$@"
STUB
chmod +x "$H/lore"
printf '#!/bin/sh\nexit 1\n' > "$TMP/fakebin/claude"; chmod +x "$TMP/fakebin/claude"
export PATH="$TMP/fakebin:$PATH"

mkenv() {  # mkenv <name> <with-status:0|1>: PR-mode vault + origin + mapped project + session worktree
  local n="$1" ws="$2"
  V="$TMP/$n/vault"; P="$TMP/$n/roma"; mkdir -p "$V" "$P"
  git init -q --bare -b main "$TMP/$n/origin.git"
  git -C "$V" init -q -b main; git -C "$V" remote add origin "$TMP/$n/origin.git"
  printf '{"vault_main": "pr"}\n' > "$V/lore-config.json"
  echo seed > "$V/seed.md"; git -C "$V" add -A; git -C "$V" commit -qm init; git -C "$V" push -q origin main
  git -C "$P" init -q -b main; git -C "$P" commit -q --allow-empty -m init
  export SECOND_BRAIN_PATH="$V"
  ( cd "$P" && bash "$H/lore-real" map --name roma ) >/dev/null 2>&1
  WT="$(cd "$P" && bash "$H/lore-real" root | sed -n 's/^ROOT=//p')"
  mkdir -p "$WT/projects/roma"
  echo "decisions" > "$WT/projects/roma/decisions.md"
  if [ "$ws" = 1 ]; then
    printf -- '---\ntitle: s\n---\n# Status\nLast updated: 2099-01-01 00:00 by x\n\n## Goal\nWorktree goal\n\n## Last checkpoint\n\n## Context refs\n' > "$WT/projects/roma/status.md"
  fi
  ( cd "$P" && bash "$H/lore-real" commit --project roma --message "[seed] roma" --paths projects/roma ) >/dev/null 2>&1
  rm -f "$CALLS"
}
session_end() { printf '{"cwd":"%s"}' "$P" | bash "$H/lore-checkpoint.sh" >/dev/null 2>&1; sleep 1.5; }

# a run that skips (no status.md) leaves the log; the checkout still shows nothing
mkenv zero 0
session_end
[ -s "$V/projects/roma/.lore-checkpoint.log" ] && ok "checkpoint log still written" || bad "checkpoint log not written"
check "checkout status empty after SessionEnd (no .gitignore)" "" "$(git -C "$V" status --porcelain)"
mkenv one 1
session_end
check "checkout status empty after a full SessionEnd" "" "$(git -C "$V" status --porcelain)"
S="$WT/projects/roma/.lore"; mkdir -p "$S/sessions" "$S/inbox/.claimed-1"
echo x > "$S/graph-cache.json"; echo h > "$S/sessions/abc"; echo e > "$S/inbox/.claimed-1/a.ev"
echo l > "$WT/projects/roma/.decisions-lint"; echo l > "$WT/projects/roma/.lore-checkpoint.log"
check "worktree status empty with local-only state" "" "$(git -C "$WT" status --porcelain)"
# committed working state stays trackable
for f in progress.txt ralph-run.md session.log status.md .lore/graph-timeline.jsonl; do
  mkdir -p "$(dirname "$WT/projects/roma/$f")"; echo c >> "$WT/projects/roma/$f"
  git -C "$WT" check-ignore -q "projects/roma/$f" && bad "$f must stay trackable" || ok "$f stays trackable"
done
# idempotent: a second SessionEnd adds no duplicate rule
n1="$(wc -l < "$(git -C "$V" rev-parse --absolute-git-dir)/info/exclude")"; session_end
n2="$(wc -l < "$(git -C "$V" rev-parse --absolute-git-dir)/info/exclude")"
check "installer is idempotent" "$n1" "$n2"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
