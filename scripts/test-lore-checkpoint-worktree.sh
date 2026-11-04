#!/usr/bin/env bash
# Tests #453: at SessionEnd lore-checkpoint.sh and lore-orient.sh read a PR-mode
# vault's project files from the session worktree (squad_vault_rroot), and a missing
# status.md never skips a pending push. Fixture vaults, stub `lore` push, temp HOME.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-checkpoint-worktree TMP
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
  local n="$1" ws="$2" cfg='{"vault_main": "pr"}'
  [ "${3:-}" = direct ] && cfg='{}'
  V="$TMP/$n/vault"; P="$TMP/$n/roma"; mkdir -p "$V" "$P"
  git init -q --bare -b main "$TMP/$n/origin.git"
  git -C "$V" init -q -b main; git -C "$V" remote add origin "$TMP/$n/origin.git"
  printf '%s\n' "$cfg" > "$V/lore-config.json"
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

# 1. status.md only in the session worktree: checkpointed there, no skip, push started
mkenv one 1
[ ! -e "$V/projects/roma/status.md" ] && ok "fixture: status.md not in the checkout" || bad "fixture: status.md leaked into the checkout"
# a stray dated line under Context refs is repaired in place (a write that needs the worktree copy)
printf '[2099-01-01 00:00] [x] stray\n' >> "$WT/projects/roma/status.md"
session_end
has "push started" "push --vault $V" "$(cat "$CALLS" 2>/dev/null)"
hasnt "no 'no status.md' skip logged" "no status.md" "$(cat "$V/projects/roma/.lore-checkpoint.log" 2>/dev/null)"
has "worktree status.md repaired" "## Last checkpoint
[2099-01-01 00:00] [x] stray" "$(cat "$WT/projects/roma/status.md")"
check "repair committed in the worktree" "" "$(git -C "$WT" status --porcelain -- projects/roma/status.md)"
check "checkout stays clean" "" "$(git -C "$V" status --porcelain)"

# 2. status.md nowhere: per-project work skipped, the pending push still starts
mkenv two 0
session_end
has "skip is logged" "no status.md" "$(cat "$V/projects/roma/.lore-checkpoint.log" 2>/dev/null)"
has "pending push still started" "push --vault $V" "$(cat "$CALLS" 2>/dev/null)"

# 3. orientation shows the worktree's status.md before the vault PR merges
mkenv three 1
out="$(cd "$P" && printf '{"cwd":"%s","source":"startup"}' "$P" | bash "$H/lore-orient.sh" 2>/dev/null)"
has "orientation has the worktree status" "Worktree goal" "$out"

# 4. #461: non-git mapped root -> bare checkpoint line, no empty Branch/Recent commits
mkenv four 1
rm -rf "$P/.git"
# #464: no change in the vault -> status.md byte-identical, no commit
before="$(cat "$WT/projects/roma/status.md")"; head0="$(git -C "$WT" rev-parse HEAD)"
session_end
check "non-git no-op: status.md untouched" "$before" "$(cat "$WT/projects/roma/status.md")"
check "non-git no-op: no commit" "$head0" "$(git -C "$WT" rev-parse HEAD)"
# a changed vault file -> exactly one checkpoint line, committed
echo more >> "$WT/projects/roma/decisions.md"
session_end
check "non-git write: one checkpoint line" "1" "$(grep -c '\] \[claude-code\] Session ended\.$' "$WT/projects/roma/status.md")"
check "non-git write: committed" "" "$(git -C "$WT" status --porcelain -- projects/roma/status.md)"
has "non-git: bare checkpoint line" "] [claude-code] Session ended.
" "$(cat "$WT/projects/roma/status.md" "$V/projects/roma/status.md" 2>/dev/null)"
hasnt "non-git: no branch fragment" "worktree branch" "$(cat "$WT/projects/roma/status.md" "$V/projects/roma/status.md" 2>/dev/null)"
hasnt "non-git: no double space" "  @" "$(cat "$WT/projects/roma/status.md" "$V/projects/roma/status.md" 2>/dev/null)"
out="$(cd "$P" && printf '{"cwd":"%s","source":"startup"}' "$P" | bash "$H/lore-orient.sh" 2>/dev/null)"
hasnt "non-git: orientation has no Branch: line" "Branch:" "$out"
hasnt "non-git: orientation has no Recent commits" "Recent commits:" "$out"

