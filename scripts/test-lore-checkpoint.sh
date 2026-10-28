#!/usr/bin/env bash
# Tests the main-checkout staleness rule of claude/hooks/lore-checkpoint.sh:
# only commits on LOCAL branches (refs/heads) after "Last updated" make status
# stale. Remote-tracking refs moving, or nothing moving, must neither write
# nor call the model. Plain bash 3.2; the vault is a fixture, claude is a fake
# that records its stdin (the rebuild evidence) and fails, so status never changes.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-checkpoint
FIXROOTS=""
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

mkdir -p "$TMPROOT/hooks" "$TMPROOT/fakebin"
cp "$REPO_ROOT"/claude/hooks/{lore-checkpoint.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
SUT="$TMPROOT/hooks/lore-checkpoint.sh"
EVIDENCE="$TMPROOT/evidence"
printf '#!/bin/sh\ncat > "%s"\nexit 1\n' "$EVIDENCE" > "$TMPROOT/fakebin/claude"
chmod +x "$TMPROOT/fakebin/claude"

out="$("$MK" connected --worktree)"
F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
F_WT="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')"
FIXROOTS="$F_ROOT"
export SECOND_BRAIN_PATH="$F_VAULT"
export PATH="$TMPROOT/fakebin:$PATH"
export SQUAD_INCIDENTS=off
STATUS="$F_VAULT/projects/fixture/status.md"

# Dates in the future keep the fixture deterministic: the fixture's own commits
# are "now", so Last updated = +1 day means nothing has moved yet.
future() { date -v+"$1"d "+%Y-%m-%d %H:%M" 2>/dev/null || date -d "$1 days" "+%Y-%m-%d %H:%M"; }
UPDATED="$(future 1)"
printf -- '---\ntitle: s\n---\n# Status\nLast updated: %s by x\n\n## Goal\n\n## Last checkpoint\n\n## Context refs\n' "$UPDATED" > "$STATUS"
BEFORE="$(cat "$STATUS")"
GIT="git -c user.name=T -c user.email=t@example.com"

run_hook() { printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1; sleep 1.5; }
no_effect() { # no_effect <label>
  [ -f "$EVIDENCE" ] && bad "$1: no model call" || ok "$1: no model call"
  check "$1: status.md unchanged" "$BEFORE" "$(cat "$STATUS")"
}

# 1. nothing moved since Last updated -> no write, no model call
run_hook; no_effect "nothing moved"

# 2. only remote-tracking refs moved (push from a clone + fetch) -> no write, no model call
git clone -q "$F_ROOT/origin.git" "$TMPROOT/clone" 2>/dev/null
( cd "$TMPROOT/clone" && git checkout -q -b remote-only && echo r > r.txt && git add r.txt \
  && GIT_COMMITTER_DATE="$(future 2)" GIT_AUTHOR_DATE="$(future 2)" $GIT commit -q -m "remote only" \
  && git push -q origin remote-only )
git -C "$F_PROJECT" fetch -q origin
check "remote-tracking ref has the newer commit" 1 "$(git -C "$F_PROJECT" log origin/remote-only --since="$UPDATED" --oneline | wc -l | tr -d ' ')"
run_hook; no_effect "remote refs only"

# 3. stash only -> no write, no model call
echo dirty >> "$F_PROJECT/README.md"
GIT_COMMITTER_DATE="$(future 2)" $GIT -C "$F_PROJECT" stash -q
run_hook; no_effect "stash only"

# 4. commit only on a worktree branch -> stale; rebuild evidence names the branch and tip
echo w > "$F_WT/w.txt"; git -C "$F_WT" add w.txt
GIT_COMMITTER_DATE="$(future 2)" GIT_AUTHOR_DATE="$(future 2)" $GIT -C "$F_WT" commit -q -m "worktree-only work"
check "main checkout stays on main" main "$(git -C "$F_PROJECT" rev-parse --abbrev-ref HEAD)"
run_hook
i=0; while [ ! -s "$EVIDENCE" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
[ -s "$EVIDENCE" ] && ok "worktree-branch commit triggers a rebuild" || bad "worktree-branch commit triggers a rebuild"
TIP="$(git -C "$F_WT" rev-parse --short HEAD)"
grep -q "fixture-wt @ $TIP worktree-only work" "$EVIDENCE" 2>/dev/null \
  && ok "evidence lists the worktree branch with its tip" || bad "evidence lists the worktree branch with its tip"
grep -q "remote-only" "$EVIDENCE" 2>/dev/null && bad "evidence omits remote-only branches" || ok "evidence omits remote-only branches"

# 5. async hook rebuilds inline and commits the vault (no detach, lock or alarm layer)
grep -qE 'setsid|nohup|\.lore-rebuild\.lock|alarm\(|timeout 90' "$REPO_ROOT/claude/hooks/lore-checkpoint.sh" \
  && bad "no detach/lock/alarm code left" || ok "no detach/lock/alarm code left"
git -C "$F_VAULT" init -q 2>/dev/null; git -C "$F_VAULT" add -A; $GIT -C "$F_VAULT" commit -q -m seed
OLD="$(date -v-9d "+%Y-%m-%d %H:%M" 2>/dev/null || date -d "9 days ago" "+%Y-%m-%d %H:%M")"
printf -- '---\ntitle: s\n---\n# Status\nLast updated: %s by x\n\n## Goal\n\n## Blocked\nkeep-me\n\n## Last checkpoint\n\n## Context refs\n' "$OLD" > "$STATUS"
cat > "$TMPROOT/fakebin/claude" <<'EOS'
#!/bin/sh
cat > /dev/null
printf -- '---\ntitle: s\n---\n# Status\nLast updated: x\n\n## Goal\nrebuilt\n\n## Done\n\n## Next\n\n## Blocked\nDROPPED\n\n## Last checkpoint\n\n## Context refs\n'
EOS
printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1
grep -q 'rebuilt' "$STATUS" && ok "stale status rebuilt synchronously" || bad "stale status rebuilt synchronously"
grep -q 'keep-me' "$STATUS" && ok "Blocked preserved verbatim" || bad "Blocked preserved verbatim"
git -C "$F_VAULT" log --format=%s -1 | grep -q 'lore: rebuild status fixture' && ok "vault commit made" || bad "vault commit made"
git -C "$F_VAULT" show --stat --format= HEAD | grep -q 'status.md' && ok "commit staged by path (status.md)" || bad "commit staged by path"

# 6. worktree session ending with uncommitted changes: checkpoint line, no progress line, no commit
echo dirty > "$F_WT/d1.txt"; echo dirty > "$F_WT/d2.txt"
HEAD_BEFORE="$(git -C "$F_WT" rev-parse HEAD)"
printf '{"cwd":"%s"}' "$F_WT" | bash "$SUT" >/dev/null 2>&1
grep -q 'uncommitted work on fixture-wt: 2 files' "$STATUS" && ok "dirty worktree leaves a checkpoint line" || bad "dirty worktree leaves a checkpoint line"
check "worktree HEAD unchanged" "$HEAD_BEFORE" "$(git -C "$F_WT" rev-parse HEAD)"
[ -f "$F_VAULT/projects/fixture/.squad/progress.txt" ] && bad "no progress line" || ok "no progress line"
printf '{"cwd":"%s"}' "$F_WT" | bash "$SUT" >/dev/null 2>&1
check "dirty line is idempotent" 1 "$(grep -c 'uncommitted work on fixture-wt' "$STATUS")"

# 7. vault commit is by path: an unrelated pre-staged vault file stays staged, out of the commit
echo u > "$F_VAULT/unrelated.txt"; git -C "$F_VAULT" add unrelated.txt
( cd "$F_PROJECT" && bash "$SUT" --note "[2099-01-01 00:00] [claude-code] by-path probe" </dev/null >/dev/null 2>&1 )
grep -q 'by-path probe' "$STATUS" && ok "note written" || bad "note written"
git -C "$F_VAULT" diff --cached --name-only | grep -qx unrelated.txt && ok "unrelated file still staged" || bad "unrelated file still staged"
git -C "$F_VAULT" show --name-only --format= HEAD | grep -q unrelated.txt && bad "unrelated file not in commit" || ok "unrelated file not in commit"

# 8. Next is remove-only: dropping a whole item passes (Next outside the budget),
#    rewording or adding an item bails and leaves status.md untouched.
LONG="$(printf 'x%.0s' $(seq 1 1700))"
next_case() { # next_case <label> <model Next body>
  printf -- '---\ntitle: s\n---\n# Status\nLast updated: %s by x\n\n## Goal\ng\n\n## Next\nACTION: keep %s\nCONTEXT: k\nACTION: drop me\nCONTEXT: d\n\n## Blocked\n\n## Last checkpoint\n\n## Context refs\n' "$OLD" "$LONG" > "$STATUS"
  NEXT_BODY="$2" ; export NEXT_BODY
  cat > "$TMPROOT/fakebin/claude" <<'EOS'
#!/bin/sh
cat > /dev/null
printf -- '---\ntitle: s\n---\n# Status\nLast updated: x\n\n## Goal\nrebuilt\n\n## Done\n\n## Next\n%s\n\n## Blocked\n\n## Last checkpoint\n\n## Context refs\n' "$NEXT_BODY"
EOS
  printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1
}
next_case drop "ACTION: keep $LONG
CONTEXT: k"
grep -q 'rebuilt' "$STATUS" && ok "dropping a Next item rebuilds (Next not budgeted)" || bad "dropping a Next item rebuilds (Next not budgeted)"
grep -q 'drop me' "$STATUS" && bad "dropped item is gone" || ok "dropped item is gone"
next_case reword "ACTION: keep $LONG
CONTEXT: k, reworded"
grep -q 'rebuilt' "$STATUS" && bad "reworded Next item bails" || ok "reworded Next item bails"
grep -q 'rewrote a Next item' "$F_VAULT/projects/fixture/.lore-checkpoint.log" && ok "bail reason logged" || bad "bail reason logged"
next_case add "ACTION: keep $LONG
CONTEXT: k
ACTION: invented
CONTEXT: i"
grep -q 'rebuilt' "$STATUS" && bad "added Next item bails" || ok "added Next item bails"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
