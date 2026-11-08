#!/usr/bin/env bash
# squad-fix-parse.sh -- parse Cody's typed fix-round response into routing keys.
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq.
#
# Usage:
#   squad-fix-parse.sh --input <file|-> --open <B1,B2,...> [--upheld <B2,...>]
#
#   --input   Cody's fix-round output (a file, or - for stdin). Blank lines are
#             ignored; every other line must be one of
#               B<n>: FIX
#               B<n>: CONTEST <evidence>
#               B<n>: ESCALATE <reason>
#   --open    comma list of the finding IDs still open (ID format: claude/agents/reven.md)
#   --upheld  comma list of IDs already ruled FINDING_UPHELD; these allow FIX or ESCALATE only
#
# Stdout: FIXES=, CONTESTS=, ESCALATIONS=, MISSING= (comma lists, empty allowed), in
# order of the open list. Printed on exit 0 and on exit 10 (best effort, so the caller
# can see what is missing). Nothing is printed on exit 2.
# Exit: 0 every open ID answered once and validly, 2 usage,
#       10 missing, duplicate or unknown ID, malformed line, or CONTEST on an upheld ID.
# Stderr: one reason line per problem.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

INPUT=""; OPEN=""; UPHELD=""; HAVE_OPEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --input|--open|--upheld)
      [ $# -ge 2 ] || squad_fail 2 "$1 requires a value"
      case "$1" in
        --input) INPUT="$2" ;; --open) OPEN="$2"; HAVE_OPEN=1 ;; --upheld) UPHELD="$2" ;;
      esac
      shift 2 ;;
    *) squad_fail 2 "unknown argument '$1'" ;;
  esac
done
[ -n "$INPUT" ] || squad_fail 2 "usage: squad-fix-parse.sh --input <file|-> --open <ids> [--upheld <ids>]"
[ "$HAVE_OPEN" -eq 1 ] || squad_fail 2 "--open is required"
if [ "$INPUT" != "-" ] && [ ! -f "$INPUT" ]; then squad_fail 2 "input file not found: $INPUT"; fi

ID_RE='^B[0-9]+$'
# Normalize "B1, B2" to " B1 B2 " for membership tests; validate every ID.
norm() {
  local out="" id
  for id in $(printf '%s' "$1" | tr ',' ' '); do
    [[ "$id" =~ $ID_RE ]] || return 1
    out="$out $id"
  done
  printf '%s ' "$out"
}
OPEN_N="$(norm "$OPEN")" || squad_fail 2 "--open holds an invalid finding ID"
UPHELD_N="$(norm "$UPHELD")" || squad_fail 2 "--upheld holds an invalid finding ID"
in_list() { case "$2" in *" $1 "*) return 0 ;; esac; return 1; }

if [ "$INPUT" = "-" ]; then TEXT="$(cat)"; else TEXT="$(cat "$INPUT")"; fi

ERR=0
problem() { ERR=1; printf '%s\n' "$1" >&2; }
SEEN=" "; FIXES=""; CONTESTS=""; ESCS=""
LINE_RE='^(B[0-9]+): (FIX|CONTEST [^[:space:]].*|ESCALATE [^[:space:]].*)$'
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  if ! [[ "$line" =~ $LINE_RE ]]; then
    problem "malformed line: $line"; continue
  fi
  id="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  if in_list "$id" "$SEEN"; then problem "duplicate ID $id"; continue; fi
  SEEN="$SEEN$id "
  if ! in_list "$id" "$OPEN_N"; then problem "unknown ID $id (not open)"; continue; fi
  case "$rest" in
    FIX) FIXES="$FIXES $id" ;;
    CONTEST*)
      if in_list "$id" "$UPHELD_N"; then problem "$id already FINDING_UPHELD: only FIX or ESCALATE"; continue; fi
      CONTESTS="$CONTESTS $id" ;;
    ESCALATE*) ESCS="$ESCS $id" ;;
  esac
done <<EOT
$TEXT
EOT

MISSING=""
for id in $OPEN_N; do
  in_list "$id" "$SEEN" || { MISSING="$MISSING $id"; problem "missing answer for $id"; }
done

csv() { printf '%s' "$1" | sed -e 's/^ *//' -e 's/ /,/g'; }
printf 'FIXES=%s\nCONTESTS=%s\nESCALATIONS=%s\nMISSING=%s\n' \
  "$(csv "$FIXES")" "$(csv "$CONTESTS")" "$(csv "$ESCS")" "$(csv "$MISSING")"
[ "$ERR" -eq 0 ] || exit 10
exit 0