# 6. #464: writes committed through `lore commit` during the session, clean at SessionEnd -> one line
mkenv six 1
rm -rf "$P/.git"
sid_end() { printf '{"cwd":"%s","session_id":"%s"}' "$P" "$1" | bash "$H/lore-checkpoint.sh" >/dev/null 2>&1; sleep 1.5; }
sid_start() { ( cd "$P" && printf '{"cwd":"%s","source":"startup","session_id":"%s"}' "$P" "$1" | bash "$H/lore-orient.sh" >/dev/null 2>&1 ); }
sid_start s-noop
before="$(cat "$WT/projects/roma/status.md")"; head0="$(git -C "$WT" rev-parse HEAD)"
sid_end s-noop
check "non-git session-record no-op: status.md untouched" "$before" "$(cat "$WT/projects/roma/status.md")"
check "non-git session-record no-op: no commit" "$head0" "$(git -C "$WT" rev-parse HEAD)"
sid_start s-work
echo "note" >> "$WT/projects/roma/decisions.md"
( cd "$P" && bash "$H/lore-real" commit --project roma --message "[work] roma" --paths projects/roma ) >/dev/null 2>&1
check "committed-writes fixture: clean tree" "" "$(git -C "$WT" status --porcelain -- projects/roma)"
sid_end s-work
check "non-git committed writes: one checkpoint line" "1" "$(grep -c '\] \[claude-code\] Session ended\.$' "$WT/projects/roma/status.md")"
check "non-git committed writes: checkpoint committed" "" "$(git -C "$WT" status --porcelain -- projects/roma/status.md)"

# 7. #464 r3: resume start (no startup record) + committed writes -> one line
mkenv seven 1
rm -rf "$P/.git"
sid_start_src() { ( cd "$P" && printf '{"cwd":"%s","source":"%s","session_id":"%s"}' "$P" "$2" "$1" | bash "$H/lore-orient.sh" >/dev/null 2>&1 ); }
sid_start_src s-res resume
SD7="$(ls -d "$V"/projects/roma/.*/sessions 2>/dev/null | head -n 1)"
[ -f "$SD7/s-res.vault" ] && ok "resume writes the vault HEAD record" || bad "resume writes the vault HEAD record"
echo "note" >> "$WT/projects/roma/decisions.md"
( cd "$P" && bash "$H/lore-real" commit --project roma --message "[work] roma" --paths projects/roma ) >/dev/null 2>&1
sid_end s-res
check "resume + committed writes: one checkpoint line" "1" "$(grep -c '\] \[claude-code\] Session ended\.$' "$WT/projects/roma/status.md")"
[ ! -f "$SD7/s-res.vault" ] && ok "record removed at SessionEnd" || bad "record removed at SessionEnd"

# 8. #464 r3: fresh direct vault (no exclude entries), no-op session -> nothing written
mkenv eight 1 direct
rm -rf "$P/.git"; : > "$V/.git/info/exclude"
sid_start s-fresh
before="$(cat "$WT/projects/roma/status.md")"; head0="$(git -C "$WT" rev-parse HEAD)"
sid_end s-fresh
check "fresh vault no-op: status.md untouched" "$before" "$(cat "$WT/projects/roma/status.md")"
check "fresh vault no-op: no commit" "$head0" "$(git -C "$WT" rev-parse HEAD)"

# 9. #464 r3: early-exit paths. A bailing SessionEnd removes its record; --note keeps it.
mkenv nine 0
rm -rf "$P/.git"
sid_start s-bail
SD9="$(ls -d "$V"/projects/roma/.*/sessions 2>/dev/null | head -n 1)"
[ -f "$SD9/s-bail.vault" ] && ok "bail fixture: record present" || bad "bail fixture: record present"
( cd "$P" && bash "$H/lore-checkpoint.sh" --note "mid-session" >/dev/null 2>&1 )
[ -f "$SD9/s-bail.vault" ] && ok "--note keeps the record" || bad "--note keeps the record"
sid_end s-bail
[ ! -f "$SD9/s-bail.vault" ] && ok "early bail removes the record" || bad "early bail removes the record"

