#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-route.sh. Plain bash 3.2; no bats, no jq.
# Usage: scripts/test-squad-route.sh
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$REPO_ROOT/claude/hooks/squad-route.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-route.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
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
