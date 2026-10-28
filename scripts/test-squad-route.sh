#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-route.sh. Plain bash 3.2; no bats, no jq.
# Usage: scripts/test-squad-route.sh
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$REPO_ROOT/claude/hooks/squad-route.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-route
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

# mk <name> <complexity> <change_type> [prd]: squad dir with forge/output.yaml
mk() {
  local d="$TMPROOT/$1"
  mkdir -p "$d/forge" "$d/prd"
  printf 'type: feature\ncomplexity: %s\nchange_type: %s\nscope: ""\n' "$2" "$3" > "$d/forge/output.yaml"
  [ "${4:-}" = prd ] && echo "# PRD" > "$d/prd/current.md"
  echo "$d"
}
run() { OUT="$("$SUT" "$@" 2>"$TMPROOT/err")"; RC=$?; ERR="$(cat "$TMPROOT/err")"; }
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

# recommend
d="$(mk hi high code)"; run recommend --squad-dir "$d"
check "recommend high/code rc" 0 "$RC"
check "recommend high/code path" "/archy -> /chisel" "$(key ROUTE)"
check "recommend high keys" "high" "$(key COMPLEXITY)"
d="$(mk hid high docs)"; run recommend --squad-dir "$d"
check "recommend high/docs still archy" "/archy -> /chisel" "$(key ROUTE)"
d="$(mk lo low code)"; run recommend --squad-dir "$d"
check "recommend low/code" "chisel pipeline" "$(key ROUTE)"
d="$(mk med medium mixed)"; run recommend --squad-dir "$d"
check "recommend medium/mixed" "chisel pipeline" "$(key ROUTE)"
d="$(mk docs medium docs)"; run recommend --squad-dir "$d"
check "recommend medium/docs" "implement directly (or /chisel for tracking)" "$(key ROUTE)"
d="$(mk bad urgent code)"; run recommend --squad-dir "$d"
check "recommend invalid complexity rc" 10 "$RC"
rm -rf "$TMPROOT/none"; mkdir -p "$TMPROOT/none"; run recommend --squad-dir "$TMPROOT/none"
check "recommend missing yaml rc" 10 "$RC"
run recommend --squad-dir
check "recommend usage rc" 2 "$RC"
run bogus
check "unknown verb rc" 2 "$RC"

# recommend with explicit values: no file dependency
rm -rf "$TMPROOT/none"; mkdir -p "$TMPROOT/none"
run recommend --squad-dir "$TMPROOT/none" --complexity high --change-type code
check "recommend args, no yaml rc" 0 "$RC"
check "recommend args high" "/archy -> /chisel" "$(key ROUTE)"
d="$(mk stale low code)"; run recommend --squad-dir "$d" --complexity high --change-type docs
check "recommend args win over stale yaml" "/archy -> /chisel" "$(key ROUTE)"
run recommend --squad-dir "$d" --complexity low --change-type docs
check "recommend args low/docs" "implement directly (or /chisel for tracking)" "$(key ROUTE)"
run recommend --squad-dir "$d" --complexity urgent --change-type code
check "recommend args invalid complexity rc" 10 "$RC"
run recommend --squad-dir "$d" --complexity low
check "recommend args need both rc" 2 "$RC"
run recommend --squad-dir "$d" --change-type code
check "recommend change-type alone rc" 2 "$RC"
run recommend --squad-dir "$d" --complexity low --change-type code
check "recommend emits OUTCOME" "unchanged" "$(key OUTCOME)"
check "recommend emits CHANGED" "no" "$(key CHANGED)"
d="$(mk gq high code)"; run gate --squad-dir "$d" --override
check "gate emits OUTCOME" "unchanged" "$(key OUTCOME)"
check "gate emits CHANGED" "no" "$(key CHANGED)"

# change_type is validated on every path and the message names its source
run recommend --complexity high --change-type bogus
check "recommend args high bad change-type rc" 10 "$RC"
check "recommend args high bad change-type stdout" "" "$OUT"
case "$ERR" in *"--change-type must be code|docs|mixed"*) ok "flag source named" ;; *) bad "flag source named ($ERR)" ;; esac
run recommend --complexity low --change-type bogus
case "$ERR" in *"--change-type must be code|docs|mixed"*) ok "flag source named (low)" ;; *) bad "flag source named low ($ERR)" ;; esac
d="$(mk yb high bogus)"; run recommend --squad-dir "$d"
check "recommend yaml high bad change_type rc" 10 "$RC"
case "$ERR" in *"output.yaml: change_type must be code|docs|mixed"*) ok "yaml source named" ;; *) bad "yaml source named ($ERR)" ;; esac

# quoted yaml values
d="$TMPROOT/quoted"; mkdir -p "$d/forge"
printf 'complexity: "high"\nchange_type: '"'"'code'"'"'  # note\n' > "$d/forge/output.yaml"
run recommend --squad-dir "$d"
check "quoted yaml values rc" 0 "$RC"
check "quoted yaml high" "/archy -> /chisel" "$(key ROUTE)"
run gate --squad-dir "$d"
check "quoted yaml gate high no prd rc" 10 "$RC"

# gate
d="$(mk g1 high code)"; run gate --squad-dir "$d"
check "gate high no prd rc" 10 "$RC"
case "$ERR" in *"complexity: high and no PRD - run /archy first"*) ok "gate names archy" ;; *) bad "gate names archy ($ERR)" ;; esac
check "gate high no prd stdout" "" "$OUT"
d="$(mk g2 high code prd)"; run gate --squad-dir "$d"
check "gate high with prd rc" 0 "$RC"
check "gate high with prd outcome" "ok" "$(key GATE)"
d="$(mk g3 low code)"; run gate --squad-dir "$d"
check "gate low rc" 0 "$RC"
d="$(mk g4 medium docs)"; run gate --squad-dir "$d"
check "gate medium rc" 0 "$RC"
d="$(mk g5 high code)"; run gate --squad-dir "$d" --override
check "gate override rc" 0 "$RC"
check "gate override outcome" "override" "$(key GATE)"
d="$(mk g6 high code)"; rm "$d/forge/output.yaml"; run gate --squad-dir "$d"
check "gate no yaml passes (PRD-only input)" 0 "$RC"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
