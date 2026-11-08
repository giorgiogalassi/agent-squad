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
#   comment <id> --body T           (write policy: #400)
#   preflight [--project-owner O --project-number N]
# Output: KEY=VALUE lines. Items: ID= TITLE= STATE= URL= PARENT= BLOCKED_BY=
# (plus BLOCKING= LABELS= CONTAINER=), blocks separated by a blank line.
# Provider: TRACKER_PROVIDER (chisel.tracker, default github).
# set-state and claim are the squad state machine (squad-labels.sh), which in
# turn uses the label verbs: one owner for the transitions.
# Detached mode: every write verb is refused (20), reads are not.
# Exit: 0 ok, 2 usage, 10 precondition / unsupported verb, 20 failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
[ -n "$VERB" ] || squad_fail 2 "usage: squad-tracker.sh <verb> [args]"
shift

case "$VERB" in
  claim)
    [ -n "${1:-}" ] || squad_fail 2 "claim requires an id"
    id="$1"; shift
    exec bash "$SQUAD_COMMON_DIR/squad-labels.sh" claim --issue "$id" "$@" ;;
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
    exec bash "$SQUAD_COMMON_DIR/squad-labels.sh" "$lv" --issue "$id" "$@" ;;
esac

squad_resolve || squad_fail_incident squad-tracker 20 "cannot resolve project paths"
squad_tracker "$VERB" "$@"
rc=$?
case "$rc" in 0|2|10|20) exit "$rc" ;; *) exit 20 ;; esac
