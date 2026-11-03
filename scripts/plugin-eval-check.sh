#!/usr/bin/env bash
# Decide whether a `claude plugin eval` run produced any real score (#323).
# Used by .github/workflows/plugin-eval.yml so a run in which every case
# errored before starting (missing sandbox deps, empty API key) is red
# instead of "All graders passed".
#
# Usage: scripts/plugin-eval-check.sh <results.json>
#
# Reads the aggregate result: top-level costUsd and cases[].arms.<arm>[] runs
# (each with score, error, costUsd). A run is scored when error is null and
# score is a number.
#
# Stdout (SCRIPT_CONTRACT.md): KEY=value lines
#   OUTCOME=pass|fail
#   REASON=<short text>
#   RUNS=<total runs>  SCORED=<scored runs>  COST_USD=<top-level cost>
# Exit: 0 at least one scored run and a non-zero cost, 2 usage error,
#       10 nothing scored or cost 0 (OUTCOME=fail),
#       20 results file missing or not parseable as JSON.
set -u
[ $# -eq 1 ] || { echo "usage: plugin-eval-check.sh <results.json>" >&2; exit 2; }
f="$1"
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 20; }
[ -f "$f" ] || { echo "error: results file not found: $f" >&2; exit 20; }
jq -e . "$f" >/dev/null 2>&1 || { echo "error: not valid JSON: $f" >&2; exit 20; }

stats="$(jq -r '
  [(.cases // [])[] | (.arms // {}) | to_entries[] | .value[]?] as $runs
  | [($runs | length),
     ($runs | map(select(.error == null and (.score | type) == "number")) | length),
     (.costUsd // 0)] | @tsv' "$f" 2>/dev/null)" \
  || { echo "error: unexpected results.json shape: $f" >&2; exit 20; }
runs="$(printf '%s' "$stats" | cut -f1)"
scored="$(printf '%s' "$stats" | cut -f2)"
cost="$(printf '%s' "$stats" | cut -f3)"
[ -n "$runs" ] && [ -n "$scored" ] || { echo "error: unexpected results.json shape: $f" >&2; exit 20; }

emit() { printf 'OUTCOME=%s\nREASON=%s\nRUNS=%s\nSCORED=%s\nCOST_USD=%s\n' "$1" "$2" "$runs" "$scored" "$cost"; }
if [ "$scored" -eq 0 ]; then
  emit fail "no case produced a score ($runs runs, all errored or unscored)"; exit 10
fi
if [ "$(jq -n --argjson c "$cost" '$c > 0')" != "true" ]; then
  emit fail "costUsd is 0, so no model call was made"; exit 10
fi
emit pass "$scored of $runs runs scored"
exit 0
