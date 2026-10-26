#!/usr/bin/env bash
# Tests claude/hooks/lore-nudge.sh (#331). Plain bash 3.2; the vault is a
# fixture and `claude` is a fake first on PATH -- no model is ever reached.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-lore-nudge.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "skip - jq missing"; exit 0; }

mkdir -p "$TMPROOT/hooks" "$TMPROOT/fakebin"
cp "$REPO_ROOT"/claude/hooks/{lore-nudge.sh,path-resolve.sh} "$TMPROOT/hooks/"
HOOK="$TMPROOT/hooks/lore-nudge.sh"
CALLS="$TMPROOT/claude-calls"
cat > "$TMPROOT/fakebin/claude" <<EOF2
#!/bin/sh
echo "called child=\${LORE_NUDGE_CHILD:-}" >> "$CALLS"
cat > "$TMPROOT/claude-stdin"
printf '%s\n' "\${FAKE_ANSWER:-NO}"
EOF2
chmod +x "$TMPROOT/fakebin/claude"
export PATH="$TMPROOT/fakebin:$PATH"

out="$("$MK" connected)"
F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
FIXROOTS="$F_ROOT"
export SECOND_BRAIN_PATH="$F_VAULT"
CFG="$F_VAULT/lore-config.json"
mkdir -p "$F_VAULT/projects/fixture"
printf '# Decisions\n\n## [2026-10-01] Old choice\nbody\n' > "$F_VAULT/projects/fixture/decisions.md"
DEC_BEFORE="$(cksum < "$F_VAULT/projects/fixture/decisions.md")"

TR="$TMPROOT/t.jsonl"
cat > "$TR" <<'EOF2'
{"type":"user","message":{"role":"user","content":"should we gate it by a setting?"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Yes, lore.nudge, off by default."}]}}
{"type":"user","message":{"role":"user","content":"ok, do that"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done: gated behind lore.nudge."}]}}
EOF2

run() { # run <cwd> <stop_hook_active>
  jq -n --arg c "$1" --arg t "$TR" --argjson a "${2:-false}" \
    '{cwd:$c, transcript_path:$t, stop_hook_active:$a}' | bash "$HOOK" 2>/dev/null
}
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
setcfg() { jq "$1" "$CFG" > "$TMPROOT/cfg.new" && mv "$TMPROOT/cfg.new" "$CFG"; }

export FAKE_ANSWER="YES: Gate nudge: lore.nudge setting, off by default"

# Off (key absent): no output, no model call
r="$(run "$F_PROJECT")"
check "off (absent): no output" "" "$r"
check "off (absent): no model call" "0" "$(calls)"

setcfg '.lore = {nudge: false}'
r="$(run "$F_PROJECT")"
check "off (false): no output" "" "$r"
check "off (false): no model call" "0" "$(calls)"

# On: eligible, proposes lore decide
setcfg '.lore = {nudge: true}'
r="$(run "$F_PROJECT")"
check "on: block decision" "block" "$(printf '%s' "$r" | jq -r .decision 2>/dev/null)"
has "on: reason proposes lore decide" 'lore decide "Gate nudge: lore.nudge setting, off by default"' "$(printf '%s' "$r" | jq -r .reason)"
has "on: reason says wait" "wait for the user" "$(printf '%s' "$r" | jq -r .reason)"
check "on: one model call" "1" "$(calls)"
has "on: judge saw the turn" "ok, do that" "$(cat "$TMPROOT/claude-stdin")"
has "on: judge saw known headings" "Old choice" "$(cat "$TMPROOT/claude-stdin")"
has "on: judge run flagged as child" "child=1" "$(cat "$CALLS")"

# On, answer NO: nothing visible
r="$(FAKE_ANSWER=NO run "$F_PROJECT")"
check "on, NO: no output" "" "$r"

# Loop guards
before="$(calls)"
r="$(run "$F_PROJECT" true)"
check "stop_hook_active: silent" "" "$r"
r="$(LORE_NUDGE_CHILD=1 run "$F_PROJECT")"
check "child session: silent" "" "$r"
check "guards: no model call" "$before" "$(calls)"

# Unmapped project: silent even when on
UNMAPPED="$TMPROOT/unmapped"; mkdir -p "$UNMAPPED"; git -C "$UNMAPPED" init -q
before="$(calls)"
r="$(run "$UNMAPPED")"
check "unmapped project: silent" "" "$r"
check "unmapped project: no model call" "$before" "$(calls)"

check "never writes decisions.md" "$DEC_BEFORE" "$(cksum < "$F_VAULT/projects/fixture/decisions.md")"

echo "---"; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
