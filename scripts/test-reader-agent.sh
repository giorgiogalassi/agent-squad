#!/usr/bin/env bash
# Tests for claude/agents/reader.md: frontmatter, contract headings, lint.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$REPO_ROOT/claude/agents/reader.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

grep -q '^model: sonnet$' "$F" && ok "model is sonnet" || bad "model is sonnet"
grep -q '^tools: Read, Grep, Glob$' "$F" && ok "tools are read-only" || bad "tools are read-only"

order="$(grep -E '^### ' "$F" | tr '\n' '|')"
want='### What this proposes|### How the existing system works, per this issue|### Guessed|### Inferred from code|### Blockers|'
[ "$order" = "$want" ] && ok "output headings in order" || bad "output headings in order: $order"

for c in 'schema' 'public API shape' 'new dependency' 'behaviour between units'; do
  grep -q "\*\*$c\*\*" "$F" && ok "category defined: $c" || bad "category defined: $c"
done
[ "$(grep -c 'Positive:' "$F")" -eq 4 ] && [ "$(grep -c 'Negative:' "$F")" -eq 4 ] && ok "one positive and one negative example each" || bad "examples per category"
grep -qi 'Internal choices are not blockers' "$F" && ok "internal choices not blockers" || bad "internal choices not blockers"
grep -qi 'never from the' "$F" && grep -q 'other issues in the batch' "$F" && ok "batch isolation stated" || bad "batch isolation stated"
grep -qi 'challenge' "$F" && bad "no prose dependency on challenge" || ok "no prose dependency on challenge"

out="$(cd "$REPO_ROOT" && bash scripts/squad-lint.sh 2>&1)"
echo "$out" | grep -q 'reader.md' && echo "$out" | grep -q 'No violations found' && ok "squad-lint passes with reader" || bad "squad-lint passes with reader"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
