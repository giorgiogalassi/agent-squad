#!/usr/bin/env bash
# squad-vcs.sh -- the VCS facade. Contract: SCRIPT_CONTRACT.md.
# Bash 3.2 compatible. Skills, agents and hooks call this (or squad_vcs from
# squad-common.sh); only hooks/vcs/<provider>.sh talk to a vendor.
#
# Usage: squad-vcs.sh <verb> [args]   (runs in the current directory)
#   available | auth-status | cli-name
#   default-branch | branch-exists <branch>
#   pr-for-branch <branch> [--state open|all|merged]
#   pr-list [--state open] [--limit N]      display lines, not KEY=VALUE
#   pr-view <pr|branch> --field base|changed-files|state|url|title
#   pr-create --head H --base B --title T --body B
#   diff --base B --head H                  unified diff on stdout (a first line starting with "# squad:"
#                                           marks a local-git fallback; parsers must skip it)
#   description-get <pr>                    PR body on stdout, verbatim
#   description-set <pr> --body-file F      (write)
#   comment <pr> --body T                   (write)
#   merged <pr>
#   stack-init <branch>...                  adopt a stacked chain (10 when unsupported)
#   pr-data <pr> --fields a,b,c             one JSON object (the only JSON verb)
# Output: KEY=VALUE lines (PR= URL= BASE= HEAD= STATE= ...). Provider:
# VCS_PROVIDER (chisel.vcs, default github). Detached mode refuses
# description-set and comment (20). Exit: 0 ok, 2 usage, 10 precondition /
# unsupported verb, 20 failure.
# Read-only verbs (available auth-status cli-name default-branch branch-exists
# pr-for-branch pr-list pr-view pr-data description-get diff merged) run even
# when the project paths do not resolve (provider github); writes do not.
# pr-create and stack-init do not check the tracker mode (Cody's `open pr`, the
# vault's own repo decide) but are under the write policy (#400): a verb that
# chisel.writes.vcs does not list is refused (20, REASON=policy: ...).

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

[ -n "${1:-}" ] || squad_fail 2 "usage: squad-vcs.sh <verb> [args]"
# Read-only verbs work in any directory, mapped project or not (/stats is for
# every Claude Code session): when the project does not resolve they run with
# provider github and detached mode. Writes still need a resolved project.
if ! squad_resolve; then
  case "$1" in
    available|auth-status|cli-name|default-branch|branch-exists|pr-for-branch|pr-list|pr-view|pr-data|description-get|diff|merged)
      export TRACKER_MODE=detached TRACKER_PROVIDER="${TRACKER_PROVIDER:-github}" VCS_PROVIDER="${VCS_PROVIDER:-github}" ;;
    *) squad_fail_incident squad-vcs 20 "cannot resolve project paths" ;;
  esac
fi
squad_vcs "$@"
rc=$?
case "$rc" in 0|1|2|10|20) exit "$rc" ;; *) exit 20 ;; esac
