#!/usr/bin/env bash
# squad-fix-parse.sh -- parse Cody's typed fix-round response into routing keys.
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq.
#
# Usage:
#   squad-fix-parse.sh --input <file|-> --open <B1,B2,...> [--upheld <B2,...>]
#
#   --input   Cody's fix-round summary (a file, or - for stdin). Only the
#             "## Fix responses" section is parsed (heading to the next "## "
#             heading or EOF); prose outside it is ignored. Inside it blank lines
#             are ignored and every other non-indented line must be one of
#               B<n>: FIX [note]
#               B<n>: CONTEST <evidence>
#               B<n>: ESCALATE <reason>
#             with an optional "- " or "* " list marker, case-insensitive verbs
#             (FIX/FIXED/FIXES, CONTEST/CONTESTED, ESCALATE/ESCALATED) and optional
#             punctuation (. : - em dash) before the text. Indented lines continue
#             the previous entry and are ignored; other lines are malformed.
#   --open    comma list of the finding IDs still open (ID format: claude/agents/reven.md)
#   --upheld  comma list of IDs already ruled FINDING_UPHELD; these allow FIX or ESCALATE only
#
# Stdout: OUTCOME=unchanged, CHANGED=no (read-only), FIXES=, CONTESTS=, ESCALATIONS=, MISSING= (comma lists, empty allowed), in
# order of the open list. Printed on exit 0 and on exit 10 (best effort, so the caller
# can see what is missing). Nothing is printed on exit 2.
# Exit: 0 every open ID answered once and validly, 2 usage,
#       10 missing section, missing, duplicate or unknown ID, malformed or stray
#       line inside the section, or CONTEST on an upheld ID.
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
# Keep only the "## Fix responses" section: heading to next "## " heading or EOF.
if printf '%s\n' "$TEXT" | grep -qE '^## Fix responses[[:space:]]*$'; then
  TEXT="$(printf '%s\n' "$TEXT" | awk '
    /^## Fix responses[ \t]*$/ { on=1; next }
    on && /^## / { on=0 }
    on { print }')"
else
  problem "no '## Fix responses' section in input"
  TEXT=""
fi
SEEN=" "; FIXES=""; CONTESTS=""; ESCS=""
ENTRY_RE='^([-*][[:space:]]+)?(B[0-9]+)([[:space:]]*:[[:space:]]*(.*))?$'
VERB_RE='^([A-Za-z]+)(.*)$'
PREV=0
strip_lead() { # drop leading whitespace, one optional . : - or em dash, then whitespace
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  case "$t" in "."*|":"*|"-"*) t="${t#?}" ;; "—"*) t="${t#—}" ;; esac
  t="${t#"${t%%[![:space:]]*}"}"
  printf '%s' "$t"
}
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  case "$line" in
    [[:space:]]*)
      # Indented prose continues the previous entry; ignored for routing.
      [ "$PREV" -eq 1 ] || problem "malformed line: $line"
      continue ;;
  esac
  if ! [[ "$line" =~ $ENTRY_RE ]] || [ -z "${BASH_REMATCH[3]}" ]; then
    problem "malformed line: $line"; continue
  fi
  id="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[4]}"
  if ! [[ "$rest" =~ $VERB_RE ]]; then problem "malformed line: $line"; continue; fi
  verb="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"; tail="$(strip_lead "${BASH_REMATCH[2]}")"
  case "$verb" in
    FIX|FIXED|FIXES) kind=FIX ;;
    CONTEST|CONTESTED) kind=CONTEST ;;
    ESCALATE|ESCALATED) kind=ESCALATE ;;
    *) problem "malformed line (unknown verb): $line"; continue ;;
  esac
  if [ "$kind" != FIX ] && [ -z "$tail" ]; then problem "malformed line (needs text): $line"; continue; fi
  PREV=1
  if in_list "$id" "$SEEN"; then problem "duplicate ID $id"; continue; fi
  SEEN="$SEEN$id "
  if [ "$kind" = CONTEST ] && in_list "$id" "$UPHELD_N"; then problem "$id already FINDING_UPHELD: only FIX or ESCALATE"; continue; fi
  if ! in_list "$id" "$OPEN_N"; then problem "unknown ID $id (not open)"; continue; fi
  case "$kind" in
    FIX) FIXES="$FIXES $id" ;;
    CONTEST) CONTESTS="$CONTESTS $id" ;;
    ESCALATE) ESCS="$ESCS $id" ;;
  esac
done <<EOT
$TEXT
EOT

MISSING=""
for id in $OPEN_N; do
  in_list "$id" "$SEEN" || { MISSING="$MISSING $id"; problem "missing answer for $id"; }
done

csv() { printf '%s' "$1" | sed -e 's/^ *//' -e 's/ /,/g'; }
printf 'OUTCOME=unchanged\nCHANGED=no\nFIXES=%s\nCONTESTS=%s\nESCALATIONS=%s\nMISSING=%s\n' \
  "$(csv "$FIXES")" "$(csv "$CONTESTS")" "$(csv "$ESCS")" "$(csv "$MISSING")"
[ "$ERR" -eq 0 ] || exit 10
exit 0
