#!/usr/bin/env bash
# Tests the SessionEnd session-log closure of claude/hooks/lore-checkpoint.sh
# (#329): the start lines of the session that just ended are closed, other live
# sessions' starts are not, a skill-closed session gets no second end, and the
# skills' start lines (with "branch:") still pair in vault-check.sh. Plain bash
# 3.2; fixture vaults only; a fake claude is first on PATH.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-lore-session.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in [$3])" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq required"; exit 0; }
mkdir -p "$TMPROOT/hooks" "$TMPROOT/fakebin"
cp "$REPO_ROOT"/claude/hooks/{lore-checkpoint.sh,vault-check.sh,decisions-lint.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
SUT="$TMPROOT/hooks/lore-checkpoint.sh"
VC="$TMPROOT/hooks/vault-check.sh"
export SQUAD_INCIDENTS=off
printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "$TMPROOT/fakebin/claude"
chmod +x "$TMPROOT/fakebin/claude"
export PATH="$TMPROOT/fakebin:$PATH"

out="$("$MK" connected)"
F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
FIXROOTS="$F_ROOT"
export SECOND_BRAIN_PATH="$F_VAULT"
GIT="git -c user.name=T -c user.email=t@example.com"
BR="$(git -C "$F_PROJECT" rev-parse --abbrev-ref HEAD)"
LOG="$F_VAULT/projects/fixture/.squad/session.log"
mkdir -p "$(dirname "$LOG")"

# Times relative to now: session began 2h ago; one start at -1h, one at -5h.
tm() { python3 -c "import datetime as d,sys;print((d.datetime.now()+d.timedelta(hours=$1)).strftime('%Y-%m-%d %H:%M'))"; }
T_NOW="$(tm 0)"; T_MINE="$(tm -1)"; T_OLD="$(tm -5)"
python3 -c "import datetime as d;print((d.datetime.utcnow()-d.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" > "$TMPROOT/ts"
TRANSCRIPT="$TMPROOT/transcript.jsonl"
printf '{"type":"summary"}\n{"type":"user","timestamp":"%s"}\n' "$(cat "$TMPROOT/ts")" > "$TRANSCRIPT"

printf -- '---\ntitle: s\ntags: [status, active]\n---\n# Status\nLast updated: %s by x\n\n## Goal\ng\n\n## Last checkpoint\n\n## Context refs\n' "$T_NOW" > "$F_VAULT/projects/fixture/status.md"
cat > "$LOG" <<LOGEOF
[$T_OLD] [forge] start — branch: $BR
[$T_MINE] [forge] start — branch: $BR
[$T_MINE] [ralph] start — batch: [1, 2], branch: $BR
[$T_MINE] [ralph] end — resolved: 2, escalated: [], skipped: []
[$T_MINE] [chisel] start — branch: some-other-branch
[$T_MINE] [archy] start
LOGEOF
git -C "$F_VAULT" init -q
$GIT -C "$F_VAULT" add -A && $GIT -C "$F_VAULT" commit -q -m seed
echo changed > "$F_VAULT/notes.md"

# Skills' new start lines still pair (item 2): ralph's batch+branch line is
# closed by its plain end; the rest are open.
orph="$(. "$VC"; session_orphans "$LOG")"
check "start with branch field pairs with a plain end" "" "$(printf '%s\n' "$orph" | grep ralph)"
has "forge start with branch is open" "$T_MINE	forge" "$orph"

run() { printf '{"cwd":"%s","transcript_path":"%s","session_id":"s-1"}' "$F_PROJECT" "$TRANSCRIPT" | bash "$SUT" >/dev/null 2>&1; }
run
L="$(cat "$LOG")"
has "this session's start closed, exact format" "[forge] end — closed at session end (start $T_MINE)" "$L"
lacks "start older than the session is not closed" "(start $T_OLD)" "$L"
lacks "other branch's live start not closed" "[chisel] end" "$L"
lacks "start without a branch is not closed" "[archy] end" "$L"
lacks "skill-closed session gets no second end" "[ralph] end — closed" "$L"
check "exactly one line appended" "7" "$(wc -l < "$LOG" | tr -d ' ')"
orph="$(. "$VC"; session_orphans "$LOG")"
lacks "closed start no longer an orphan" "$T_MINE	forge" "$orph"
check "commit touches session.log only" "projects/fixture/.squad/session.log" "$(git -C "$F_VAULT" show --name-only --format= HEAD | grep -v INDEX.md)"
check "unrelated change stays uncommitted" "?? notes.md" "$(git -C "$F_VAULT" status --porcelain | grep notes.md)"
n="$(wc -l < "$LOG" | tr -d ' ')"; c="$(git -C "$F_VAULT" rev-list --count HEAD)"
run
check "second SessionEnd writes nothing" "$n" "$(wc -l < "$LOG" | tr -d ' ')"
check "second SessionEnd commits nothing for the log" "$c" "$(git -C "$F_VAULT" rev-list --count HEAD)"

# No transcript: nothing closed (no safe identification).
printf '[%s] [seed] start — branch: %s\n' "$T_MINE" "$BR" >> "$LOG"
n="$(wc -l < "$LOG" | tr -d ' ')"
printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1
check "no transcript: nothing closed" "$n" "$(wc -l < "$LOG" | tr -d ' ')"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
