#!/usr/bin/env bash
# Tests claude/hooks/lore-orient.sh output shape. Plain bash 3.2; needs jq to validate.
set -u
# Never write the real vault incident store.
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
JQ="$(command -v jq)" || { echo "jq required to validate output"; exit 1; }
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-lore-orient.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

# Hooks dir copy with path-resolve.sh alongside, as installed.
mkdir -p "$TMPROOT/hooks" "$TMPROOT/nojq"
cp "$REPO_ROOT/claude/hooks/lore-orient.sh" "$REPO_ROOT/claude/hooks/path-resolve.sh" "$TMPROOT/hooks/"
# PATH without jq: symlink the tools the hook needs, minus jq.
for t in bash git cat sed awk grep dirname basename tr wc head tail sort date stat ls mkdir cut find; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$TMPROOT/nojq/$t"
done

out="$("$MK" connected)"
F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
FIXROOTS="$F_ROOT"
# Awkward characters to prove escaping round-trips without doubling.
mkdir -p "$F_VAULT/projects/fixture"
printf '# Status\nquote " backslash \\ tab\tend\n' > "$F_VAULT/projects/fixture/status.md"
# Without jq the real path-resolve.sh cannot read the mapping, so the full
# output is only reachable via a stub that supplies it; this exercises the printf branch.
mkdir -p "$TMPROOT/hooks-nojq"
cp "$REPO_ROOT/claude/hooks/lore-orient.sh" "$TMPROOT/hooks-nojq/"
cat > "$TMPROOT/hooks-nojq/path-resolve.sh" <<EOP
#!/usr/bin/env bash
echo "VAULT_PATH=$F_VAULT"; echo "PROJECT_ROOT=$F_PROJECT"; echo "DISPLAY_NAME=fixture"; echo "SQUAD_DIR=$F_VAULT/projects/fixture/.squad"
EOP
chmod +x "$TMPROOT/hooks-nojq/path-resolve.sh"

CHECK='.hookSpecificOutput.hookEventName == "SessionStart"
  and (.hookSpecificOutput.additionalContext | length > 0)
  and (has("additionalContext") | not)
  and (.hookSpecificOutput.additionalContext == .systemMessage)'
MARK='quote " backslash \ tab'$'\t''end'
check_shape() {  # check_shape <label> <json>
  if printf '%s' "$2" | "$JQ" -e "$CHECK" >/dev/null 2>&1; then ok "$1 shape"; else bad "$1 shape: $2"; fi
  if printf '%s' "$2" | "$JQ" -e --arg m "$MARK" '.hookSpecificOutput.additionalContext | contains($m)' >/dev/null 2>&1; then ok "$1 escaping round-trips"; else bad "$1 escaping"; fi
}

j="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null)"
check_shape "jq" "$j"
n="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/nojq" bash "$TMPROOT/hooks-nojq/lore-orient.sh" 2>/dev/null)"
check_shape "no-jq" "$n"

# msg-only path (no vault): systemMessage only, both branches.
for mode in jq nojq; do
  if [ "$mode" = jq ]; then P="$PATH"; else P="$TMPROOT/nojq"; fi
  m="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$TMPROOT/missing" PATH="$P" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null)"
  if printf '%s' "$m" | "$JQ" -e '(keys == ["systemMessage"]) and (.systemMessage | length > 0)' >/dev/null 2>&1; then
    ok "msg-only $mode"; else bad "msg-only $mode: $m"; fi
done

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
