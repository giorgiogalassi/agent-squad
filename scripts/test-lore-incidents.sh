#!/usr/bin/env bash
# Tests the transcript-denial pass of claude/hooks/lore-checkpoint.sh
# (--incidents mode and the SessionEnd spawn). Plain bash 3.2; needs jq.
# SQUAD_INCIDENTS_FILE is a temp file; no model call; the vault is a fixture.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
FX="$REPO_ROOT/scripts/fixtures/transcripts"
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-lore-incidents.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

mkdir -p "$TMPROOT/hooks" "$TMPROOT/nojq" "$TMPROOT/fakebin"
cp "$REPO_ROOT"/claude/hooks/{lore-checkpoint.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
SUT="$TMPROOT/hooks/lore-checkpoint.sh"
# Fake claude: any model call would be a test bug.
printf '#!/bin/sh\necho "fake claude called" >> "%s/claude-called"\nexit 1\n' "$TMPROOT" > "$TMPROOT/fakebin/claude"
chmod +x "$TMPROOT/fakebin/claude"
for t in bash git cat sed awk grep dirname basename tr wc head tail sort date stat ls mkdir cut find rm mktemp uniq env; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$TMPROOT/nojq/$t"
done

out="$("$MK" connected)"
F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
FIXROOTS="$F_ROOT"
mkdir -p "$F_VAULT/projects/fixture"
printf -- '---\ntitle: s\n---\n# Status\nLast updated: 2099-01-01 00:00 by x\n\n## Last checkpoint\n\n## Context refs\n' > "$F_VAULT/projects/fixture/status.md"
export SECOND_BRAIN_PATH="$F_VAULT"
export PATH="$TMPROOT/fakebin:$PATH"

N=0
newstore() { N=$((N+1)); export SQUAD_INCIDENTS_FILE="$TMPROOT/store$N.tsv"; : > "$SQUAD_INCIDENTS_FILE"; }
rows() { wc -l < "$SQUAD_INCIDENTS_FILE" | tr -d ' '; }
col() { awk -F'\t' -v c="$1" '{print $c}' "$SQUAD_INCIDENTS_FILE" | tr '\n' ' ' | sed 's/ $//'; }
pass() { bash "$SUT" --incidents "$1" "$2" fixture >/dev/null 2>&1 </dev/null; }
# session dir layout: $TMPROOT/s<N>/<sid>.jsonl
mksession() { # mksession <name> <main-fixture>
  mkdir -p "$TMPROOT/$1"; cp "$FX/$2" "$TMPROOT/$1/$1.jsonl"
}

# 1. one denial -> one row (rejection and failing test in the same file are skipped)
newstore; mksession sa main-squad.jsonl
pass "$TMPROOT/sa/sa.jsonl" sa
check "one row for the squad denial" 1 "$(rows)"
check "kind=denial" denial "$(col 5)"
check "dedupe_id = tool_use_id" toolu_DENY1 "$(col 8)"
check "source=transcript" transcript "$(col 4)"

# 2. idempotent
pass "$TMPROOT/sa/sa.jsonl" sa
check "second run adds nothing" 1 "$(rows)"

# 3. subagent attribution via meta.json
newstore; mksession sb main-outside.jsonl
mkdir -p "$TMPROOT/sb/sb/subagents"
cp "$FX/subagent-cody.jsonl" "$TMPROOT/sb/sb/subagents/agent-abc.jsonl"
cp "$FX/subagent-cody.meta.json" "$TMPROOT/sb/sb/subagents/agent-abc.meta.json"
pass "$TMPROOT/sb/sb.jsonl" sb
check "subagent denial recorded (main outside squad paths skipped)" 1 "$(rows)"
check "component=cody" cody "$(col 6)"
check "subagent dedupe id" toolu_SUBDENY "$(col 8)"

# 4. rejection + failing test only -> nothing
newstore; mkdir -p "$TMPROOT/sc"
grep -v 'DENY1' "$FX/main-squad.jsonl" > "$TMPROOT/sc/sc.jsonl"
pass "$TMPROOT/sc/sc.jsonl" sc
check "no rows for rejection / failing test" 0 "$(rows)"

# 5. main denial outside squad paths -> nothing
newstore; mksession sd main-outside.jsonl
pass "$TMPROOT/sd/sd.jsonl" sd
check "no row outside squad paths" 0 "$(rows)"

# 6. no jq: hook exits 0, store unchanged
newstore; mksession se main-squad.jsonl
RC=0
printf '{"cwd":"%s","transcript_path":"%s","session_id":"se"}' "$F_PROJECT" "$TMPROOT/se/se.jsonl" \
  | env PATH="$TMPROOT/nojq" bash "$SUT" >/dev/null 2>&1 || RC=$?
check "no jq: hook exits 0" 0 "$RC"
sleep 1
check "no jq: store unchanged" 0 "$(rows)"
RC=0; env PATH="$TMPROOT/nojq" bash "$SUT" --incidents "$TMPROOT/se/se.jsonl" se fixture >/dev/null 2>&1 </dev/null || RC=$?
check "no jq: --incidents exits 0" 0 "$RC"
check "no jq: --incidents store unchanged" 0 "$(rows)"

# 7. SessionEnd hook spawns the pass detached; foreground is fast; vault not committed
newstore; mksession sf main-squad.jsonl
START="$(date +%s%N 2>/dev/null)"; case "$START" in *N) START="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000000000')" ;; esac
printf '{"cwd":"%s","transcript_path":"%s","session_id":"sf"}' "$F_PROJECT" "$TMPROOT/sf/sf.jsonl" | bash "$SUT" >/dev/null 2>&1
END="$(date +%s%N 2>/dev/null)"; case "$END" in *N) END="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000000000')" ;; esac
echo "info - hook foreground: $(( (END - START) / 1000000 )) ms"
i=0; while [ "$(rows)" -lt 1 ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
check "hook spawned the pass (row appears)" 1 "$(rows)"
[ $(( (END - START) / 1000000 )) -lt 1000 ] && ok "foreground < 1 s" || bad "foreground < 1 s"
[ -f "$TMPROOT/claude-called" ] && bad "no model call" || ok "no model call"
check "vault not committed by the pass" 0 "$(git -C "$F_VAULT" log --oneline 2>/dev/null | grep -c 'incident')"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
