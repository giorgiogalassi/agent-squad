#!/usr/bin/env bash
# Path resolution utility, shared by every skill and agent in the squad.
# Resolves the vault path, the project root, and (if lore-config.json
# already maps this project) its display name.
#
# This is mechanism only, not policy: DISPLAY_NAME is printed empty when
# no mapping exists (or jq is unavailable to read one). What a caller
# does about an empty DISPLAY_NAME differs by skill — Seed stops and
# tells the user to run `lore start`; Forge, Chisel, Archy, Ralph, and
# Sidecar fall back to the basename of PROJECT_ROOT and continue; Lore
# is the one that creates the mapping in the first place. This script
# does not decide any of that — it only reports what's true right now.
#
# PROJECT_ROOT is resolved via `git rev-parse --git-common-dir`, not
# `--show-toplevel`. The two agree in a normal checkout, but
# `--show-toplevel` returns a *linked worktree's own* directory when run
# from inside one (e.g. a worktree Sidecar created) rather than the main
# project's — see PATH_RESOLUTION.md for why that matters and how this
# was verified. Falls back to `--show-toplevel` on git older than 2.31,
# which predates `--path-format`.
#
# Output: three KEY=VALUE lines on stdout, always in this order. Read
# them with the values a shell or an agent can both parse directly.
#
# Install (Claude Code): copy to ~/.claude/hooks/path-resolve.sh, chmod +x.
# Install (Codex): copy to ~/.codex/hooks/path-resolve.sh, chmod +x.
# Every skill and agent's "Path resolution protocol" runs this via a
# shell command as its first step instead of re-deriving the algorithm
# inline.

VAULT="${SECOND_BRAIN_PATH:-$HOME/second-brain}"

COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$COMMON_DIR" ]; then
  ROOT="$(dirname "$COMMON_DIR")"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
fi

DISPLAY=""
CONFIG="$VAULT/lore-config.json"
if [ -n "$ROOT" ] && [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
  DISPLAY="$(jq -r --arg k "$ROOT" '.projects[$k] // empty' "$CONFIG" 2>/dev/null)"
fi

echo "VAULT_PATH=$VAULT"
echo "PROJECT_ROOT=$ROOT"
echo "DISPLAY_NAME=$DISPLAY"
