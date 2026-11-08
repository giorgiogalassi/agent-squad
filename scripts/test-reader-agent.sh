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
grep -Eqi '(read|load|invoke|use|run|see)[^.]{0,20}challenge(\.md)?' "$F" && bad "no dependency on challenge" || ok "no dependency on challenge"
grep -qi 'before opening the repo' "$F" && grep -qi 'defined in the' "$F" && ok "issue-text pass precedes repo read" || bad "issue-text pass precedes repo read"
grep -qi 'resolved' "$F" && grep -qi 'by assumption is a blocker' "$F" && ok "assumed category item is a blocker" || bad "assumed category item is a blocker"
grep -qi 'goes in `Guessed`' "$F" && ok "batch-only definition is guessed" || bad "batch-only definition is guessed"
for c in schema-blocker internal-choice-no-blocker batch-names-schema; do
  [ -f "$REPO_ROOT/claude/evals/reader-blockers/graders/$c.md" ] && ok "eval grader: $c" || bad "eval grader: $c"
done

# Grader self-check: run each regex against a correct and a fluent-filler sample.
. "$REPO_ROOT/scripts/lib/test-tmp.sh"
test_tmp_init test-reader-agent SAMPLES
cat > "$SAMPLES/good.txt" <<'EOS'
RUN A
### What this proposes
Persist jobs.
### Blockers
- schema: the issue never defines the jobs table columns.
RUN B
### Blockers
none
RUN C
Issue 1
### Blockers
none
Issue 3
### What this proposes
Read the queue.
### Guessed
- the shape of queue.json entries is defined only in another issue.
### Blockers
none
EOS
cat > "$SAMPLES/filler.txt" <<'EOS'
RUN A
### What this proposes
Persist jobs; the schema is straightforward and I assumed it.
### Blockers
none
RUN B
### Blockers
none, the internal choice is just a naming detail.
RUN C
Issue 3
### What this proposes
Read queue.json and its fields as usual.
### Guessed
none
### Blockers
none
EOS
grader_match() { # grader sample -> prints 1/0
  python3 - "$REPO_ROOT/claude/evals/reader-blockers/graders/$1.md" "$SAMPLES/$2.txt" <<'EOP'
import re, sys
meta = open(sys.argv[1]).read().split('---')[1]
pat = re.search(r'^pattern: "(.*)"$', meta, re.M).group(1).replace('\\\\', '\\')
fl = re.search(r'^flags: "(.*)"$', meta, re.M).group(1)
f = (re.I if 'i' in fl else 0) | (re.S if 's' in fl else 0)
print(1 if re.search(pat, open(sys.argv[2]).read(), f) else 0)
EOP
}
[ "$(grader_match schema-blocker good)" = 1 ] && [ "$(grader_match schema-blocker filler)" = 0 ] && ok "grader schema-blocker: correct matches, filler does not" || bad "grader schema-blocker self-check"
[ "$(grader_match batch-names-schema good)" = 1 ] && [ "$(grader_match batch-names-schema filler)" = 0 ] && ok "grader batch-names-schema: correct matches, filler does not" || bad "grader batch-names-schema self-check"
[ "$(grader_match internal-choice-no-blocker good)" = 1 ] && [ "$(grader_match internal-choice-no-blocker filler)" = 1 ] && ok "grader internal-choice-no-blocker: none (with trailing note) matches" || bad "grader internal-choice-no-blocker self-check"

out="$(cd "$REPO_ROOT" && bash scripts/squad-lint.sh 2>&1)"
echo "$out" | grep -q 'reader.md' && echo "$out" | grep -q 'No violations found' && ok "squad-lint passes with reader" || bad "squad-lint passes with reader"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
