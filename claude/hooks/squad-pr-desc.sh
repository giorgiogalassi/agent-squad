#!/usr/bin/env bash
# squad-pr-desc.sh -- applies Reven's "Description drift" block to a PR
# description. Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq.
#
# Usage:
#   squad-pr-desc.sh apply --block <file> --pr <n>                 (connected)
#   squad-pr-desc.sh apply --block <file> --issue <id> --handoff <p> (detached)
#
# <file> holds Reven's review (or just its "## Description drift" section).
# Block grammar, one item per entry; text is taken verbatim after the prefix:
#   - line: <exact current description line>
#     to: <replacement line; empty removes the line>
#   - add: <new bullet text, appended as "- <text>" when not already present>
#   - none: <reason>
# A block with `none:` and no other item changes nothing. A missing section,
# or a section with no valid item, is a precondition failure (10): the
# section is mandatory in every Reven review.
#
# Connected: reads the PR body (read-only gh), applies the items, writes it
# back with one `gh pr edit --body-file` through squad_gh_write. Replacing is
# exact whole-line match, first occurrence; unmatched `line:` items are
# counted in MISSED and left for the caller to report, never guessed.
# Detached: zero gh calls; appends one checklist line per item to --handoff.
# Emits: OUTCOME, CHANGED, REPLACED, ADDED, MISSED (connected) or ITEMS
# (detached). Exit: 0 ok, 2 usage, 10 block missing/invalid, 20 gh/io failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
[ "$VERB" = apply ] || squad_fail 2 "usage: squad-pr-desc.sh apply --block <file> --pr <n> | --issue <id> --handoff <p>"
shift
BLOCK=""; PR=""; ISSUE=""; HANDOFF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --block|--pr|--issue|--handoff)
      [ $# -ge 2 ] || squad_fail 2 "$1 requires a value"
      case "$1" in
        --block) BLOCK="$2" ;; --pr) PR="$2" ;;
        --issue) ISSUE="$2" ;; --handoff) HANDOFF="$2" ;;
      esac
      shift 2 ;;
    *) squad_fail 2 "unknown argument '$1'" ;;
  esac
done
[ -n "$BLOCK" ] || squad_fail 2 "apply requires --block"
[ -f "$BLOCK" ] && [ -r "$BLOCK" ] || squad_fail 10 "block file missing or unreadable: $BLOCK"

# --- parse the section into parallel arrays ---------------------------------
OLD=(); NEW=(); ADD=(); NONE=""; HAVE_SECTION=0; IN=0; PENDING=""
while IFS= read -r raw || [ -n "$raw" ]; do
  l="${raw%$'\r'}"
  case "$l" in
    '## Description drift'*) HAVE_SECTION=1; IN=1; continue ;;
    '## '*) [ "$IN" = 1 ] && IN=0; continue ;;
  esac
  [ "$IN" = 1 ] || continue
  case "$l" in
    '- line: '*|'- line:')
      PENDING="${l#- line:}"; PENDING="${PENDING# }"; HAVE_OLD=1 ;;
    '  to: '*|'  to:'|'to: '*|'to:')
      if [ "${HAVE_OLD:-0}" = 1 ]; then
        t="${l#*to:}"; t="${t# }"
        OLD[${#OLD[@]}]="$PENDING"; NEW[${#NEW[@]}]="$t"; HAVE_OLD=0
      fi ;;
    '- add: '*) t="${l#- add: }"; [ -n "$t" ] && ADD[${#ADD[@]}]="$t" ;;
    '- none: '*) NONE="${l#- none: }" ;;
  esac
done < "$BLOCK"

[ "$HAVE_SECTION" = 1 ] || squad_fail 10 "no '## Description drift' section in $BLOCK"
NL=${#OLD[@]}; NA=${#ADD[@]}
if [ "$NL" -eq 0 ] && [ "$NA" -eq 0 ] && [ -z "$NONE" ]; then
  squad_fail 10 "Description drift section has no valid item (line/to, add or none: <reason>)"
fi

squad_resolve || squad_fail_incident squad-pr-desc 20 "cannot resolve project paths"

# --- detached: record only, no gh calls of any kind --------------------------
if [ "$TRACKER_MODE" != connected ]; then
  [ -n "$HANDOFF" ] || squad_fail 2 "--handoff is required in detached mode"
  [ -n "$ISSUE" ] || squad_fail 2 "--issue is required in detached mode"
  CH=no; i=0
  while [ "$i" -lt "$NL" ]; do
    squad_record_local "$HANDOFF" "- [ ] PR description of $ISSUE: replace \"${OLD[$i]}\" with \"${NEW[$i]}\""; rc=$?
    case "$rc" in 0) CH=yes ;; 1) ;; *) squad_fail 20 "cannot write handoff $HANDOFF" ;; esac
    i=$((i+1))
  done
  i=0
  while [ "$i" -lt "$NA" ]; do
    squad_record_local "$HANDOFF" "- [ ] PR description of $ISSUE: add bullet \"${ADD[$i]}\""; rc=$?
    case "$rc" in 0) CH=yes ;; 1) ;; *) squad_fail 20 "cannot write handoff $HANDOFF" ;; esac
    i=$((i+1))
  done
  if [ "$CH" = yes ]; then OUT=recorded-local; else OUT=unchanged; fi
  squad_emit OUTCOME "$OUT"; squad_emit CHANGED "$CH"; squad_emit ITEMS "$((NL+NA))"
  exit 0
