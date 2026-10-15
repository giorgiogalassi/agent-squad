#!/usr/bin/env bash
# Tests the main-checkout staleness rule of claude/hooks/lore-checkpoint.sh:
# only commits on LOCAL branches (refs/heads) after "Last updated" make status
# stale. Remote-tracking refs moving, or nothing moving, must neither write
# nor call the model. Plain bash 3.2; the vault is a fixture, claude is a fake
# that records its stdin (the rebuild evidence) and fails, so status never changes.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-lore-checkpoint.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
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

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
