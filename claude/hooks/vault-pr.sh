#!/usr/bin/env bash
# vault-pr.sh -- vault commits and the session-end PR when the vault's main takes
# changes only through pull requests (#350). Thin wrapper over squad-common.sh
# (squad_vault_commit, squad_vault_finish). Contract: SCRIPT_CONTRACT.md.
#
# Usage: vault-pr.sh commit "<message>" <vault-relative path>...
#        vault-pr.sh finish
# `commit` commits the paths Lore wrote (on the lore/<project>-<date> branch in PR
# mode, see lore-config.json "vault_main"). `finish` pushes that branch and opens
# or updates its PR when the vault is in PR mode and has an origin remote, in either
# tracker mode; local-only projects never push. Without gh the branch is pushed and
# a stderr notice names the manual PR step.
# Stdout: OUTCOME=applied|unchanged  CHANGED=yes|no (commit unchanged: paths left
# uncommitted; finish unchanged: nothing pushed and no PR created)
# Exit: 0 ok, 2 usage, 20 resolution, push or PR failure.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=squad-common.sh
. "$HOOK_DIR/squad-common.sh"

CMD="${1:-}"; [ $# -gt 0 ] && shift
squad_resolve || exit 20
V="$VAULT_PATH"
git -C "$V" rev-parse --git-dir >/dev/null 2>&1 || { squad_emit OUTCOME unchanged; squad_emit CHANGED no; exit 0; }
case "$CMD" in
  commit)
    [ $# -ge 2 ] || squad_fail 2 "usage: vault-pr.sh commit \"<message>\" <path>..."
    MSG="$1"; shift
    squad_vault_commit "$V" "${DISPLAY_NAME:-vault}" "$MSG" "$@" || exit 20
    if [ -z "$(git -C "$V" status --porcelain -- "$@" 2>/dev/null)" ]; then
      squad_emit OUTCOME applied; squad_emit CHANGED yes
    else
      squad_emit OUTCOME unchanged; squad_emit CHANGED no
    fi
    ;;
  finish)
    squad_vault_finish "$V" || exit 20
    if [ "${SQUAD_VAULT_PUSHED:-0}" -gt 0 ]; then
      squad_emit OUTCOME applied; squad_emit CHANGED yes
    else
      squad_emit OUTCOME unchanged; squad_emit CHANGED no
    fi
    ;;
  *) squad_fail 2 "usage: vault-pr.sh commit \"<message>\" <path>... | finish" ;;
esac
exit 0
