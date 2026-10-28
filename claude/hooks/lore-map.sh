#!/usr/bin/env bash
# lore-map.sh -- writes one project mapping into the vault config, choosing the
# target deterministically (#372). Called by `/seed` and `lore start`. Contract:
# SCRIPT_CONTRACT.md (KEY=value lines on stdout).
#
# Usage: lore-map.sh set --root <path> --name <display> [--local] [--vault <dir>]
#        lore-map.sh ignore [--vault <dir>]
#
# set: `projects[<root>] = <name>` goes to lore-config.local.json when --local is
#   passed or the vault git-ignores projects/<name>/ (squad_local_only), else to
#   lore-config.json. A local-only name never reaches the tracked file. The tracked
#   write is committed through squad_vault_commit; the local file is never
#   committed and the vault .gitignore is made to list it.
# ignore: creates the vault .gitignore listing lore-config.local.json, or appends
#   the line when missing; committed when the vault is a git repo.
#
# Stdout: OUTCOME=applied|unchanged  CHANGED=yes|no  [TARGET=local|tracked]
# Exit: 0 ok, 2 usage, 10 precondition (no jq, no vault, config is not valid JSON),
#       20 resolution or I/O failure.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=squad-common.sh
. "$HOOK_DIR/squad-common.sh"

VERB="${1:-}"; [ $# -gt 0 ] && shift
VAULT=""; ROOT=""; NAME=""; LOCAL=no
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) [ $# -ge 2 ] || squad_fail 2 "--vault needs a value"; VAULT="$2"; shift 2 ;;
    --root) [ $# -ge 2 ] || squad_fail 2 "--root needs a value"; ROOT="$2"; shift 2 ;;
    --name) [ $# -ge 2 ] || squad_fail 2 "--name needs a value"; NAME="$2"; shift 2 ;;
    --local) LOCAL=yes; shift ;;
    *) squad_fail 2 "lore-map.sh: unknown option $1" ;;
  esac
done
case "$VERB" in set|ignore) ;; *) squad_fail 2 "usage: lore-map.sh set|ignore [options]" ;; esac
if [ "$VERB" = set ]; then
  [ -n "$ROOT" ] && [ -n "$NAME" ] || squad_fail 2 "set needs --root and --name"
fi

if [ -z "$VAULT" ]; then
  squad_resolve || squad_fail 20 "path resolution failed"
  VAULT="$VAULT_PATH"
fi
[ -d "$VAULT" ] || squad_fail 10 "no vault at $VAULT"

is_git_vault() { [ "$(git -C "$VAULT" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$VAULT" && pwd -P)" ]; }

# ensure_ignore: 0 changed, 1 already listed; 20 on I/O error.
ensure_ignore() {
  local gi="$VAULT/.gitignore"
  # The pattern also covers lore-config.local.json.tmp.<pid> left by a killed write.
  if [ -f "$gi" ] && grep -qxF 'lore-config.local.json*' "$gi"; then return 1; fi
  if [ -s "$gi" ] && [ -n "$(tail -c 1 "$gi")" ]; then printf '\n' >> "$gi" || return 20; fi
  printf 'lore-config.local.json*\n' >> "$gi" || return 20
  return 0
}

if [ "$VERB" = ignore ]; then
  rc=0; ensure_ignore || rc=$?
  [ "$rc" = 20 ] && squad_fail 20 "cannot write $VAULT/.gitignore"
  if [ "$rc" = 1 ]; then squad_emit OUTCOME unchanged; squad_emit CHANGED no; exit 0; fi
  is_git_vault && squad_vault_commit "$VAULT" vault "[lore] ignore local config" .gitignore
  squad_emit OUTCOME applied; squad_emit CHANGED yes
  exit 0
fi

command -v jq >/dev/null 2>&1 || squad_fail 10 "jq is required to write the mapping"

if [ "$LOCAL" = yes ] || squad_local_only "$VAULT" "$NAME"; then
  TARGET=local; FILE="$VAULT/lore-config.local.json"
else
  TARGET=tracked; FILE="$VAULT/lore-config.json"
fi

if [ -s "$FILE" ]; then
  jq empty "$FILE" >/dev/null 2>&1 || squad_fail 10 "$(basename "$FILE") is not valid JSON; fix it by hand, it was not touched"
  SRC="$FILE"
else
  SRC=""
fi

CHANGED=no
if [ "$TARGET" = local ]; then
  # Ignore rule first: the name must never exist in the vault before it is ignored.
  rc=0; ensure_ignore || rc=$?
  [ "$rc" = 20 ] && squad_fail 20 "cannot write $VAULT/.gitignore"
  if [ "$rc" = 0 ]; then
    CHANGED=yes
    is_git_vault && squad_vault_commit "$VAULT" vault "[lore] ignore local config" .gitignore
  fi
fi

if [ -n "$SRC" ] && [ "$(jq -r --arg k "$ROOT" '.projects[$k] // empty' "$SRC")" = "$NAME" ]; then
  :
else
  TMP="$FILE.tmp.$$"
  trap 'rm -f "$TMP"' EXIT
  if [ -n "$SRC" ]; then
    jq --arg k "$ROOT" --arg n "$NAME" '.projects[$k] = $n' "$SRC" > "$TMP"
  else
    echo '{"projects":{}}' | jq --arg k "$ROOT" --arg n "$NAME" '.projects[$k] = $n' > "$TMP"
  fi || squad_fail 20 "jq failed; $(basename "$FILE") was not touched"
  mv "$TMP" "$FILE" || squad_fail 20 "cannot write $FILE"
  CHANGED=yes
  if [ "$TARGET" = tracked ]; then
    is_git_vault && squad_vault_commit "$VAULT" "$NAME" "[lore] map project $NAME" lore-config.json
  fi
fi

if [ "$TARGET" = local ]; then
  # A root already in the tracked config is moved out of it; history is not rewritten.
  TRK="$VAULT/lore-config.json"
  if [ -s "$TRK" ] && jq empty "$TRK" >/dev/null 2>&1 \
     && [ -n "$(jq -r --arg k "$ROOT" '.projects[$k] // empty' "$TRK")" ]; then
    TTMP="$TRK.tmp.$$"
    trap 'rm -f "${TMP:-}" "$TTMP"' EXIT
    jq --arg k "$ROOT" 'del(.projects[$k])' "$TRK" > "$TTMP" || squad_fail 20 "jq failed; lore-config.json was not touched"
    mv "$TTMP" "$TRK" || squad_fail 20 "cannot write $TRK"
    # Message is name-free on purpose.
    is_git_vault && squad_vault_commit "$VAULT" "$NAME" "[lore] unmap project from shared config" lore-config.json
    echo "lore-map: the project name is still in the vault git history; history was not rewritten" >&2
    CHANGED=yes
  fi
fi
if [ "$CHANGED" = yes ]; then squad_emit OUTCOME applied; else squad_emit OUTCOME unchanged; fi
squad_emit CHANGED "$CHANGED"; squad_emit TARGET "$TARGET"
exit 0
