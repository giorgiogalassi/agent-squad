#!/usr/bin/env bash
# squad-labels.sh -- performs the label transitions of LABEL_STATE_MACHINE.md.
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq needed.
#
# Usage:
#   squad-labels.sh ensure   [--handoff <p>]
#   squad-labels.sh claim    --issue <n> [--handoff <p>]
#   squad-labels.sh review   --issue <n> [--handoff <p>]
#   squad-labels.sh escalate --issue <n> --reason <text> [--handoff <p>]
#
# Connected: mutates via squad_gh_write only; label names come ONLY from
# chisel-config.json (state_labels.{in_progress,in_review,blocked} required,
# review_label absent/"none" = not configured), parsed with grep/sed. A
# missing/unreadable config or missing state label is a hard failure (20);
# there are no built-in defaults. The issue's current labels are read with
# `gh issue view --json labels`.
# Two-step verbs are re-runnable after a partial failure:
#   review    swap edit, then remove review_label; a re-run that finds
#             in_review but review_label still present does only the remove.
#   escalate  comment first, then label swap. A retry after a label-swap
#             failure may DUPLICATE the comment (recoverable); the reverse
#             order would lose the comment (not recoverable).
# Detached: zero gh calls; appends a checklist line to --handoff (required).
# Exit: 0 ok, 2 usage, 10 illegal transition, 20 gh/io failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
[ -n "$VERB" ] || squad_fail 2 "usage: squad-labels.sh ensure|claim|review|escalate [options]"
shift
case "$VERB" in ensure|claim|review|escalate) ;; *) squad_fail 2 "unknown verb '$VERB'" ;; esac

ISSUE=""; REASON=""; HANDOFF=""; HAVE_REASON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --issue|--reason|--handoff)
      [ $# -ge 2 ] || squad_fail 2 "$1 requires a value"
      case "$1" in
        --issue) ISSUE="$2" ;;
        --reason) REASON="$2"; HAVE_REASON=1 ;;
        --handoff) HANDOFF="$2" ;;
      esac
      shift 2 ;;
    *) squad_fail 2 "unknown argument '$1'" ;;
  esac
done
if [ "$VERB" != ensure ]; then
  [ -n "$ISSUE" ] || squad_fail 2 "$VERB requires --issue"
fi
if [ "$VERB" = escalate ]; then
  [ "$HAVE_REASON" = 1 ] && [ -n "$REASON" ] || squad_fail 2 "escalate requires --reason"
fi

squad_resolve || squad_fail_incident squad-labels 20 "cannot resolve project paths"

# --- detached: record only, no gh calls of any kind -------------------------
if [ "$TRACKER_MODE" != connected ]; then
  if [ "$VERB" = ensure ]; then
    squad_emit OUTCOME unchanged; squad_emit CHANGED no
    exit 0
  fi
  [ -n "$HANDOFF" ] || squad_fail 2 "--handoff is required in detached mode"
  case "$VERB" in
    claim) LINE="- [ ] Move $ISSUE to In Progress" ;;
    review) LINE="- [ ] Move $ISSUE to In Review" ;;
    escalate) LINE="- [ ] Move $ISSUE to Blocked, comment: $(printf '%s' "$REASON" | tr '\r\n' '  ')" ;;
  esac
  squad_record_local "$HANDOFF" "$LINE"; rc=$?
  case "$rc" in
    0) OUT=recorded-local; CH=yes ;;
    1) OUT=unchanged; CH=no ;;
    *) squad_fail 20 "cannot write handoff $HANDOFF" ;;
  esac
  squad_emit OUTCOME "$OUT"; squad_emit CHANGED "$CH"; squad_emit ISSUE "$ISSUE"
  squad_emit HANDOFF_LINE "$LINE"
  exit 0
fi

# --- connected: label names from config -------------------------------------
CFG="$VAULT_PATH/projects/$DISPLAY_NAME/.squad/chisel-config.json"
[ -f "$CFG" ] && [ -r "$CFG" ] || squad_fail_incident squad-labels 20 "chisel-config.json missing or unreadable: $CFG"
# cfgval <key>: first string value of "<key>" in the config (keys are unique).
cfgval() { grep -o "\"$1\" *: *\"[^\"]*\"" "$CFG" | head -1 | sed 's/^"[^"]*" *: *"//; s/"$//'; }
L_IP="$(cfgval in_progress)"; L_IR="$(cfgval in_review)"; L_BL="$(cfgval blocked)"
L_RV="$(cfgval review_label)"; [ -n "$L_RV" ] || L_RV=none
[ -n "$L_IP" ] || squad_fail_incident squad-labels 20 "chisel.state_labels.in_progress missing in $CFG"
[ -n "$L_IR" ] || squad_fail_incident squad-labels 20 "chisel.state_labels.in_review missing in $CFG"
[ -n "$L_BL" ] || squad_fail_incident squad-labels 20 "chisel.state_labels.blocked missing in $CFG"