fi

# --- connected ----------------------------------------------------------------
[ -n "$PR" ] || squad_fail 2 "--pr is required in connected mode"
if [ "$NL" -eq 0 ] && [ "$NA" -eq 0 ]; then
  squad_emit OUTCOME unchanged; squad_emit CHANGED no
  squad_emit REPLACED 0; squad_emit ADDED 0; squad_emit MISSED 0
  exit 0
fi
BODY="$(gh pr view "$PR" --json body -q .body)" || squad_fail_incident squad-pr-desc 20 "gh pr view $PR failed"

TMP="$(mktemp "${TMPDIR:-/tmp}/squad-pr-desc.XXXXXX")" || squad_fail 20 "cannot create temp file"
trap 'rm -f "$TMP"' EXIT
USED=""; REPLACED=0; : > "$TMP"
while IFS= read -r raw || [ -n "$raw" ]; do
  l="${raw%$'\r'}"; out="$l"; drop=0; i=0
  while [ "$i" -lt "$NL" ]; do
    case " $USED " in *" $i "*) ;; *)
      if [ "$l" = "${OLD[$i]}" ]; then
        USED="$USED $i"; REPLACED=$((REPLACED+1))
        if [ -n "${NEW[$i]}" ]; then out="${NEW[$i]}"; else drop=1; fi
        break
      fi ;;
    esac
    i=$((i+1))
  done
  [ "$drop" = 1 ] || printf '%s\n' "$out" >> "$TMP"
done <<EOB
$BODY
EOB
MISSED=$((NL-REPLACED)); ADDED=0; i=0
while [ "$i" -lt "$NA" ]; do
  if ! grep -qxF -- "- ${ADD[$i]}" "$TMP"; then
    printf '%s\n' "- ${ADD[$i]}" >> "$TMP"; ADDED=$((ADDED+1))
  fi
  i=$((i+1))
done

if [ "$REPLACED" -eq 0 ] && [ "$ADDED" -eq 0 ]; then
  squad_emit OUTCOME unchanged; squad_emit CHANGED no
else
  squad_gh_write pr edit "$PR" --body-file "$TMP" || squad_fail_incident squad-pr-desc 20 "gh pr edit $PR failed"
  squad_emit OUTCOME applied; squad_emit CHANGED yes
fi
squad_emit REPLACED "$REPLACED"; squad_emit ADDED "$ADDED"; squad_emit MISSED "$MISSED"
exit 0
