#!/usr/bin/env bash
# squad-labels.sh -- performs the label transitions of LABEL_STATE_MACHINE.md.
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq needed.
#
# Usage:
#   squad-labels.sh ensure   [--handoff <p>]
#   squad-labels.sh claim    --issue <n> [--handoff <p>]
#   squad-labels.sh review   --issue <n> [--handoff <p>]
#   squad-labels.sh escalate --issue <n> --reason <text> [--handoff <p>]
#   squad-labels.sh needs-review --issue <n> [--handoff <p>]
#
# Connected: mutates via the tracker facade (squad_tracker) only; label names come ONLY from
# chisel-config.json (state_labels.{in_progress,in_review,blocked} required,
# review_label absent/"none" = not configured), parsed with grep/sed. A
# missing/unreadable config or missing state label is a hard failure (20);
# there are no built-in defaults. The issue's current labels are read with
# the tracker facade (squad_tracker labels).
# Two-step verbs are re-runnable after a partial failure:
#   review    swap edit, then remove review_label; a re-run that finds
#             in_review but review_label still present does only the remove.
#   escalate  comment first, then label swap. A retry after a label-swap
#             failure may DUPLICATE the comment (recoverable); the reverse
#             order would lose the comment (not recoverable).
#   needs-review  re-applies review_label to an issue whose PR is open (in_review
#             present), keeping in_review. review_label not configured = 10.
# Detached: zero tracker calls; appends a checklist line to --handoff (required).
# Exit: 0 ok, 2 usage, 10 illegal transition or no project mapped, 20 tracker/io failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
[ -n "$VERB" ] || squad_fail 2 "usage: squad-labels.sh ensure|claim|review|escalate|needs-review [options]"
shift
case "$VERB" in ensure|claim|review|escalate|needs-review) ;; *) squad_fail 2 "unknown verb '$VERB'" ;; esac

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
# Unmapped cwd (#395): fail before any projects/<name> path is built; no incident (nothing to dedupe).
[ -n "${DISPLAY_NAME:-}" ] || squad_fail 10 "no project mapped for ${PROJECT_ROOT:-$PWD}; run /seed or /lore start"

# Write policy (#400): claim needs `claim`, review / needs-review / escalate need
# `set-state` in chisel.writes.tracker. Checked here because every flow calls this
# script directly. Once authorised, the transition's own label edits pass
# squad_policy_check through an in-process flag (never read from the environment).
if [ "$TRACKER_MODE" = connected ] && [ "$VERB" != ensure ]; then
  case "$VERB" in claim) _pv=claim ;; *) _pv=set-state ;; esac
  squad_policy_check tracker "$_pv" || exit 20
  _SQUAD_POLICY_TRANSITION=1
  # A tracker without labels (jira) provides its own transitions: delegate, same as
  # squad-tracker.sh set-state. An adapter that does not load is a failure.
  squad_adapter_load tracker \
    || squad_fail_incident squad-labels 20 "tracker adapter '${TRACKER_PROVIDER:-github}' failed to load"
  if declare -F tracker_set_state >/dev/null 2>&1; then
    if [ "$VERB" = escalate ]; then tracker_set_state "$ISSUE" "$VERB" --reason "$REASON"; else tracker_set_state "$ISSUE" "$VERB"; fi
    exit $?
  fi
fi

# --- detached: record only, no tracker calls of any kind -------------------------
if [ "$TRACKER_MODE" != connected ]; then
  if [ "$VERB" = ensure ]; then
    squad_emit OUTCOME unchanged; squad_emit CHANGED no
    exit 0
  fi
  [ -n "$HANDOFF" ] || squad_fail 2 "--handoff is required in detached mode"
  case "$VERB" in
    claim) LINE="- [ ] Move $ISSUE to In Progress" ;;
    review) LINE="- [ ] Move $ISSUE to In Review" ;;
    needs-review) LINE="- [ ] Mark $ISSUE as Needs Review (review loop ended without approval)" ;;
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
CFG="$STATE_DIR/chisel-config.json"
[ -f "$CFG" ] && [ -r "$CFG" ] || squad_fail_incident squad-labels 20 "chisel-config.json missing or unreadable: $CFG"
# cfgval <key>: first string value of "<key>" in the config (keys are unique).
cfgval() { grep -o "\"$1\" *: *\"[^\"]*\"" "$CFG" | head -1 | sed 's/^"[^"]*" *: *"//; s/"$//'; }
L_IP="$(cfgval in_progress)"; L_IR="$(cfgval in_review)"; L_BL="$(cfgval blocked)"
L_RV="$(cfgval review_label)"; [ -n "$L_RV" ] || L_RV=none
[ -n "$L_IP" ] || squad_fail_incident squad-labels 20 "chisel.state_labels.in_progress missing in $CFG"
[ -n "$L_IR" ] || squad_fail_incident squad-labels 20 "chisel.state_labels.in_review missing in $CFG"
[ -n "$L_BL" ] || squad_fail_incident squad-labels 20 "chisel.state_labels.blocked missing in $CFG"

