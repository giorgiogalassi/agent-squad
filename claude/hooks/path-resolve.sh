#!/usr/bin/env bash
# Path resolution utility, shared by every skill and agent in the squad.
# Resolves the vault path, the project root, and (if lore-config.json
# already maps this project) its display name.
#
# This is mechanism only, not policy: DISPLAY_NAME is printed empty when
# no mapping exists (or jq is unavailable to read one). What a caller
# does about an empty DISPLAY_NAME differs by skill — Seed does first
# contact itself (names and records the mapping); Forge, Chisel, Archy, Ralph, and
# Sidecar fall back to the basename of PROJECT_ROOT and continue; Lore
# handles repair (re-mapping, migration). This script
# does not decide any of that — it only reports what's true right now.
#
# PROJECT_ROOT is resolved via `git rev-parse --git-common-dir`, not
# `--show-toplevel`. The two agree in a normal checkout, but
# `--show-toplevel` returns a *linked worktree's own* directory when run
# from inside one (e.g. a worktree Sidecar created) rather than the main
# project's — see PATH_RESOLUTION.md for why that matters and how this
# was verified.
#
# `--path-format=absolute` requires git 2.31+. Git older than that does
# NOT fail on the unrecognised flag — verified directly: `git rev-parse`
# echoes any option it doesn't recognise back to stdout as a literal
# line and keeps processing the rest of the command, exiting 0. So
# `COMMON_DIR` would come back as a two-line string (the echoed flag
# plus the real --git-common-dir output) instead of failing, and a bare
# `-n "$COMMON_DIR"` check can't tell that apart from success. Instead
# the output is validated: it must be exactly one line and an existing
# directory. Falls back to `--show-toplevel` when that validation fails.
#
# Submodules: `--git-common-dir` from inside a submodule resolves to
# `<super>/.git/modules/<name>`, not the submodule's own root, so the
# common-dir path is skipped entirely when
# `--show-superproject-working-tree` reports we're inside one, and
# `--show-toplevel` (the submodule's own checkout root) is used
# instead. This means PROJECT_ROOT for a submodule opened as a linked
# worktree is not resolved correctly (an unsupported combination); plain
# submodule checkouts resolve correctly.
#
# SQUAD_DIR is where project knowledge lives (architecture.md,
# scout-cache.md, forge/, prd/). lore-config.json may carry an optional
# top-level `context` map keyed by project root, like `projects`:
# `"context": {"/abs/root": "repo"}`. `repo` -> <PROJECT_ROOT>/.squad;
# anything else or absent -> <vault>/projects/<name>/.squad (default).
# status.md, decisions.md, preferences/, session.log, chisel-config.json,
# progress.txt and issues/ always stay in the vault regardless.
# SQUAD_DIR is a path only; callers check that it exists.
#
# TRACKER_MODE is `connected` or `detached`, read from `chisel.mode` in
# <VAULT>/projects/<name>/.squad/chisel-config.json (always the vault,
# never SQUAD_DIR). It is `connected` only when the file exists, jq can
# read it and the value is exactly "connected"; any doubt (file missing,
# key missing, unknown value, jq missing) yields `detached` plus one
# stderr line. A config without `mode` is detached here on purpose:
# Chisel's "no mode = connected" rule is for its config flow, not for
# write safety.
#
# TRACKER_MODE gates where squad tickets are written (Chisel). It is NOT
# where Reven reads the project's issue and PR: that comes from the
# `## Issue tracker and PR host` section of architecture.md.
#
# Output: five KEY=VALUE lines on stdout, always in this order. Read
# them with the values a shell or an agent can both parse directly.
#
# Install: copy to ~/.claude/hooks/path-resolve.sh, chmod +x.
# Every skill and agent's "Path resolution protocol" runs this via Bash
# as its first step instead of re-deriving the algorithm inline.

VAULT="${SECOND_BRAIN_PATH:-$HOME/second-brain}"

ROOT=""
SUPERPROJECT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"
if [ -z "$SUPERPROJECT" ]; then
  COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  LINE_COUNT="$(printf '%s\n' "$COMMON_DIR" | wc -l | tr -d ' ')"
  if [ -n "$COMMON_DIR" ] && [ "$LINE_COUNT" = "1" ] && [ -d "$COMMON_DIR" ]; then
    ROOT="$(dirname "$COMMON_DIR")"
  fi
fi
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
fi

DISPLAY=""
CONFIG="$VAULT/lore-config.json"
if [ -n "$ROOT" ] && [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
  DISPLAY="$(jq -r --arg k "$ROOT" '.projects[$k] // empty' "$CONFIG" 2>/dev/null)"
fi

CONTEXT=""
if [ -n "$ROOT" ] && [ -f "$CONFIG" ]; then
  if command -v jq >/dev/null 2>&1; then
    CONTEXT="$(jq -r --arg k "$ROOT" '.context[$k] // empty' "$CONFIG" 2>/dev/null)"
  elif grep -q '"context"' "$CONFIG" 2>/dev/null; then
    # Config declares per-project context but jq is missing: we cannot
    # read it, so say so instead of silently resolving to the vault.
    echo "path-resolve: jq not found; 'context' in $CONFIG ignored, SQUAD_DIR defaults to the vault" >&2
  fi
fi
NAME="${DISPLAY:-$(basename "$ROOT")}"
if [ "$CONTEXT" = "repo" ] && [ -n "$ROOT" ]; then
  SQUAD_DIR="$ROOT/.squad"
else
  SQUAD_DIR="$VAULT/projects/$NAME/.squad"
fi

TRACKER_MODE="detached"
CHISEL_CONFIG="$VAULT/projects/$NAME/.squad/chisel-config.json"
if [ ! -f "$CHISEL_CONFIG" ]; then
  echo "path-resolve: $CHISEL_CONFIG not found; TRACKER_MODE=detached" >&2
elif ! command -v jq >/dev/null 2>&1; then
  echo "path-resolve: jq not found; cannot read chisel.mode, TRACKER_MODE=detached" >&2
else
  MODE="$(jq -r '.chisel.mode // empty' "$CHISEL_CONFIG" 2>/dev/null)"
  case "$MODE" in
    connected) TRACKER_MODE="connected" ;;
    detached) ;;
    "") echo "path-resolve: chisel.mode missing or unreadable in $CHISEL_CONFIG; TRACKER_MODE=detached" >&2 ;;
    *) echo "path-resolve: unrecognized chisel.mode '$MODE' in $CHISEL_CONFIG; TRACKER_MODE=detached" >&2 ;;
  esac
fi

echo "VAULT_PATH=$VAULT"
echo "PROJECT_ROOT=$ROOT"
echo "DISPLAY_NAME=$DISPLAY"
echo "SQUAD_DIR=$SQUAD_DIR"
echo "TRACKER_MODE=$TRACKER_MODE"