# 10. #473: first contact. The project is unmapped at SessionStart (no per-project record
# possible), mapped and written to through `lore commit` during the session -> one line.
mkfirst() {  # mkfirst <name>: PR-mode vault + origin, non-git unmapped project dir
  local n="$1"
  V="$TMP/$n/vault"; P="$TMP/$n/roma"; mkdir -p "$V" "$P"
  git init -q --bare -b main "$TMP/$n/origin.git"
  git -C "$V" init -q -b main; git -C "$V" remote add origin "$TMP/$n/origin.git"
  printf '{"vault_main": "pr"}\n' > "$V/lore-config.json"
  echo seed > "$V/seed.md"; git -C "$V" add -A; git -C "$V" commit -qm init; git -C "$V" push -q origin main
  export SECOND_BRAIN_PATH="$V"; rm -f "$CALLS"
}
seed_work() {  # map the project and write through lore commit; sets WT
  ( cd "$P" && bash "$H/lore-real" map --name roma ) >/dev/null 2>&1
  WT="$(cd "$P" && bash "$H/lore-real" root | sed -n 's/^ROOT=//p')"
  mkdir -p "$WT/projects/roma"
  printf -- '---\ntitle: s\n---\n# Status\nLast updated: 2099-01-01 00:00 by x\n\n## Goal\ng\n\n## Last checkpoint\n\n## Context refs\n' > "$WT/projects/roma/status.md"
  echo "ctx" > "$WT/projects/roma/decisions.md"
  ( cd "$P" && bash "$H/lore-real" commit --project roma --message "[seed] roma" --paths projects/roma ) >/dev/null 2>&1
}
mkfirst ten
sid_start s-first
seed_work
check "first contact fixture: clean tree" "" "$(git -C "$WT" status --porcelain -- projects/roma)"
sid_end s-first
check "first contact + lore commit: one checkpoint line" "1" "$(grep -c '\] \[claude-code\] Session ended\.$' "$WT/projects/roma/status.md")"
check "first contact: no vault-level record left" "" "$(find "$V/.git/lore-sessions" -name '*.vault' 2>/dev/null)"
[ ! -e "$V/projects/_vault" ] && ok "first contact: nothing under projects/_vault" || bad "first contact: projects/_vault exists"

# 10b. an unmapped session that never maps and writes nothing -> no record left, no worktree.
mkfirst tenb
sid_start s-never
sid_end s-never
check "unmapped no-op: no vault-level record left" "" "$(find "$V/.git/lore-sessions" -name '*.vault' 2>/dev/null)"
[ ! -e "$V/projects/_vault" ] && ok "unmapped no-op: projects/_vault does not exist" || bad "unmapped no-op: projects/_vault exists"
vc="$(SECOND_BRAIN_PATH="$V" bash "$H/vault-check.sh" check --all --vault "$V" 2>&1)"
hasnt "unmapped no-op: vault-check sees no _vault scope" "_vault" "$vc"
check "unmapped no-op: no worktree created" "" "$(ls -d "$V"/.claude/worktrees/lore-* 2>/dev/null)"

# 10c. first contact, then compact (same session id) after mapping and lore commit: the
# project record must not be written at the moved HEAD -> still one line.
mkfirst tenc
sid_start s-cmp
seed_work
sid_start_src() { ( cd "$P" && printf '{"cwd":"%s","source":"%s","session_id":"%s"}' "$P" "$2" "$1" | bash "$H/lore-orient.sh" >/dev/null 2>&1 ); }
sid_start_src s-cmp compact
sid_end s-cmp
check "first contact + compact: one checkpoint line" "1" "$(grep -c '\] \[claude-code\] Session ended\.$' "$WT/projects/roma/status.md")"

# 11. #473: the write branch changes mid-session (suffix hop to lore/roma-<date>-2):
# exactly one line, on the branch that holds the commits.
mkenv eleven 1
rm -rf "$P/.git"
sid_start s-hop
WT1="$WT"; b1="$(git -C "$WT1" symbolic-ref --short HEAD)"
git -C "$V" worktree add -q -b "${b1}-2" "$V/.claude/worktrees/lore-${b1#lore/}-2" main >/dev/null 2>&1
WT2="$V/.claude/worktrees/lore-${b1#lore/}-2"
mkdir -p "$WT2/projects/roma"; cp "$WT1/projects/roma/status.md" "$WT2/projects/roma/status.md"; echo hop >> "$WT2/projects/roma/decisions.md"
git -C "$WT2" add projects/roma; git -C "$WT2" commit -qm "[hop] roma"
touch "$WT2"
sid_end s-hop
check "hop: one line on the new branch" "1" "$(grep -c '\] \[claude-code\] Session ended\.$' "$WT2/projects/roma/status.md" 2>/dev/null)"
check "hop: none on the old branch" "0" "$(grep -c '\] \[claude-code\] Session ended\.$' "$WT1/projects/roma/status.md" 2>/dev/null)"

# 5. #461: git root keeps the branch/sha form (worktree session on branch feat)
mkenv five 1
git -C "$P" worktree add -q -b feat "$TMP/five/wt" >/dev/null 2>&1
git -C "$TMP/five/wt" commit -q --allow-empty -m w
sha="$(git -C "$TMP/five/wt" rev-parse --short HEAD)"
printf '{"cwd":"%s"}' "$TMP/five/wt" | bash "$H/lore-checkpoint.sh" >/dev/null 2>&1; sleep 1.5
has "git: line names branch @ sha" "Session ended on worktree branch feat @ $sha." "$(cat "$WT/projects/roma/status.md" "$V/projects/roma/status.md" 2>/dev/null)"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