# One repo lookup per call (read-only).
# Unwrapped on purpose: the adapter caches the lookup in this shell.
squad_tracker repo >/dev/null || squad_fail_incident squad-labels 20 "tracker repo lookup failed"

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
  HAVE="$(squad_tracker label-list)" || squad_fail_incident squad-labels 20 "tracker label list failed"
  CREATED=""
  for n in "$L_RV" "$L_IP" "$L_IR" "$L_BL"; do
    [ "$n" = none ] && continue
    in_list "$HAVE" "$n" && continue
    squad_tracker label-create "$n" || squad_fail_incident squad-labels 20 "tracker label create $n failed"
    CREATED="$CREATED$n
"
  done
  if [ -n "$CREATED" ]; then OUT=applied; CH=yes; else OUT=unchanged; CH=no; fi
  squad_emit OUTCOME "$OUT"; squad_emit CHANGED "$CH"
  squad_emit LABELS_CREATED "$(join "$CREATED")"
  exit 0
fi

FROM="$(squad_tracker labels "$ISSUE")" || squad_fail_incident squad-labels 20 "tracker issue lookup $ISSUE failed"
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
    squad_tracker label "$ISSUE" --assign-me --add "$L_IP" \
      || squad_fail_incident squad-labels 20 "tracker label edit failed"
    finish applied yes "$FROM" "$(add "$FROM" "$L_IP")" ;;
  review)
    if [ "$has_ip" = 0 ] && [ "$has_ir" = 1 ]; then
      # Already swapped; only a leftover review_label (partial failure) remains.
      [ "$has_rv" = 1 ] || finish unchanged no "$FROM" "$FROM"
      squad_tracker label "$ISSUE" --remove "$L_RV" \
        || squad_fail_incident squad-labels 20 "tracker label edit (remove $L_RV) failed"
      finish applied yes "$FROM" "$(drop "$FROM" "$L_RV")"
    fi
    [ "$has_ip" = 0 ] && squad_fail_incident squad-labels 10 "cannot review $ISSUE: neither $L_IP nor $L_IR present"
    squad_tracker label "$ISSUE" --remove "$L_IP" --add "$L_IR" \
      || squad_fail_incident squad-labels 20 "tracker label edit failed"
    TO="$(add "$(drop "$FROM" "$L_IP")" "$L_IR")"
    if [ "$L_RV" != none ]; then
      squad_tracker label "$ISSUE" --remove "$L_RV" \
        || squad_fail_incident squad-labels 20 "tracker label edit (remove $L_RV) failed; re-run review to finish"
      TO="$(drop "$TO" "$L_RV")"
    fi
    finish applied yes "$FROM" "$TO" ;;
  needs-review)
    [ "$L_RV" = none ] && squad_fail 10 "cannot mark $ISSUE needs-review: review_label not configured"
    [ "$has_rv" = 1 ] && finish unchanged no "$FROM" "$FROM"
    [ "$has_ir" = 1 ] || squad_fail 10 "cannot mark $ISSUE needs-review: $L_IR not present"
    squad_tracker label "$ISSUE" --add "$L_RV" \
      || squad_fail_incident squad-labels 20 "tracker label edit failed"
    finish applied yes "$FROM" "$(add "$FROM" "$L_RV")" ;;
  escalate)
    [ "$has_ip" = 0 ] && [ "$has_bl" = 1 ] && finish unchanged no "$FROM" "$FROM"
    [ "$has_ip" = 0 ] && squad_fail 10 "cannot escalate $ISSUE: $L_IP not present"
    # Write policy (#400): without `comment` the reason stays out of the tracker;
    # the transition still happens and the caller records the reason (COMMENT=skipped).
    if squad_policy_allows tracker comment; then
      squad_tracker comment "$ISSUE" --body "$REASON" \
        || squad_fail_incident squad-labels 20 "tracker comment failed"
    else
      squad_emit COMMENT skipped
      squad_emit REASON "policy: comment not allowed on ${DISPLAY_NAME:-project}"
    fi
    squad_tracker label "$ISSUE" --remove "$L_IP" --add "$L_BL" \
      || squad_fail_incident squad-labels 20 "tracker label edit failed after comment posted; a retry may duplicate the comment"
    squad_incident squad-labels 0 "escalated $ISSUE: $REASON" escalation
    finish applied yes "$FROM" "$(add "$(drop "$FROM" "$L_IP")" "$L_BL")" ;;
esac
