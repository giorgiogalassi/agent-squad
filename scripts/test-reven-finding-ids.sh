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

has 'Evidence you can re-read' "re-readable evidence decides"
has 'cannot re-read is ruled `FINDING_UPHELD`' "unreadable evidence upheld"
has 'is removed from `## Blocking issues`' "withdrawn leaves blocking list"
has 'never CHANGES REQUESTED with an empty list' "no empty CHANGES REQUESTED"
has 're-list every still-unresolved prior finding under its original' "re-review carry-over"
has 'even when the reading scope is only the fix diff' "carry-over on fix diff"

has "no nit tier" "states no nit tier"
has 'explicitly rejects or replaces' "rejected approach rule"
has 'never an Observation' "rejected approach is blocking"
has '## Orphan check' "orphan check section"
has 'Both directions count' "orphan check both directions"
has 'readers of it remain' "removed writer, remaining readers"
has '"Left for a later' "later-issue exemption narrowed"
has 'Identifiers you did not check' "unchecked identifiers go under Not read"
has 'compare the two parsers' "parser comparison"
has 'repeats a case another spec' "duplicate tests non-blocking"
has '<N> identifiers checked, <M> orphans' "orphan line under Orphan check heading"
has 'Batch the greps' "orphan greps batched"
has 'do not by themselves' "unchecked identifiers do not force INCOMPLETE"
has 'or the project'"'"'s' "orphan kinds stack-agnostic"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
