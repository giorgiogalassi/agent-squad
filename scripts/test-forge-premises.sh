#!/usr/bin/env bash
# Structural tests for #459: premise check prose (Forge, Chisel, Cody, Reven, Ralph)
# and the forge-already-covered eval case (scaffold, graders). Plain bash 3.2.
set -u
export SQUAD_INCIDENTS=off GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/scripts/lib/test-tmp.sh"
test_tmp_init test-forge-premises TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
has() { grep -qE -- "$2" "$1" && ok "$3" || bad "$3"; }
C="$REPO_ROOT/claude"

has "$C/skills/forge/SKILL.md" '^## Premise check' "forge: premise check section"
has "$C/skills/forge/SKILL.md" '^premises:' "forge: premises in output YAML"
has "$C/skills/forge/SKILL.md" 'gap confirmed \| already covered \| not verifiable' "forge: three statuses"
has "$C/skills/forge/SKILL.md" 'Never apply `already covered` or `not verifiable` silently' "forge: no silent apply"
has "$C/skills/forge/SKILL.md" 'trigger:' "forge: trigger location field"
has "$C/skills/forge/SKILL.md" 'state_at_trigger:' "forge: state at trigger field"
has "$C/skills/archy/SKILL.md" '^## Premises' "archy: PRD carries premises"
has "$C/skills/chisel/SKILL.md" '^## Kind and premises' "chisel: kind and premises section"
has "$C/skills/chisel/SKILL.md" 'readiness path below' "chisel: reuses readiness path"
has "$C/agents/cody.md" 'ESCALATION: premise' "cody: premise escalation summary"
has "$C/agents/cody.md" 'ESCALATE premise' "cody: fix-round ESCALATE"
has "$C/skills/ralph/SKILL.md" 'ESCALATION: premise' "ralph: premise escalation is immediate"
has "$C/agents/reven.md" '^## Premise check' "reven: premise check section"
has "$C/agents/reven.md" 'not a generic reachability check' "reven: no reachability check"
has "$C/agents/reven.md" 'premise P<k> fails' "reven: finding names premise ID and path"

E="$C/evals/forge-already-covered"
for f in case.yaml prompt.md scaffold.sh graders/already-covered-evidence.md graders/no-behaviour-reset-on-load.md; do
  [ -f "$E/$f" ] && ok "eval file: $f" || bad "eval file: $f"
done

# Scaffold builds the fixture in a sandboxed HOME.
H="$TMP/home"; mkdir -p "$H/cwd"
(cd "$H/cwd" && env HOME="$H" SECOND_BRAIN_PATH="$H/second-brain" TMPDIR="$H/cwd" bash "$E/scaffold.sh" >/dev/null 2>&1)
P="$H/cwd/project"
[ -f "$P/src/store.ts" ] && grep -q 'resetSection(current)' "$P/src/store.ts" && ok "fixture: navigate resets the section left" || bad "fixture store.ts"
[ -f "$P/src/product-list.ts" ] && grep -q "attr:" "$P/src/product-list.ts" && ok "fixture: sort by attr:<id>" || bad "fixture product-list.ts"
[ -z "$(git -C "$P" status --porcelain 2>/dev/null)" ] && ok "fixture: committed, clean tree" || bad "fixture tree not clean"

# Grader self-check: correct output vs a plan that adds the reset.
cat > "$TMP/good.txt" <<'EOS'
premises:
  - id: P1
    status: already covered
    trigger: src/store.ts:30 loadAttributeDefinitions runs on navigate('catalog')
    state_at_trigger: src/store.ts:26 resetSection already reset the sort to default
Issues: none planned for P1
EOS
cat > "$TMP/bad.txt" <<'EOS'
premises:
  - id: P1
    status: gap confirmed
Issues:
  Kind: behaviour - Reset the sort to default when attribute definitions load
EOS
grader_match() {
  python3 -I - "$E/graders/$1.md" "$TMP/$2.txt" <<'EOP'
import re, sys
meta = open(sys.argv[1]).read().split('---')[1]
pat = re.search(r'^pattern: "(.*)"$', meta, re.M).group(1).replace('\\\\', '\\')
fl = re.search(r'^flags: "(.*)"$', meta, re.M).group(1)
f = (re.I if 'i' in fl else 0) | (re.S if 's' in fl else 0)
print(1 if re.search(pat, open(sys.argv[2]).read(), f) else 0)
EOP
}
[ "$(grader_match already-covered-evidence good)" = 1 ] && [ "$(grader_match already-covered-evidence bad)" = 0 ] && ok "grader already-covered-evidence" || bad "grader already-covered-evidence"
[ "$(grader_match no-behaviour-reset-on-load good)" = 1 ] && [ "$(grader_match no-behaviour-reset-on-load bad)" = 0 ] && ok "grader no-behaviour-reset-on-load" || bad "grader no-behaviour-reset-on-load"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