# One repo lookup per call (read-only).
REPO_JSON="$(gh repo view --json nameWithOwner)" || squad_fail_incident squad-labels 20 "gh repo view failed"
REPO="$(printf '%s' "$REPO_JSON" | sed -n 's/.*"nameWithOwner" *: *"\([^"]*\)".*/\1/p')"
[ -n "$REPO" ] || squad_fail_incident squad-labels 20 "cannot determine owner/repo"

# names_of: label names from gh JSON on stdin, one per line.
names_of() { grep -o '"name" *: *"[^"]*"' | sed 's/^"name" *: *"//; s/"$//'; }
# in_list <list> <name>
in_list() { printf '%s\n' "$1" | grep -qxF -- "$2"; }
join() { printf '%s' "$1" | grep -v '^$' | tr '\n' ',' | sed 's/,$//'; }
# managed <list>: the state/review labels present in <list>, fixed order.
managed() {
  local n
  for n in "$L_RV" "$L_IP" "$L_IR" "$L_BL"; do
    [ "$n" = none ] && continue
    in_list "$1" "$n" && printf '%s\n' "$n"
  done
  return 0
}
drop() { printf '%s\n' "$1" | grep -vxF -- "$2"; return 0; }
add() { in_list "$1" "$2" && printf '%s\n' "$1" || printf '%s\n%s\n' "$1" "$2"; }

finish() {  # finish <outcome> <changed> <from> <to>
  squad_emit OUTCOME "$1"; squad_emit CHANGED "$2"
  [ -n "$ISSUE" ] && squad_emit ISSUE "$ISSUE"
  squad_emit FROM_LABELS "$(join "$(managed "$3")")"
  squad_emit TO_LABELS "$(join "$(managed "$4")")"
  exit 0
}

if [ "$VERB" = ensure ]; then
  LIST="$(gh label list -R "$REPO" --json name)" || squad_fail_incident squad-labels 20 "gh label list failed"
  HAVE="$(printf '%s' "$LIST" | names_of)"
  CREATED=""
  for n in "$L_RV" "$L_IP" "$L_IR" "$L_BL"; do
    [ "$n" = none ] && continue
    in_list "$HAVE" "$n" && continue
    squad_gh_write label create "$n" -R "$REPO" || squad_fail_incident squad-labels 20 "gh label create $n failed"
    CREATED="$CREATED$n
"
  done
  if [ -n "$CREATED" ]; then OUT=applied; CH=yes; else OUT=unchanged; CH=no; fi
  squad_emit OUTCOME "$OUT"; squad_emit CHANGED "$CH"
  squad_emit LABELS_CREATED "$(join "$CREATED")"
  exit 0
fi

VIEW="$(gh issue view "$ISSUE" -R "$REPO" --json labels)" || squad_fail_incident squad-labels 20 "gh issue view $ISSUE failed"
FROM="$(printf '%s' "$VIEW" | names_of)"
has_ip=0; has_ir=0; has_bl=0; has_rv=0
in_list "$FROM" "$L_IP" && has_ip=1
in_list "$FROM" "$L_IR" && has_ir=1
in_list "$FROM" "$L_BL" && has_bl=1
[ "$L_RV" != none ] && in_list "$FROM" "$L_RV" && has_rv=1

case "$VERB" in
  claim)
    [ "$has_ip" = 1 ] && finish unchanged no "$FROM" "$FROM"
    [ "$has_ir" = 1 ] && squad_fail 10 "cannot claim $ISSUE: already $L_IR"
    [ "$has_bl" = 1 ] && squad_fail 10 "cannot claim $ISSUE: $L_BL present (no such transition)"
    squad_gh_write issue edit "$ISSUE" -R "$REPO" --add-assignee @me --add-label "$L_IP" \
      || squad_fail_incident squad-labels 20 "gh issue edit failed"
    finish applied yes "$FROM" "$(add "$FROM" "$L_IP")" ;;
  review)
    if [ "$has_ip" = 0 ] && [ "$has_ir" = 1 ]; then
      # Already swapped; only a leftover review_label (partial failure) remains.
      [ "$has_rv" = 1 ] || finish unchanged no "$FROM" "$FROM"
      squad_gh_write issue edit "$ISSUE" -R "$REPO" --remove-label "$L_RV" \
        || squad_fail_incident squad-labels 20 "gh issue edit (remove $L_RV) failed"
      finish applied yes "$FROM" "$(drop "$FROM" "$L_RV")"
    fi
    [ "$has_ip" = 0 ] && squad_fail_incident squad-labels 10 "cannot review $ISSUE: neither $L_IP nor $L_IR present"
    squad_gh_write issue edit "$ISSUE" -R "$REPO" --remove-label "$L_IP" --add-label "$L_IR" \
      || squad_fail_incident squad-labels 20 "gh issue edit failed"
    TO="$(add "$(drop "$FROM" "$L_IP")" "$L_IR")"
    if [ "$L_RV" != none ]; then
      squad_gh_write issue edit "$ISSUE" -R "$REPO" --remove-label "$L_RV" \
        || squad_fail_incident squad-labels 20 "gh issue edit (remove $L_RV) failed; re-run review to finish"
      TO="$(drop "$TO" "$L_RV")"
    fi
    finish applied yes "$FROM" "$TO" ;;
  escalate)
    [ "$has_ip" = 0 ] && [ "$has_bl" = 1 ] && finish unchanged no "$FROM" "$FROM"
    [ "$has_ip" = 0 ] && squad_fail 10 "cannot escalate $ISSUE: $L_IP not present"
    squad_gh_write issue comment "$ISSUE" -R "$REPO" --body "$REASON" \
      || squad_fail_incident squad-labels 20 "gh issue comment failed"
    squad_gh_write issue edit "$ISSUE" -R "$REPO" --remove-label "$L_IP" --add-label "$L_BL" \
      || squad_fail_incident squad-labels 20 "gh issue edit failed after comment posted; a retry may duplicate the comment"
    squad_incident squad-labels 0 "escalated $ISSUE: $REASON" escalation
    finish applied yes "$FROM" "$(add "$(drop "$FROM" "$L_IP")" "$L_BL")" ;;
esac
