#!/usr/bin/env bash
# Tests for claude/hooks/squad-readiness.sh (the `## Readiness` section of an issue
# body) and for LABEL_STATE_MACHINE.md row L10 (Chisel adds `blocked` at creation
# for an unresolved readiness blocker; BLOCKERS > 0 is the signal Chisel acts on).
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO_ROOT/claude/hooks/squad-readiness.sh"
. "$REPO_ROOT/scripts/lib/test-tmp.sh"
test_tmp_init test-squad-readiness TMP
PASS=0; FAIL=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "  expected: $2"; echo "  actual:   $3"; fi
}
key() { sed -n "s/^$1=//p" <<<"$OUT" | head -n 1; }

cat > "$TMP/reader.md" <<'EOS'
## Issue D1

### What this proposes
Persist jobs.

### Guessed
- the jobs table columns

### Inferred from code
- none

### Blockers
- schema: the jobs table columns are not defined.
- public API shape: the exit codes are not defined.

## Issue D2

### What this proposes
Rename a flag.

### Blockers
none

## Issue D3

### Blockers
- none
EOS
mkbody() { printf 'Title body line\n\nAcceptance criteria\n- one\n' > "$TMP/$1.md"; }
run() {  # run <body-name> <key> <mode>
  OUT="$(bash "$S" apply --body "$TMP/$1.md" --reader "$TMP/reader.md" --key "$2" --mode "$3" 2>"$TMP/err")"; RC=$?
}
sections() { grep -c '^## Readiness$' "$TMP/$1.md"; }

# blockers, connected
mkbody a; run a D1 connected
check "apply: rc/outcome/changed/blockers" "0/applied/yes/2" "$RC/$(key OUTCOME)/$(key CHANGED)/$(key BLOCKERS)"
check "apply: one section" "1" "$(sections a)"
check "apply: connected marker" "1" "$(grep -c '^Readiness: blocked (2)$' "$TMP/a.md")"
check "apply: no detached marker" "0" "$(grep -c '^Blocked: readiness$' "$TMP/a.md")"
check "apply: reader heading dropped" "0" "$(grep -c '^## Issue ' "$TMP/a.md")"
check "apply: other issue not leaked" "0" "$(grep -c 'Rename a flag' "$TMP/a.md")"
check "apply: body kept" "1" "$(grep -c '^- one$' "$TMP/a.md")"

# replace, not append (same key twice, then a different key)
run a D1 connected
check "re-run is unchanged" "0/unchanged/no" "$RC/$(key OUTCOME)/$(key CHANGED)"
check "re-run keeps one section" "1" "$(sections a)"
run a D2 connected
check "re-run with new result: blockers" "0/0" "$RC/$(key BLOCKERS)"
check "re-run with new result: one section" "1" "$(sections a)"
check "re-run with new result: old marker gone" "0" "$(grep -c '^Readiness: blocked' "$TMP/a.md")"
check "re-run with new result: new content" "1" "$(grep -c 'Rename a flag' "$TMP/a.md")"
check "re-run with new result: old content gone" "0" "$(grep -c 'Persist jobs' "$TMP/a.md")"

# L10: BLOCKERS > 0 is what Chisel turns into the blocked label and the marker line
mkbody b; run b D2 connected
check "L10 no blocker: BLOCKERS=0 and no marker" "0/0" "$(key BLOCKERS)/$(grep -c '^Readiness: blocked' "$TMP/b.md")"
mkbody b; run b D3 connected
check "L10 '- none' is not a blocker" "0" "$(key BLOCKERS)"
mkbody b; run b D1 connected
check "L10 open blockers: BLOCKERS=2 and marker" "2/1" "$(key BLOCKERS)/$(grep -c '^Readiness: blocked (2)$' "$TMP/b.md")"

# detached marker
mkbody c; run c D1 detached
check "detached: marker" "1/0" "$(grep -c '^Blocked: readiness$' "$TMP/c.md")/$(grep -c '^Readiness: blocked' "$TMP/c.md")"
check "detached: one section" "1" "$(sections c)"

# a section followed by another section keeps the later one
printf 'Intro\n\n## Readiness\nold\n\n## Notes\nkeep me\n' > "$TMP/d.md"; run d D2 connected
check "later section kept" "1/1" "$(grep -c '^keep me$' "$TMP/d.md")/$(grep -c '^## Notes$' "$TMP/d.md")"
check "old section text gone" "0" "$(grep -c '^old$' "$TMP/d.md")"

# failures
mkbody e; cp "$TMP/e.md" "$TMP/e.before"; run e NOPE connected
check "unknown key: exit 10, body untouched" "10/same" "$RC/$(cmp -s "$TMP/e.md" "$TMP/e.before" && echo same || echo diff)"
bash "$S" apply --body "$TMP/e.md" --reader "$TMP/reader.md" --key D1 --mode other >/dev/null 2>&1; check "bad mode: exit 2" "2" "$?"
bash "$S" apply --body "$TMP/e.md" >/dev/null 2>&1; check "missing args: exit 2" "2" "$?"
bash "$S" apply --body "$TMP/none.md" --reader "$TMP/reader.md" --key D1 --mode connected >/dev/null 2>&1; check "unreadable body: exit 20" "20" "$?"
bash "$S" bogus >/dev/null 2>&1; check "unknown verb: exit 2" "2" "$?"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
