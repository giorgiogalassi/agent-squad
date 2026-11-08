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
#   diff --base B --head H                  unified diff on stdout
#   description-get <pr>                    PR body on stdout, verbatim
#   description-set <pr> --body-file F      (write; write policy: #400)
#   comment <pr> --body T                   (write; write policy: #400)
#   merged <pr>
#   stack-init <branch>...                  adopt a stacked chain (10 when unsupported)
#   pr-data <pr> --fields a,b,c             one JSON object (the only JSON verb)
# Output: KEY=VALUE lines (PR= URL= BASE= HEAD= STATE= ...). Provider:
# VCS_PROVIDER (chisel.vcs, default github). Detached mode refuses
# description-set and comment (20). Exit: 0 ok, 2 usage, 10 precondition /
# unsupported verb, 20 failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

[ -n "${1:-}" ] || squad_fail 2 "usage: squad-vcs.sh <verb> [args]"
squad_resolve || squad_fail_incident squad-vcs 20 "cannot resolve project paths"
squad_vcs "$@"
rc=$?
case "$rc" in 0|1|2|10|20) exit "$rc" ;; *) exit 20 ;; esac
