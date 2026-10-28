#!/usr/bin/env bash
# squad-route.sh -- deterministic routing from forge/output.yaml.
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq, no gh.
#
# Usage:
#   squad-route.sh recommend [--squad-dir <dir>]
#   squad-route.sh gate [--squad-dir <dir>] [--override]
#
# recommend: reads complexity and change_type; emits COMPLEXITY, CHANGE_TYPE,
#   ROUTE. high -> "/archy -> /chisel"; otherwise change_type decides
#   (docs -> implement directly, code/mixed -> chisel pipeline).
# gate: for Chisel. Passes (GATE=ok) unless forge/output.yaml says
#   complexity: high and prd/current.md is missing (exit 10). No output.yaml
#   passes: Chisel's input is then the PRD. --override passes with GATE=override.
# Default <dir> is SQUAD_DIR from path-resolve.sh.
# Exit: 0 ok, 2 usage, 10 precondition failed, 20 path resolution failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
case "$VERB" in recommend|gate) ;; *) squad_fail 2 "usage: squad-route.sh recommend|gate [--squad-dir <dir>] [--override]" ;; esac
shift
SQUAD=""; OVERRIDE=no
while [ $# -gt 0 ]; do
  case "$1" in
    --squad-dir) [ $# -ge 2 ] || squad_fail 2 "--squad-dir requires a value"; SQUAD="$2"; shift 2 ;;
    --override) OVERRIDE=yes; shift ;;
    *) squad_fail 2 "unknown argument: $1" ;;
  esac
done

if [ -z "$SQUAD" ]; then
  SQUAD="$(bash "$(dirname "${BASH_SOURCE[0]}")/path-resolve.sh" 2>/dev/null | sed -n 's/^SQUAD_DIR=//p')"
  [ -n "$SQUAD" ] || squad_fail 20 "could not resolve SQUAD_DIR"
fi
YAML="$SQUAD/forge/output.yaml"

field() { sed -n "s/^$1:[[:space:]]*\([A-Za-z]*\).*/\1/p" "$YAML" | head -n 1; }

if [ ! -f "$YAML" ]; then
  [ "$VERB" = gate ] && { squad_emit GATE ok; exit 0; }
  squad_fail 10 "no forge/output.yaml in $SQUAD"
fi
COMPLEXITY="$(field complexity)"
CHANGE="$(field change_type)"
case "$COMPLEXITY" in low|medium|high) ;; *) squad_fail 10 "output.yaml: complexity must be low|medium|high" ;; esac

if [ "$VERB" = gate ]; then
  if [ "$COMPLEXITY" = high ] && [ ! -f "$SQUAD/prd/current.md" ]; then
    if [ "$OVERRIDE" = yes ]; then squad_emit GATE override; exit 0; fi
    squad_fail 10 "complexity: high and no PRD - run /archy first"
  fi
  squad_emit GATE ok
  exit 0
fi

if [ "$COMPLEXITY" = high ]; then
  ROUTE="/archy -> /chisel"
else
  case "$CHANGE" in
    docs) ROUTE="implement directly (or /chisel for tracking)" ;;
    code|mixed) ROUTE="chisel pipeline" ;;
    *) squad_fail 10 "output.yaml: change_type must be code|docs|mixed" ;;
  esac
fi
squad_emit COMPLEXITY "$COMPLEXITY"; squad_emit CHANGE_TYPE "$CHANGE"; squad_emit ROUTE "$ROUTE"
