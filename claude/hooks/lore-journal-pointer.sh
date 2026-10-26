#!/usr/bin/env bash
# lore-journal-pointer.sh -- writes the JOURNAL pointer for a `context: repo`
# project (#330). Called by `/seed` and `lore start`. Contract:
# SCRIPT_CONTRACT.md (KEY=value lines on stdout).
#
# Usage: lore-journal-pointer.sh [--vault <dir>] [--project <name>] [--root <dir>]
#                                [--context repo]
#
# Without flags the project is resolved with path-resolve.sh; it is
# `context: repo` when SQUAD_DIR is not <vault>/projects/<name>/.squad.
# Writes exactly two lines, both idempotent:
#   decisions.md  `Decisions for this project live in <root>/JOURNAL.md
#                 (context: repo); this file holds vault-only rules.`
#                 placed after the H1 (or the front matter); an existing header
#                 line is replaced in place, never duplicated. Decision entries
#                 are never read or rewritten.
#   status.md     one line under `## Context refs` (section created if absent;
#                 the lone `—` placeholder is dropped):
#                 `- <root>/JOURNAL.md (context: repo decisions)`, or
#                 `... (context: repo decisions; file missing)` when the file
#                 does not exist. The absolute path is skipped by the
#                 orientation's vault-relative ref loader on purpose; the
#                 JOURNAL tail itself is injected by lore-orient.sh.
# Not `context: repo` -> OUTCOME=unchanged, nothing written.
# Commits only the files it wrote when the vault is a git repo.
#
# Stdout: OUTCOME=applied|unchanged  CHANGED=yes|no  JOURNAL=present|missing
# Exit: 0 ok, 2 usage, 10 precondition (no project / status or decisions file
#       absent), 20 resolution or I/O failure.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=squad-common.sh
. "$HOOK_DIR/squad-common.sh"

VAULT=""; NAME=""; ROOT=""; CTX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) [ $# -ge 2 ] || squad_fail 2 "--vault needs a value"; VAULT="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || squad_fail 2 "--project needs a value"; NAME="$2"; shift 2 ;;
    --root) [ $# -ge 2 ] || squad_fail 2 "--root needs a value"; ROOT="$2"; shift 2 ;;
    --context) [ $# -ge 2 ] || squad_fail 2 "--context needs a value"; CTX="$2"; shift 2 ;;
    *) squad_fail 2 "lore-journal-pointer.sh: unknown option $1" ;;
  esac
done

if [ -z "$VAULT" ] || [ -z "$NAME" ] || [ -z "$ROOT" ]; then
  squad_resolve || squad_fail 20 "path resolution failed"
  [ -z "$VAULT" ] && VAULT="$VAULT_PATH"
  [ -z "$NAME" ] && NAME="$DISPLAY_NAME"
  [ -z "$ROOT" ] && ROOT="$PROJECT_ROOT"
  if [ -z "$CTX" ] && [ -n "${SQUAD_DIR:-}" ] && [ -n "$NAME" ] \
     && [ "$SQUAD_DIR" != "$VAULT/projects/$NAME/.squad" ]; then
    CTX=repo
  fi
fi
[ -n "$NAME" ] || squad_fail 10 "no project resolved (use --project or run inside a mapped project)"
[ -d "$VAULT/projects/$NAME" ] || squad_fail 10 "no vault project at $VAULT/projects/$NAME"

if [ "$CTX" != repo ]; then
  squad_emit OUTCOME unchanged; squad_emit CHANGED no
  exit 0
fi

PROJ="$VAULT/projects/$NAME"
JOURNAL="$ROOT/JOURNAL.md"
if [ -f "$JOURNAL" ]; then
  STATE=present; SUFFIX="(context: repo decisions)"
else
  STATE=missing; SUFFIX="(context: repo decisions; file missing)"
fi
HEADER="Decisions for this project live in $JOURNAL (context: repo); this file holds vault-only rules."
REFLINE="- $JOURNAL $SUFFIX"
DEC="$PROJ/decisions.md"; STA="$PROJ/status.md"
[ -f "$DEC" ] || squad_fail 10 "decisions.md missing for $NAME; run /seed first"
[ -f "$STA" ] || squad_fail 10 "status.md missing for $NAME; run /seed first"

TMP="$(mktemp "${TMPDIR:-/tmp}/journal-pointer.XXXXXX")" || squad_fail 20 "mktemp failed"
trap 'rm -f "$TMP"' EXIT
WROTE=""

# decisions.md: replace the existing header line, else insert after the H1
# (or the front matter, or at the top). Nothing else is touched.
if ! grep -qxF -- "$HEADER" "$DEC"; then
  HDR="$HEADER" awk '
    BEGIN { h = ENVIRON["HDR"]; fm = 0; done = 0 }
    function ins() { print ""; print h; done = 1 }
    /^Decisions for this project live in / { if (!done) { print h; done = 1 } ; next }
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm == 1 { print; if ($0 == "---") fm = 2; next }
    { print }
    (fm == 2 || fm == 0) && !done && /^# / && !seen { seen = 1; ins() }
    END { }
  ' "$DEC" > "$TMP" || squad_fail 20 "cannot rewrite decisions.md"
  # Header pre-existing but stale: the awk replaced it in place. Not found
  # anywhere and no H1: place it right after the front matter / at the top.
  if ! grep -qxF -- "$HEADER" "$TMP"; then
    HDR="$HEADER" awk '
      BEGIN { h = ENVIRON["HDR"]; fm = 0; done = 0 }
      NR == 1 && $0 == "---" { fm = 1; print; next }
      fm == 1 { print; if ($0 == "---") { fm = 2; print ""; print h; done = 1 } ; next }
      NR == 1 { print h; print ""; done = 1 }
      { print }
    ' "$DEC" > "$TMP" || squad_fail 20 "cannot rewrite decisions.md"
  fi
  cat "$TMP" > "$DEC" || squad_fail 20 "cannot write decisions.md"
  WROTE="projects/$NAME/decisions.md"
fi

# status.md: drop stale pointer lines and the lone placeholder inside
# `## Context refs`, put the current line first in the section.
if ! awk '/^## /{on = ($0 == "## Context refs"); next} on' "$STA" | grep -qxF -- "$REFLINE"; then
  if grep -qx '## Context refs' "$STA"; then
    LINE="$REFLINE" awk '
      BEGIN { l = ENVIRON["LINE"]; on = 0 }
      /^## / { on = ($0 == "## Context refs"); print; if (on) print l; next }
      on && ($0 == "—" || $0 ~ /JOURNAL\.md \(context: repo/) { next }
      { print }
    ' "$STA" > "$TMP" || squad_fail 20 "cannot rewrite status.md"
  else
    { cat "$STA"; printf '\n## Context refs\n%s\n' "$REFLINE"; } > "$TMP" || squad_fail 20 "cannot rewrite status.md"
  fi
  cat "$TMP" > "$STA" || squad_fail 20 "cannot write status.md"
  WROTE="$WROTE${WROTE:+ }projects/$NAME/status.md"
fi

if [ -z "$WROTE" ]; then
  squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit JOURNAL "$STATE"
  exit 0
fi

if [ "$(git -C "$VAULT" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$VAULT" && pwd -P)" ]; then
  # shellcheck disable=SC2086
  git -C "$VAULT" add -- $WROTE >/dev/null 2>&1 \
    && git -C "$VAULT" commit -q -m "[lore] $NAME journal pointer" -- $WROTE >/dev/null 2>&1 || true
fi
squad_emit OUTCOME applied; squad_emit CHANGED yes; squad_emit JOURNAL "$STATE"
exit 0
