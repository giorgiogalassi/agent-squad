#!/usr/bin/env bash
# Tests for check 15 (interface-level categories defined once) and the
# "tested in" form of check 7 in scripts/squad-lint.sh.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-lint-chisel TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

fixture() {
  mkdir -p "$1/scripts"
  cp -R "$REPO_ROOT/claude" "$1/claude"
  cp "$REPO_ROOT/scripts/lint-allowlist-1b.txt" "$REPO_ROOT"/scripts/test-squad-labels.sh "$REPO_ROOT"/scripts/test-squad-readiness.sh "$1/scripts/"
  cp -R "$REPO_ROOT/scripts/lib" "$1/scripts/lib"
  cp "$REPO_ROOT"/*.md "$1/" 2>/dev/null
  return 0
}
sec() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$1" 2>&1 | sed -n "/== $2/,/== summary\|^$/p"; }

fixture "$TMP/a"
sec "$TMP/a" 15 | grep -q '\[FAIL\]' && bad "pristine chisel passes check 15" || ok "pristine chisel passes check 15"
sec "$TMP/a" 7 | grep -q '\[FAIL\]' && bad "pristine L10 row passes check 7" || ok "pristine L10 row passes check 7"
grep -q '^| L10 ' "$REPO_ROOT/LABEL_STATE_MACHINE.md" && ok "L10 row exists" || bad "L10 row exists"

# Chisel restating the categories fails
fixture "$TMP/b"
printf '\nDecide schema, public API shape, new dependency and behaviour between units.\n' >> "$TMP/b/claude/skills/chisel/SKILL.md"
sec "$TMP/b" 15 | grep -q 'restates the interface-level categories' && ok "restated categories are reported" || bad "restated categories are reported"
bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$TMP/b" >/dev/null 2>&1 && bad "restated categories exit non-zero" || ok "restated categories exit non-zero"

# L10 without a test fails check 7
fixture "$TMP/c"
sed -i.bak '/check "L10 /d' "$TMP/c/scripts/test-squad-readiness.sh" && rm -f "$TMP/c/scripts/test-squad-readiness.sh.bak"
sec "$TMP/c" 7 | grep -q 'row L10 names scripts/test-squad-readiness.sh' && ok "L10 without a test is reported" || bad "L10 without a test is reported"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
