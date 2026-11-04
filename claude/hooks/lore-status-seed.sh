#!/usr/bin/env bash
# lore-status-seed.sh -- scaffolds a new project's status.md for /seed (#465).
# Stamps `Last updated: <YYYY-MM-DD HH:MM> by seed` so the INDEX row /seed adds
# the same day agrees with status.md (vault-check INDEX_ROW_BEHIND). Contract:
# SCRIPT_CONTRACT.md (KEY=value lines on stdout).
#
# Usage: lore-status-seed.sh --vault <dir> --project <name> [--goal <one line>]
# Creates projects/<name>/ if absent. An existing status.md is never touched. Does not commit: /seed's
# `lore commit` lists status.md. Done/Next/... stay `—`.
# Stdout: OUTCOME=applied|unchanged  CHANGED=yes|no
# Exit: 0 ok, 2 usage, 20 I/O failure.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=squad-common.sh
. "$HOOK_DIR/squad-common.sh"

VAULT=""; NAME=""; GOAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) [ $# -ge 2 ] || squad_fail 2 "--vault needs a value"; VAULT="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || squad_fail 2 "--project needs a value"; NAME="$2"; shift 2 ;;
    --goal) [ $# -ge 2 ] || squad_fail 2 "--goal needs a value"; GOAL="$2"; shift 2 ;;
    *) squad_fail 2 "lore-status-seed.sh: unknown option $1" ;;
  esac
done
[ -n "$VAULT" ] && [ -n "$NAME" ] || squad_fail 2 "--vault and --project are required"

PROJ="$(squad_vault_rroot "$VAULT" "$NAME")/projects/$NAME"
STA="$PROJ/status.md"
if [ -f "$STA" ]; then
  squad_emit OUTCOME unchanged; squad_emit CHANGED no
  exit 0
fi

# One line only: a multi-line Goal would break the section layout.
mkdir -p "$PROJ" || squad_fail 20 "cannot create $PROJ"
GOAL="$(printf '%s' "$GOAL" | tr '\n\r' '  ' | sed 's/^ *//; s/ *$//')"
[ -n "$GOAL" ] || GOAL="—"
NOW="$(date '+%Y-%m-%d %H:%M')"

cat > "$STA" <<DOC || squad_fail 20 "cannot write status.md"
---
title: $NAME — Status
tags: [status, active]
project: $NAME
---

# Status — $NAME
Last updated: $NOW by seed

## Goal
$GOAL

## Done
—

## Next
—

## Blocked
—

## Last checkpoint
—

## Context refs
—
DOC
squad_emit OUTCOME applied; squad_emit CHANGED yes
exit 0
