#!/usr/bin/env bash
# squad-route.sh -- deterministic routing from forge/output.yaml.
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq, no gh.
#
# Usage:
#   squad-route.sh recommend [--complexity <v> --change-type <v>] [--squad-dir <dir>]
#   squad-route.sh gate [--squad-dir <dir>] [--override]
#
# recommend: takes complexity and change_type from the flags (both or neither;
#   Forge passes them, so no output.yaml ordering dependency), else reads
#   forge/output.yaml; emits COMPLEXITY, CHANGE_TYPE, ROUTE. Both values are
#   validated. high -> "/archy -> /chisel"; otherwise change_type decides
#   (docs -> implement directly, code/mixed -> chisel pipeline).
# gate: for Chisel. Passes (GATE=ok) unless forge/output.yaml says
#   complexity: high and prd/current.md is missing (exit 10). No output.yaml
#   passes: Chisel's input is then the PRD. --override passes with GATE=override.
# Both verbs are read-only: they also emit OUTCOME=unchanged, CHANGED=no.
# Default <dir> is SQUAD_DIR from path-resolve.sh.
# Exit: 0 ok, 2 usage, 10 precondition failed, 20 path resolution failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
case "$VERB" in recommend|gate) ;; *) squad_fail 2 "usage: squad-route.sh recommend|gate [--complexity <v> --change-type <v>] [--squad-dir <dir>] [--override]" ;; esac
shift
SQUAD=""; OVERRIDE=no; ARG_C=""; ARG_T=""
while [ $# -gt 0 ]; do
  case "$1" in
    --squad-dir) [ $# -ge 2 ] || squad_fail 2 "--squad-dir requires a value"; SQUAD="$2"; shift 2 ;;
    --complexity) [ $# -ge 2 ] || squad_fail 2 "--complexity requires a value"; ARG_C="$2"; shift 2 ;;
    --change-type) [ $# -ge 2 ] || squad_fail 2 "--change-type requires a value"; ARG_T="$2"; shift 2 ;;
    --override) OVERRIDE=yes; shift ;;
    *) squad_fail 2 "unknown argument: $1" ;;
  esac
done

if [ -n "$ARG_C$ARG_T" ]; then
  [ "$VERB" = recommend ] || squad_fail 2 "--complexity/--change-type apply to recommend only"
  [ -n "$ARG_C" ] && [ -n "$ARG_T" ] || squad_fail 2 "--complexity and --change-type go together"
fi

if [ -z "$SQUAD" ] && [ -z "$ARG_C" ]; then
  SQUAD="$(bash "$(dirname "${BASH_SOURCE[0]}")/path-resolve.sh" 2>/dev/null | sed -n 's/^SQUAD_DIR=//p')"
  [ -n "$SQUAD" ] || squad_fail 20 "could not resolve SQUAD_DIR"
fi
YAML="$SQUAD/forge/output.yaml"

# Accepts bare, "double" or 'single' quoted values.
field() { sed -n "s/^$1:[[:space:]]*[\"']\{0,1\}\([A-Za-z]*\).*/\1/p" "$YAML" | head -n 1; }

if [ -n "$ARG_C" ]; then
  COMPLEXITY="$ARG_C"; CHANGE="$ARG_T"; SRC_C="--complexity"; SRC_T="--change-type"
else
  if [ ! -f "$YAML" ]; then
    [ "$VERB" = gate ] && { squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit GATE ok; exit 0; }
    squad_fail 10 "no forge/output.yaml in $SQUAD"
  fi
  COMPLEXITY="$(field complexity)"
  CHANGE="$(field change_type)"
  SRC_C="output.yaml: complexity"; SRC_T="output.yaml: change_type"
fi
case "$COMPLEXITY" in low|medium|high) ;; *) squad_fail 10 "$SRC_C must be low|medium|high" ;; esac
[ "$VERB" = recommend ] && { case "$CHANGE" in code|docs|mixed) ;; *) squad_fail 10 "$SRC_T must be code|docs|mixed" ;; esac; }

if [ "$VERB" = gate ]; then
  if [ "$COMPLEXITY" = high ] && [ ! -f "$SQUAD/prd/current.md" ]; then
    if [ "$OVERRIDE" = yes ]; then squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit GATE override; exit 0; fi
    squad_fail 10 "complexity: high and no PRD - run /archy first"
  fi
  squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit GATE ok
  exit 0
fi

if [ "$COMPLEXITY" = high ]; then
  ROUTE="/archy -> /chisel"
else
  case "$CHANGE" in
    docs) ROUTE="implement directly (or /chisel for tracking)" ;;
    code|mixed) ROUTE="chisel pipeline" ;;
    *) ROUTE="" ;;
  esac
fi
squad_emit OUTCOME unchanged; squad_emit CHANGED no
squad_emit COMPLEXITY "$COMPLEXITY"; squad_emit CHANGE_TYPE "$CHANGE"; squad_emit ROUTE "$ROUTE"
