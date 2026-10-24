#!/usr/bin/env bash
# Tests for check 7 (label doc rows tied to tests) of scripts/squad-lint.sh.
set -u
# Never write the real vault incident store.
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-lint-labels.XXXXXX")"
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
c7() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$1" 2>&1 | sed -n '/== 7/,/== summary/p'; }

fixture "$TMP/a"
c7 "$TMP/a" | grep -q '\[FAIL\]' && bad "pristine copy passes check 7" || ok "pristine copy passes check 7"

# row without a test
fixture "$TMP/b"
printf '| L99 | Extra | x | `squad-labels.sh extra` | connected | - | - | - | - |\n' >> "$TMP/b/LABEL_STATE_MACHINE.md"
c7 "$TMP/b" | grep -q 'row L99 has no test' && ok "row without test is reported" || bad "row without test is reported"
bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$TMP/b" >/dev/null 2>&1 && bad "row without test exits non-zero" || ok "row without test exits non-zero"

# test without a row
fixture "$TMP/c"
printf 'check "L99 extra: nothing" 0 0\n' >> "$TMP/c/scripts/test-squad-labels.sh"
c7 "$TMP/c" | grep -q 'test id L99 has no' && ok "test without row is reported" || bad "test without row is reported"
bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$TMP/c" >/dev/null 2>&1 && bad "test without row exits non-zero" || ok "test without row exits non-zero"

# not-script-performed row needs no test
fixture "$TMP/d"
# Portable insert (no sed \n in replacement): put the row before the "| D |" row.
awk '/^\| D \| / && !done { print "| L99 | Extra | x | not script-performed | connected | - | - | - | - |"; done=1 } { print }' "$TMP/d/LABEL_STATE_MACHINE.md" > "$TMP/d/doc.new" && mv "$TMP/d/doc.new" "$TMP/d/LABEL_STATE_MACHINE.md"
grep -q '^| L99 | Extra | x | not script-performed' "$TMP/d/LABEL_STATE_MACHINE.md" && ok "fixture D contains the extra row" || bad "fixture D contains the extra row"
c7 "$TMP/d" | grep -q '\[FAIL\]' && bad "human row needs no test" || ok "human row needs no test"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
