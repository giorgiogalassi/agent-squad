#!/usr/bin/env bash
# Tests for claude/agents/reven.md: finding IDs and contest rulings contract.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$REPO_ROOT/claude/agents/reven.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
has() { grep -qF -- "$1" "$F" && ok "$2" || bad "$2"; }

has '- B<n> [file:line] description and required fix' "blocking issue format"
has 'B<n>: FINDING_UPHELD <reason>' "upheld ruling line"
has 'B<n>: FINDING_WITHDRAWN <reason>' "withdrawn ruling line"
has 'A wish to' "wish is not evidence"
has 'contest is not evidence' "wish is not evidence (cont.)"
has 'cannot be contested again' "upheld not re-contestable"
has 'highest ID' "numbering continues from brief"
has 'Verdict: APPROVED | CHANGES REQUESTED | COMMENT | INCOMPLETE' "verdicts unchanged"

has "no nit tier" "states no nit tier"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
