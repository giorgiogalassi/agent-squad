#!/usr/bin/env bash
# Tests for checks 8 (referenced hooks exist) and 9 (plugin layout) of scripts/squad-lint.sh.
set -u
# Never write the real vault incident store.
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-lint-hooks TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

fixture() {  # fixture <dir>
  mkdir -p "$1/scripts"
  cp -R "$REPO_ROOT/claude" "$1/claude"
  cp "$REPO_ROOT/scripts/lint-allowlist-1b.txt" "$REPO_ROOT/scripts/test-squad-labels.sh" "$1/scripts/"
  cp -R "$REPO_ROOT/scripts/lib" "$1/scripts/lib"
  cp "$REPO_ROOT"/*.md "$1/" 2>/dev/null
  return 0
}
c8() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$1" 2>&1 | sed -n '/== 8/,/== summary/p'; }

fixture "$TMP/a"
c8 "$TMP/a" | grep -q '\[FAIL\]' && bad "pristine copy passes check 8" || ok "pristine copy passes check 8"

fixture "$TMP/b"
printf '\nRun `bash ${CLAUDE_PLUGIN_ROOT}/hooks/nope.sh go`.\n' >> "$TMP/b/claude/skills/seed/SKILL.md"
c8 "$TMP/b" | grep -q 'nope.sh' && ok "skill ref to missing hook is reported" || bad "skill ref to missing hook is reported"
bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$TMP/b" >/dev/null 2>&1 && bad "missing hook exits non-zero" || ok "missing hook exits non-zero"

fixture "$TMP/c"
printf '\nRun `bash ${CLAUDE_PLUGIN_ROOT}/hooks/nope.sh go`.\n' >> "$TMP/c/claude/agents/cody.md"
c8 "$TMP/c" | grep -q 'nope.sh' && ok "agent ref to missing hook is reported" || bad "agent ref to missing hook is reported"

# Check 9: plugin layout.
c9() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$1" 2>&1 | sed -n '/== 9/,/== summary/p'; }
c9 "$TMP/a" | grep -q '\[FAIL\]' && bad "pristine copy passes check 9" || ok "pristine copy passes check 9"

fixture "$TMP/d"
printf '\nRun `bash ~/.claude/hooks/path-resolve.sh`.\n' >> "$TMP/d/claude/skills/seed/SKILL.md"
c8 "$TMP/d" | grep -q 'plugin root' && ok "copy-install path is reported" || bad "copy-install path is reported"

fixture "$TMP/e"
sed -i.bak 's#lore-orient.sh#lore-gone.sh#' "$TMP/e/claude/hooks/hooks.json"
c9 "$TMP/e" | grep -q 'lore-orient.sh' && ok "hooks.json missing registration is reported" || bad "hooks.json missing registration is reported"

fixture "$TMP/f"
{ printf -- '---\npermissionMode: plan\n'; sed '1d' "$TMP/f/claude/agents/cody.md"; } > "$TMP/f/cody.new"
mv "$TMP/f/cody.new" "$TMP/f/claude/agents/cody.md"
c9 "$TMP/f" | grep -q "permissionMode" && ok "ignored agent frontmatter key is reported" || bad "ignored agent frontmatter key is reported"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
