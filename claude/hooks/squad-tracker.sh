#!/usr/bin/env bash
# squad-tracker.sh -- the tracker facade. Contract: SCRIPT_CONTRACT.md.
# Bash 3.2 compatible. Skills, agents and hooks call this (or squad_tracker
# from squad-common.sh); only hooks/tracker/<provider>.sh talk to a vendor.
#
# Usage: squad-tracker.sh <verb> [args]
#   batch <container|latest>        open sub-issues of a container, with dependencies
#   get <id>                        one issue
#   create --title T --body B [--parent N] [--blocked-by N[,N]] [--label L]...
#   create-child <parent> --title T --body B [--blocked-by N[,N]] [--label L]...
#   link-blocking <blocker> <dependent>
#   project-add <issue-url> --owner O --number N     (providers with projects)
#   set-state <id> <in-progress|in-review|needs-review|blocked> [--reason T] [--handoff P]
#   claim <id> [--handoff P]        = set-state <id> in-progress
#   labels <id> | label-list | label-create <name>
#   label <id> [--assign-me] [--add L]... [--remove L]...
#   comment <id> --body T
#   preflight [--project-owner O --project-number N]
# Output: KEY=VALUE lines. Items: ID= TITLE= STATE= URL= PARENT= BLOCKED_BY=
# (plus BLOCKING= LABELS= CONTAINER=), blocks separated by a blank line.
# Provider: TRACKER_PROVIDER (chisel.tracker, default github).
# set-state and claim are the squad state machine. Today they delegate to the
# label state machine (squad-labels.sh), which uses the label verbs: one owner
# for the transitions. A tracker without labels (#398) provides its own by
# defining tracker_set_state <id> <claim|review|needs-review|escalate>
# [--reason T] [--handoff P] in its adapter; when defined it is used instead
# and squad-labels.sh is not called. The github adapter does not define it.
# Detached mode: every write verb is refused (20), reads are not.
# Write policy (#400): a write verb the project's chisel.writes.tracker does not
# list is refused (20, REASON=policy: ...); see squad_policy_check.
# Exit: 0 ok, 2 usage, 10 precondition / unsupported verb, 20 failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
[ -n "$VERB" ] || squad_fail 2 "usage: squad-tracker.sh <verb> [args]"
shift

# _state_transition <squad-labels verb> <id> [args]: the adapter's
# tracker_set_state when it defines one, else the label state machine.
_state_transition() {
  local lv="$1" id="$2" pv; shift 2
  case "$lv" in claim) pv=claim ;; *) pv=set-state ;; esac
  squad_resolve || squad_fail_incident squad-tracker 20 "cannot resolve project paths"
  squad_policy_check tracker "$pv" || exit 20
  _SQUAD_POLICY_TRANSITION=1   # in-process only (not exported): this transition's own label edits
  if squad_resolve && squad_adapter_load tracker && declare -F tracker_set_state >/dev/null 2>&1; then
    tracker_set_state "$id" "$lv" "$@"
    exit $?
  fi
  unset _SQUAD_POLICY_TRANSITION   # squad-labels.sh authorises the transition itself
  exec bash "$SQUAD_COMMON_DIR/squad-labels.sh" "$lv" --issue "$id" "$@"
}

case "$VERB" in
  claim)
    [ -n "${1:-}" ] || squad_fail 2 "claim requires an id"
    id="$1"; shift
    _state_transition claim "$id" "$@" ;;
  set-state)
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || squad_fail 2 "usage: set-state <id> <state> [--reason T] [--handoff P]"
    id="$1"; st="$2"; shift 2
    case "$st" in
      in-progress) lv=claim ;;
      in-review) lv=review ;;
      needs-review) lv=needs-review ;;
      blocked) lv=escalate ;;
      *) squad_fail 2 "unknown squad state '$st'" ;;
    esac
    _state_transition "$lv" "$id" "$@" ;;
esac

squad_resolve || squad_fail_incident squad-tracker 20 "cannot resolve project paths"
squad_tracker "$VERB" "$@"
rc=$?
case "$rc" in 0|2|10|20) exit "$rc" ;; *) exit 20 ;; esac
