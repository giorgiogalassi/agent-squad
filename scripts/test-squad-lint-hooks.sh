#!/usr/bin/env bash
# Tests for check 8 (referenced hooks exist) of scripts/squad-lint.sh.
set -u
# Never write the real vault incident store.
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-lint-hooks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

fixture() {  # fixture <dir>
  mkdir -p "$1/scripts"
  cp -R "$REPO_ROOT/claude" "$1/claude"
  cp "$REPO_ROOT/scripts/lint-allowlist-1b.txt" "$REPO_ROOT/scripts/test-squad-labels.sh" "$1/scripts/"
  cp "$REPO_ROOT"/*.md "$1/" 2>/dev/null
  return 0
}
c8() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$1" 2>&1 | sed -n '/== 8/,/== summary/p'; }

fixture "$TMP/a"
c8 "$TMP/a" | grep -q '\[FAIL\]' && bad "pristine copy passes check 8" || ok "pristine copy passes check 8"

fixture "$TMP/b"
printf '\nRun `bash ~/.claude/hooks/nope.sh go`.\n' >> "$TMP/b/claude/skills/sidecar/SKILL.md"
c8 "$TMP/b" | grep -q 'nope.sh' && ok "skill ref to missing hook is reported" || bad "skill ref to missing hook is reported"
bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$TMP/b" >/dev/null 2>&1 && bad "missing hook exits non-zero" || ok "missing hook exits non-zero"

fixture "$TMP/c"
printf '\nRun `bash ~/.claude/hooks/nope.sh go`.\n' >> "$TMP/c/claude/agents/cody.md"
c8 "$TMP/c" | grep -q 'nope.sh' && ok "agent ref to missing hook is reported" || bad "agent ref to missing hook is reported"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
