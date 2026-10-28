#!/usr/bin/env bash
# Tests claude/hooks/cody-checkpoint.sh (async SubagentStop hook, matcher cody):
# checkpoint line + progress.txt line derived from git evidence. Plain bash 3.2;
# needs jq. The vault is a fixture and `gh` is a fake.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-cody-checkpoint
FIXROOTS=""
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

mkdir -p "$TMPROOT/hooks" "$TMPROOT/fakebin"
cp "$REPO_ROOT"/claude/hooks/{cody-checkpoint.sh,lore-checkpoint.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
SUT="$TMPROOT/hooks/cody-checkpoint.sh"
# Fake gh: `pr list` prints "<number> <base>" when FAKE_PR is set, nothing otherwise.
printf '#!/bin/sh\n[ -n "$FAKE_PR" ] && echo "$FAKE_PR"\nexit 0\n' > "$TMPROOT/fakebin/gh"
chmod +x "$TMPROOT/fakebin/gh"
export PATH="$TMPROOT/fakebin:$PATH"
export SQUAD_INCIDENTS=off
GIT="git -c user.name=T -c user.email=t@example.com"

setup() {  # setup <mode>: sets F_ROOT F_PROJECT F_VAULT STATUS PROGRESS ENVF
  out="$("$MK" "$1")"
  F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
  F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
  F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  FIXROOTS="$FIXROOTS $F_ROOT"
  export SECOND_BRAIN_PATH="$F_VAULT"
  STATUS="$F_VAULT/projects/fixture/status.md"
  PROGRESS="$F_VAULT/projects/fixture/.squad/progress.txt"
  ENVF="$F_VAULT/projects/fixture/.squad/cody-checkpoint.env"
  printf -- '---\ntitle: s\n---\n# Status\nLast updated: 2099-01-01 00:00 by x\n\n## Goal\n\n## Last checkpoint\n\n## Context refs\n' > "$STATUS"
  git -C "$F_VAULT" init -q; git -C "$F_VAULT" add -A; $GIT -C "$F_VAULT" commit -q -m seed
}
commit_on() {  # commit_on <branch> <subject>
  git -C "$F_PROJECT" checkout -q -b "$1"
  echo x >> "$F_PROJECT/f.txt"; git -C "$F_PROJECT" add f.txt; $GIT -C "$F_PROJECT" commit -q -m "$2"
}
run_hook() {  # run_hook [agent_type]
  printf '{"cwd":"%s","agent_type":"%s","agent_transcript_path":"%s/none.jsonl"}' "$F_PROJECT" "${1:-cody}" "$TMPROOT" | bash "$SUT" >/dev/null 2>&1
}
envval() { sed -n "s/^$1=//p" "$ENVF" 2>/dev/null; }

# 1. connected, PR open
setup connected
commit_on 296-x "[#296] add thing"
FAKE_PR="7 main" run_hook
grep -q 'PR #7 opened. Branch: 296-x @' "$STATUS" && ok "pr: checkpoint line in status.md" || bad "pr: checkpoint line"
check "pr: progress line" "[#296] resolved. PR: #7 (base: main). Notes: [#296] add thing" "$(cat "$PROGRESS" 2>/dev/null)"
check "pr: summary STATE" pr "$(envval STATE)"
check "pr: summary TREE" clean "$(envval TREE)"
check "pr: summary SHA" "$(git -C "$F_PROJECT" rev-parse --short HEAD)" "$(envval SHA)"
FAKE_PR="7 main" run_hook
check "pr: idempotent status" 1 "$(grep -c 'PR #7 opened' "$STATUS")"
check "pr: idempotent progress" 1 "$(wc -l < "$PROGRESS" | tr -d ' ')"
# status.md and progress.txt are committed by path; the summary .env stays untracked.
git -C "$F_VAULT" status --porcelain -- projects/fixture/status.md projects/fixture/.squad/progress.txt | grep -q . \
  && bad "pr: status.md and progress.txt committed" || ok "pr: status.md and progress.txt committed"

# 2. connected, stopped with a commit, no PR (maxTurns): checkpoint line, no progress line
setup connected
commit_on 296-y "[#296] half done"
echo wip > "$F_PROJECT/wip.txt"
run_hook
grep -q 'committed @ .*no PR yet' "$STATUS" && ok "no PR: checkpoint line" || bad "no PR: checkpoint line"
[ -f "$PROGRESS" ] && bad "no PR: no progress line" || ok "no PR: no progress line"
check "no PR: summary STATE" committed "$(envval STATE)"
check "no PR: summary TREE" dirty "$(envval TREE)"

# 3. detached: ready for manual push
setup detached
commit_on 296-z "[#296] done"
run_hook
grep -q 'Branch 296-z ready for manual push @' "$STATUS" && ok "detached: checkpoint line" || bad "detached: checkpoint line"
check "detached: summary STATE" detached "$(envval STATE)"

# 4. no write: shared branch, no issue ID, other agent
setup connected
BEFORE="$(cat "$STATUS")"
run_hook; check "main branch: status unchanged" "$BEFORE" "$(cat "$STATUS")"
commit_on 296-q "no id here"
run_hook; check "no issue ID: status unchanged" "$BEFORE" "$(cat "$STATUS")"
echo y >> "$F_PROJECT/f.txt"; git -C "$F_PROJECT" add f.txt; $GIT -C "$F_PROJECT" commit -q -m "[#296] with id"
run_hook reven; check "other agent: status unchanged" "$BEFORE" "$(cat "$STATUS")"
run_hook "agent-squad:cody"; grep -q 'no PR yet' "$STATUS" && ok "plugin-namespaced agent type matches" || bad "plugin-namespaced agent type matches"

# 4b. fresh branch cut from a stacked base whose tip carries another issue ID, no Cody commit,
#     no PR possible -> nothing recorded (connected and detached), stale summary removed
for _m in connected detached; do
  setup "$_m"
  git -C "$F_PROJECT" checkout -q -b stack
  echo s >> "$F_PROJECT/f.txt"; git -C "$F_PROJECT" add f.txt; $GIT -C "$F_PROJECT" commit -q -m "[#293] stack tip"
  git -C "$F_PROJECT" checkout -q -b 296-fresh
  mkdir -p "$(dirname "$ENVF")"; echo STATE=old > "$ENVF"
  BEFORE="$(cat "$STATUS")"
  run_hook
  check "$_m stacked base, no Cody commit: status unchanged" "$BEFORE" "$(cat "$STATUS")"
  [ -f "$PROGRESS" ] && bad "$_m stacked base: no progress line" || ok "$_m stacked base: no progress line"
  [ -f "$ENVF" ] && bad "$_m stacked base: stale summary removed" || ok "$_m stacked base: stale summary removed"
done

# 4b2. guard (a) alone: same issue ID as the branch, but HEAD already sits on another branch
setup connected
git -C "$F_PROJECT" checkout -q -b other
echo s >> "$F_PROJECT/f.txt"; git -C "$F_PROJECT" add f.txt; $GIT -C "$F_PROJECT" commit -q -m "[#296] earlier work"
git -C "$F_PROJECT" checkout -q -b 296-again
BEFORE="$(cat "$STATUS")"
run_hook
check "HEAD on another branch: status unchanged" "$BEFORE" "$(cat "$STATUS")"

# 4b3. positive: a real Cody commit on a fresh stacked branch IS recorded
setup connected
git -C "$F_PROJECT" checkout -q -b stack
echo s >> "$F_PROJECT/f.txt"; git -C "$F_PROJECT" add f.txt; $GIT -C "$F_PROJECT" commit -q -m "[#293] stack tip"
git -C "$F_PROJECT" checkout -q -b 296-real
echo c >> "$F_PROJECT/f.txt"; git -C "$F_PROJECT" add f.txt; $GIT -C "$F_PROJECT" commit -q -m "[#296] real work"
run_hook
grep -q 'Branch 296-real committed @ .*\[#296\] real work' "$STATUS" && ok "stacked branch, real commit: recorded" || bad "stacked branch, real commit: recorded"
check "stacked branch, real commit: summary ISSUE" "#296" "$(envval ISSUE)"

# 4b4. detached chain: one lead-named branch carries several issues' commits; the later one is recorded
for _m in detached connected; do
  setup "$_m"
  commit_on 12-reservations "[#12] reservations table"
  echo n >> "$F_PROJECT/f.txt"; git -C "$F_PROJECT" add f.txt; $GIT -C "$F_PROJECT" commit -q -m "[#13] reservation form"
  run_hook
  grep -q 'Branch 12-reservations .*@ .*\[#13\] reservation form' "$STATUS" && ok "$_m chain: second issue commit recorded" || bad "$_m chain: second issue commit recorded"
  check "$_m chain: summary ISSUE" "#13" "$(envval ISSUE)"
done

# 4b5. HEAD also on its own branch at another remote, or on a fetched pull ref -> still recorded
for _ref in refs/remotes/upstream/296-rem refs/remotes/origin/pr/5 refs/remotes/upstream/pr/9; do
  setup connected
  commit_on 296-rem "[#296] real work"
  git -C "$F_PROJECT" update-ref "$_ref" HEAD
  run_hook
  grep -q 'Branch 296-rem committed @ .*\[#296\] real work' "$STATUS" && ok "$_ref: recorded" || bad "$_ref: recorded"
done

# 4c. progress dedupe matches on PR number, whatever follows the ID (dated form)
setup connected
commit_on 296-d "[#296] add thing"
mkdir -p "$(dirname "$PROGRESS")"; echo "[#296] 2026-10-24 resolved. PR: #7 (base: main). Notes: older" > "$PROGRESS"
FAKE_PR="7 main" run_hook
check "progress dedupe by PR number" 1 "$(wc -l < "$PROGRESS" | tr -d ' ')"

# 4d. vault commit is by path: an unrelated pre-staged vault file stays staged, out of the commit
setup connected
commit_on 296-p "[#296] add thing"
echo u > "$F_VAULT/unrelated.txt"; git -C "$F_VAULT" add unrelated.txt
FAKE_PR="7 main" run_hook
git -C "$F_VAULT" diff --cached --name-only | grep -qx unrelated.txt && ok "vault: unrelated file still staged" || bad "vault: unrelated file still staged"
git -C "$F_VAULT" log --name-only --format= | grep -q unrelated.txt && bad "vault: unrelated file not committed" || ok "vault: unrelated file not committed"
git -C "$F_VAULT" log --format=%s | grep -q 'lore: progress' && ok "vault: progress commit made" || bad "vault: progress commit made"

# 4e. local-only project (only status.md excluded, so the progress commit still happens):
#     the vault commit message carries no project name; a non-excluded control keeps it
setup connected
git -C "$F_VAULT" rm -q --cached projects/fixture/status.md; $GIT -C "$F_VAULT" commit -q -m untrack
printf 'projects/fixture/status.md\n' >> "$F_VAULT/.git/info/exclude"
commit_on 296-l "[#296] add thing"
FAKE_PR="7 main" run_hook
git -C "$F_VAULT" log --format=%s | grep -q '^lore: progress local$' && ok "local-only: progress commit uses public name" || bad "local-only: progress commit uses public name"
git -C "$F_VAULT" log --format=%B | grep -q fixture && bad "local-only: name absent from git log" || ok "local-only: name absent from git log"
setup connected
commit_on 296-c "[#296] add thing"
FAKE_PR="7 main" run_hook
git -C "$F_VAULT" log --format=%s | grep -qx 'lore: progress fixture' && ok "control: progress commit keeps name" || bad "control: progress commit keeps name"

# 5. exits 0 on garbage input
RC=0; printf 'not json' | bash "$SUT" >/dev/null 2>&1 || RC=$?
check "garbage input exits 0" 0 "$RC"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
