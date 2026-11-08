#!/usr/bin/env bash
# squad-readiness.sh -- put a reader result into an issue body (Chisel).
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq, no gh.
#
# Usage:
#   squad-readiness.sh apply --body <file> --reader <file> --key <key> --mode connected|detached
#
# apply: takes the block `## Issue <key>` from the reader output file, drops that
#   heading, and rewrites <file> (the issue body) so it ends with exactly one
#   `## Readiness` section holding the block. An earlier `## Readiness` section
#   (heading up to the next `## ` heading or the end) and an earlier marker line
#   are removed first, so a re-run replaces and never appends. With one or more
#   open items under `### Blockers` (`- none` and an empty list count as zero) the
#   marker goes above the section: `Readiness: blocked (<n>)` (connected) or
#   `Blocked: readiness` (detached). Emits BLOCKERS=<n>; OUTCOME=applied|unchanged,
#   CHANGED=yes|no.
# Exit: 0 done, 2 usage, 10 no block for <key> in the reader file (body untouched),
#   20 file unreadable or unwritable.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

[ "${1:-}" = apply ] || squad_fail 2 "usage: squad-readiness.sh apply --body <file> --reader <file> --key <key> --mode connected|detached"
shift
BODY=""; READER=""; KEY=""; MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body|--reader|--key|--mode)
      [ $# -ge 2 ] || squad_fail 2 "$1 requires a value"
      case "$1" in --body) BODY="$2" ;; --reader) READER="$2" ;; --key) KEY="$2" ;; --mode) MODE="$2" ;; esac
      shift 2 ;;
    *) squad_fail 2 "unknown argument: $1" ;;
  esac
done
[ -n "$BODY" ] && [ -n "$READER" ] && [ -n "$KEY" ] || squad_fail 2 "--body, --reader and --key are required"
case "$MODE" in connected|detached) ;; *) squad_fail 2 "--mode must be connected or detached" ;; esac
[ -r "$BODY" ] && [ -r "$READER" ] || squad_fail 20 "cannot read $BODY or $READER"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/squad-readiness.XXXXXX")" || squad_fail 20 "cannot create a temp dir"
[ -n "$TMPD" ] && [ -d "$TMPD" ] || squad_fail 20 "cannot create a temp dir"
trap 'rm -rf "$TMPD"' EXIT   # lint:tmp-ok

# 1. The reader block for this key, without its heading.
KEY="$KEY" awk '
  /^## Issue / { if (on) exit; line=$0; sub(/[[:space:]]+$/, "", line); if (line == "## Issue " ENVIRON["KEY"]) { on=1; found=1; next } }
  on { print }
  END { exit found ? 0 : 1 }
' "$READER" > "$TMPD/block" || squad_fail 10 "no '## Issue $KEY' block in $READER"

# 2. Open blockers.
N="$(awk '
  /^### / { inb = ($0 ~ /^### Blockers[[:space:]]*$/); next }
  inb && /^- / { if (tolower($0) !~ /^- none[.]?[[:space:]]*$/) n++ }
  END { print n + 0 }
' "$TMPD/block")"

# 3. Body without an earlier section or marker, no trailing blank lines.
awk '
  /^## / { skip = ($0 ~ /^## Readiness[[:space:]]*$/) }
  skip { next }
  /^Readiness: blocked \([0-9]+\)[[:space:]]*$/ || /^Blocked: readiness[[:space:]]*$/ { next }
  { lines[++n] = $0 }
  END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }
' "$BODY" > "$TMPD/new"

# 4. Marker, then the one section.
{
  printf '\n'
  if [ "$N" -gt 0 ]; then
    if [ "$MODE" = connected ]; then printf 'Readiness: blocked (%s)\n\n' "$N"; else printf 'Blocked: readiness\n\n'; fi
  fi
  printf '## Readiness\n'
  cat "$TMPD/block"
} >> "$TMPD/new"

squad_emit BLOCKERS "$N"
if cmp -s "$TMPD/new" "$BODY"; then
  squad_emit OUTCOME unchanged; squad_emit CHANGED no
else
  cat "$TMPD/new" > "$BODY" || squad_fail 20 "cannot write $BODY"
  squad_emit OUTCOME applied; squad_emit CHANGED yes
fi
