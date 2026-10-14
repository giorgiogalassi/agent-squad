#!/usr/bin/env bash
# Tests for check 6 (gh write ban) of scripts/squad-lint.sh.
# Copies the repo's claude/ tree and lint inputs into a fixture and mutates it.
set -u
# Never write the real vault incident store.
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-lint-gh.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

fixture() {  # fixture <dir>
  mkdir -p "$1/scripts"
  cp -R "$REPO_ROOT/claude" "$1/claude"
  cp "$REPO_ROOT/scripts/lint-allowlist-1b.txt" "$REPO_ROOT/scripts/test-squad-labels.sh" "$1/scripts/"
  cp "$REPO_ROOT"/*.md "$1/" 2>/dev/null
  [ -d "$REPO_ROOT/codex" ] && cp -R "$REPO_ROOT/codex" "$1/codex"
  return 0
}
run() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$1" 2>&1; }

# 1. pristine fixture passes check 6
fixture "$TMP/a"
out="$(run "$TMP/a")"
if printf '%s\n' "$out" | sed -n '/== 6/,/== summary/p' | grep -q '\[FAIL\]'; then bad "clean copy passes check 6"; else ok "clean copy passes check 6"; fi

# 2. a raw label write in cody.md fails
fixture "$TMP/b"
printf '\nRun gh issue edit 1 --add-label x now.\n' >> "$TMP/b/claude/agents/cody.md"
out="$(run "$TMP/b")"; rc=$?
printf '%s\n' "$out" | grep -q 'cody.md:.*gh issue edit 1' && ok "bad cody.md is reported" || bad "bad cody.md is reported"
bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$TMP/b" >/dev/null 2>&1 && bad "bad cody.md exits non-zero" || ok "bad cody.md exits non-zero"

# 3. lint:gh-ok on the same line silences it
fixture "$TMP/c"
printf '\nRun gh issue edit 1 --add-label x now. <!-- lint:gh-ok -->\n' >> "$TMP/c/claude/agents/cody.md"
out="$(run "$TMP/c")"
printf '%s\n' "$out" | sed -n '/== 6/,/== summary/p' | grep -q '\[FAIL\]' && bad "lint:gh-ok line is accepted" || ok "lint:gh-ok line is accepted"

# 4. allowlist entry without a retires tag fails
fixture "$TMP/d"
printf 'claude/agents/cody.md|^gh pr create\n' >> "$TMP/d/scripts/lint-allowlist-1b.txt"
out="$(run "$TMP/d")"
printf '%s\n' "$out" | grep -q 'lint-allowlist-1b.txt:.*retires' && ok "tag-less allowlist line is reported" || bad "tag-less allowlist line is reported"
bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$TMP/d" >/dev/null 2>&1 && bad "tag-less allowlist exits non-zero" || ok "tag-less allowlist exits non-zero"

# 5. gh api graphql: query allowed, mutation fenced block rejected
fixture "$TMP/e"
printf '\n```bash\ngh api graphql -f query=%s\n```\n' "'query { x }'" >> "$TMP/e/claude/agents/cody.md"
out="$(run "$TMP/e")"
printf '%s\n' "$out" | sed -n '/== 6/,/== summary/p' | grep -q '\[FAIL\]' && bad "graphql query is a read" || ok "graphql query is a read"
fixture "$TMP/f"
printf '\n```bash\ngh api graphql -f query=%s\n# mutation\n```\n' "'x'" >> "$TMP/f/claude/agents/cody.md"
out="$(run "$TMP/f")"
printf '%s\n' "$out" | grep -q 'cody.md:.*gh api graphql' && ok "graphql in a mutation block is rejected" || bad "graphql in a mutation block is rejected"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
