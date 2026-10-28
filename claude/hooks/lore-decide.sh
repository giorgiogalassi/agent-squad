#!/usr/bin/env bash
# lore-decide.sh -- the single write path for a project decision (#327).
# `lore prefer` (project-only) and the Lore agent's `lore decide` both call it.
# Contract: SCRIPT_CONTRACT.md (KEY=value lines on stdout).
#
# Usage: lore-decide.sh "<title>: <body>" [--supersedes "<YYYY-MM-DD> <title>"] [--rule]
#                       [--project <name>]
#
# Appends `## [YYYY-MM-DD] [rule] <title>` (the [rule] tag only with --rule) to
# <vault>/projects/<name>/decisions.md. With --supersedes the new entry gets
# `Supersedes: [date] <title>` and the named entry the inverse marker (through
# decisions-lint.sh fix). Over 60 active entries, fully superseded entries move
# to decisions-archive.md; the caps otherwise only warn (DECISIONS_OVER_CAP,
# DECISIONS_OVER_RULE_CAP), as `lore prefer` always did. Commits the vault.
#
# Stdout: OUTCOME=applied|unchanged  CHANGED=yes|no  ENTRY=[date] title
#         ARCHIVED=<n>  plus any DECISIONS_* finding of decisions-lint.sh.
# Exit: 0 ok, 2 usage, 10 precondition (supersedes target missing/ambiguous),
#       20 resolution or I/O failure.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=squad-common.sh
. "$HOOK_DIR/squad-common.sh"
LINT="$HOOK_DIR/decisions-lint.sh"

TEXT=""; SUPER=""; RULE=0; PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --supersedes) [ $# -ge 2 ] || squad_fail 2 "--supersedes needs a value"; SUPER="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || squad_fail 2 "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --rule) RULE=1; shift ;;
    -*) squad_fail 2 "unknown argument: $1" ;;
    *) [ -z "$TEXT" ] || squad_fail 2 "one decision text only"; TEXT="$1"; shift ;;
  esac
done
[ -n "$TEXT" ] || squad_fail 2 "usage: lore-decide.sh \"<title>: <body>\" [--supersedes \"<YYYY-MM-DD> <title>\"] [--rule]"
case "$TEXT$SUPER$PROJECT" in *$'\n'*) squad_fail 2 "newlines are not allowed in arguments" ;; esac

squad_resolve || exit 20
NAME="${PROJECT:-${DISPLAY_NAME:-}}"
[ -n "$NAME" ] || squad_fail 20 "no project name resolved"
FILE="$VAULT_PATH/projects/$NAME/decisions.md"
mkdir -p "$(dirname "$FILE")" || squad_fail 20 "cannot create $(dirname "$FILE")"

case "$TEXT" in
  *": "*) TITLE="${TEXT%%: *}"; BODY="${TEXT#*: }" ;;
  *) TITLE="$TEXT"; BODY="" ;;
esac
TODAY="$(date +%Y-%m-%d)"
ENTRY="[$TODAY] $TITLE"

heads() { grep -E '^## \[[0-9]{4}-[0-9]{2}-[0-9]{2}\]' "$FILE" 2>/dev/null | sed -E 's/[[:space:]]+$//'; }

if [ -f "$FILE" ] && heads | sed -E 's/^## (\[[0-9-]+\]) (\[rule\] )?/\1 /' | grep -qxF -- "$ENTRY"; then
  squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit ENTRY "$ENTRY"
  exit 0
fi

SUPLINE=""
if [ -n "$SUPER" ]; then
  case "$SUPER" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ ?*) ;;
    *) squad_fail 2 "--supersedes expects \"<YYYY-MM-DD> <title>\"" ;;
  esac
  SD="${SUPER%% *}"; ST="${SUPER#* }"
  [ -f "$FILE" ] || squad_fail 10 "no decisions.md to supersede in"
  N="$(heads | sed -E 's/^## (\[[0-9-]+\]) (\[rule\] )?/\1 /' | grep -cxF -- "[$SD] $ST")"
  [ "$N" = 1 ] || squad_fail 10 "--supersedes matches $N entries for \"$SUPER\" (need exactly one)"
  SUPLINE="Supersedes: [$SD] $ST"
fi

if [ ! -f "$FILE" ]; then
  printf -- '---\ntitle: %s — Decisions\ntags: [decisions]\nproject: %s\n---\n\n# Decisions — %s\n\n> Append-only. Format: `## [YYYY-MM-DD] <decision title>`\n> Managed by Lore.\n' \
    "$NAME" "$NAME" "$NAME" > "$FILE" || squad_fail 20 "cannot write $FILE"
fi
{
  printf '\n## [%s] %s%s\n' "$TODAY" "$([ "$RULE" = 1 ] && printf '[rule] ')" "$TITLE"
  [ -n "$SUPLINE" ] && printf '%s\n' "$SUPLINE"
  [ -n "$BODY" ] && printf '%s\n' "$BODY"
} >> "$FILE" || squad_fail 20 "cannot write $FILE"

bash "$LINT" fix "$FILE" >/dev/null || squad_fail 20 "decisions-lint fix failed"

# Cap: over 60 active entries, move fully superseded ones to the archive.
ARCHIVED=0
ACTIVE_OVER="$(bash "$LINT" check "$FILE" | sed -n 's/^DECISIONS_OVER_CAP=//p')"
if [ -n "$ACTIVE_OVER" ]; then
  ARCH="$(dirname "$FILE")/decisions-archive.md"
  KEEP="$FILE.keep.$$"; MOVE="$FILE.move.$$"
  awk -v keep="$KEEP" -v move="$MOVE" '
    function flush() {
      if (n == 0) return
      if (sup) { for (i = 1; i <= n; i++) print buf[i] > move; moved++ }
      else for (i = 1; i <= n; i++) print buf[i] > keep
      n = 0; sup = 0
    }
    /^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ { flush(); inentry = 1 }
    /^#+ / && !/^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ { flush(); inentry = 0 }
    { if (!inentry) print > keep; else { buf[++n] = $0; if ($0 ~ /^Superseded by: /) sup = 1 } }
    END { flush(); print moved + 0 }' "$FILE" > "$FILE.cnt.$$"
  ARCHIVED="$(cat "$FILE.cnt.$$")"; rm -f "$FILE.cnt.$$"
  if [ "${ARCHIVED:-0}" -gt 0 ] && [ -f "$MOVE" ]; then
    [ -f "$ARCH" ] || printf '# Decisions archive — %s\n' "$NAME" > "$ARCH"
    { printf '\n'; cat "$MOVE"; } >> "$ARCH" && mv "$KEEP" "$FILE" || ARCHIVED=0
  fi
  rm -f "$KEEP" "$MOVE"
fi

_paths="projects/$NAME/decisions.md"
[ -f "$(dirname "$FILE")/decisions-archive.md" ] && _paths="$_paths projects/$NAME/decisions-archive.md"
# shellcheck disable=SC2086
squad_vault_commit "$VAULT_PATH" "$NAME" "[lore] $(squad_public_name "$VAULT_PATH" "$NAME") decide $(date '+%Y-%m-%d %H:%M')" $_paths

squad_emit OUTCOME applied; squad_emit CHANGED yes; squad_emit ENTRY "$ENTRY"; squad_emit ARCHIVED "$ARCHIVED"
bash "$LINT" check "$FILE" | grep -E '^DECISIONS_(OVER_CAP|OVER_RULE_CAP|BULLETS)=' || true
exit 0
