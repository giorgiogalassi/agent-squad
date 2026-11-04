#!/usr/bin/env bash
# Path resolution utility, shared by every skill and agent in the squad.
# Resolves the vault path, the project root, and (if lore-config.json
# already maps this project) its display name.
#
# This is mechanism only, not policy: DISPLAY_NAME is printed empty when
# no mapping exists (or jq is unavailable to read one). What a caller
# does about an empty DISPLAY_NAME differs by skill — Seed and Lore do
# first contact through `lore map` (names and records the mapping); Forge,
# Chisel, Archy, and Ralph fall back to the basename of PROJECT_ROOT and
# continue; Lore also handles repair (re-mapping, migration). This script
# does not decide any of that — it only reports what's true right now.
#
# PROJECT_ROOT is resolved via `git rev-parse --git-common-dir`, not
# `--show-toplevel`. The two agree in a normal checkout, but
# `--show-toplevel` returns a *linked worktree's own* directory when run
# from inside one (e.g. a worktree `claude -w` created) rather than the main
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
# lore-config.local.json (untracked, same schema) is read first for both maps.
# status.md, decisions.md, preferences/, session.log, chisel-config.json,
# progress.txt and issues/ always stay in the vault regardless.
# SQUAD_DIR is a path only; callers check that it exists. With no project (empty
# DISPLAY_NAME and no PROJECT_ROOT) SQUAD_DIR and STATE_DIR are emitted empty,
# never with an empty `projects//` segment (#441).
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
# STATE_DIR is the per-project vault state directory:
# <vault>/projects/<name>/<state_dir>. The directory name comes only from
# the top-level `state_dir` key of lore-config.local.json / lore-config.json
# (a single path segment; the local file wins). Key absent: `.squad` when any
# projects/*/.squad/ already holds a state file (session.log, progress.txt,
# ralph-run.md, chisel-config.json, inbox/, issues/; existing vaults keep working,
# nothing moves), else `.lore`. SQUAD_DIR content (architecture.md, forge/, prd/)
# does not count, so Seed cannot flip the name (#442). No env var or client flag changes the name.
# STATE_DIR is always in the vault, also for `context: repo` projects.
# `path-resolve.sh --state-name` prints just the directory name (for scripts
# that hold a vault and a project name but no project root).
#
# Output: six KEY=VALUE lines on stdout, always in this order. Read
# them with the values a shell or an agent can both parse directly.
#
# Ships in the plugin's hooks/ directory; skills and agents call it as
# ${CLAUDE_PLUGIN_ROOT}/hooks/path-resolve.sh.
# Every skill and agent's "Path resolution protocol" runs this via Bash
# as its first step instead of re-deriving the algorithm inline.

VAULT="${SECOND_BRAIN_PATH:-$HOME/second-brain}"

# state_name: the state directory name for this vault (see STATE_DIR above).
state_name() {
  local f v=""
  for f in "$VAULT/lore-config.local.json" "$VAULT/lore-config.json"; do
    [ -f "$f" ] || continue
    if command -v jq >/dev/null 2>&1; then
      v="$(jq -r '.state_dir // empty | strings' "$f" 2>/dev/null)"
    else
      v="$(sed -n 's/.*"state_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)"
    fi
    case "$v" in
      ""|.|..|*/*) v="" ;;
      *) printf '%s' "$v"; return 0 ;;
    esac
  done
  # Fallback for vaults without the key: keep `.squad` when it already holds STATE
  # (#442). Only state files count; project knowledge (architecture.md, forge/, prd/)
  # lives in SQUAD_DIR, which stays `.squad` by design, so Seed writing it must not
  # flip the name. Read-only: nothing is pinned or written.
  for f in "$VAULT"/projects/*/.squad; do
    [ -d "$f" ] || continue
    for s in session.log progress.txt ralph-run.md chisel-config.json inbox issues; do
      if [ -e "$f/$s" ]; then printf '.squad'; return 0; fi
    done
  done
  printf '.lore'
}
if [ "${1:-}" = "--state-name" ]; then
  state_name; echo
  exit 0
fi

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
# Canonical (physical) root: /var vs /private/var and symlinks must match the keys
# `lore map` writes (#440). A non-git directory has no git root; its physical cwd is
# only a candidate and becomes PROJECT_ROOT when a config maps it (checked below).
CAND=""
if [ -n "$ROOT" ]; then
  ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P || printf '%s' "$ROOT")"
else
  CAND="$(pwd -P 2>/dev/null)"
fi

# lore-config.local.json (#355) is an optional, untracked file with the same
# `projects`/`context` schema, for projects whose name must stay out of the
# vault remote. It wins over lore-config.json per key; an unreadable local
# file is ignored.
DISPLAY=""
CONFIG="$VAULT/lore-config.json"
LOCAL_CONFIG="$VAULT/lore-config.local.json"
# Session worktrees (#440): in a PR-mode vault `lore map` commits the mapping on the
# open session branch (worktree <vault>/.claude/worktrees/lore-*), not in the
# checkout. SESSION_CONFIGS lists those worktrees' lore-config.json, newest commit
# first, and is read after the checkout's local and tracked configs. Once the vault PR
# merges and the worktree is cleaned up, the checkout carries the mapping and this
# list no longer matters. Read-only: nothing is written or fetched.
SESSION_CONFIGS=""
sess_configs() {
  local wt ts
  for wt in "$VAULT"/.claude/worktrees/lore-*; do
    [ -f "$wt/lore-config.json" ] || continue
    ts="$(git -C "$wt" log -1 --format=%ct 2>/dev/null)"
    printf '%s %s\n' "${ts:-0}" "$wt/lore-config.json"
  done | sort -k1,1nr -k2 | sed 's/^[0-9]* //'
}
# cfg_get <map> <root>: first non-empty value from the local, the tracked, then the
# session-worktree configs (newest first, one path per line in SESSION_CONFIGS).
cfg_get() {
  local f v
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    v="$(jq -r --arg k "$2" ".$1[\$k] // empty" "$f" 2>/dev/null)"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done <<EOF2
$LOCAL_CONFIG
$CONFIG
$SESSION_CONFIGS
EOF2
  return 0
}
# resolve_display <root>: DISPLAY from the checkout configs, then the session worktrees;
# names a conflict between session branches on stderr.
resolve_display() {
  local d f o
  d="$(cfg_get projects "$1")"
  if [ -z "$d" ]; then
    SESSION_CONFIGS="$(sess_configs)"
    d="$(cfg_get projects "$1")"
    if [ -n "$d" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        o="$(jq -r --arg k "$1" '.projects[$k] // empty' "$f" 2>/dev/null)"
        [ -n "$o" ] && [ "$o" != "$d" ] \
          && echo "path-resolve: session branches map $1 to different names ('$d' newest wins, '$o' in $f)" >&2
      done <<EOF3
$SESSION_CONFIGS
EOF3
    fi
  fi
  printf '%s' "$d"
}
# sess_squad_dir <name>: <worktree>/projects/<name>/.squad of the newest session
# worktree (lore-<name>-<date>[-N]) that has it; empty when none. A local-only
# project's worktrees are named lore-local-*, so they never match.
sess_squad_dir() {
  local wt t n d="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" pub
  [ -d "$VAULT/.claude/worktrees" ] || return 0
  pub="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')"
  # One open branch per project (#443): the same worktree squad_vault_wt picks, i.e.
  # the newest by date then -N suffix (a project's earlier ones have landed). $d is a glob.
  for wt in "$VAULT/.claude/worktrees/lore-$pub-"$d "$VAULT/.claude/worktrees/lore-$pub-"$d-[0-9]*; do
    [ -d "$wt/projects/$1/.squad" ] || continue
    t="${wt##*/lore-$pub-}"; n="${t:10}"; n="${n#-}"
    printf '%s %05d %s\n' "${t:0:10}" "${n:-0}" "$wt/projects/$1/.squad"
  done | sort | tail -n 1 | sed 's/^[^ ]* [^ ]* //'
}
if command -v jq >/dev/null 2>&1; then
  if [ -n "$ROOT" ]; then
    DISPLAY="$(resolve_display "$ROOT")"
  elif [ -n "$CAND" ]; then
    # Non-git directory: it is a project only when a config maps it.
    DISPLAY="$(resolve_display "$CAND")"
    [ -n "$DISPLAY" ] && ROOT="$CAND"
  fi
fi

CONTEXT=""
if [ -n "$ROOT" ] && { [ -f "$CONFIG" ] || [ -f "$LOCAL_CONFIG" ]; }; then
  if command -v jq >/dev/null 2>&1; then
    CONTEXT="$(cfg_get context "$ROOT")"
  elif grep -q '"context"' "$CONFIG" "$LOCAL_CONFIG" 2>/dev/null; then
    # Config declares per-project context but jq is missing: we cannot
    # read it, so say so instead of silently resolving to the vault.
    echo "path-resolve: jq not found; 'context' in $CONFIG ignored, SQUAD_DIR defaults to the vault" >&2
  fi
fi
NAME="${DISPLAY:-$(basename "$ROOT")}"
# No project (empty NAME: a non-git directory no config maps, #441): SQUAD_DIR and
# STATE_DIR stay empty. A path with an empty `projects//` segment is never built.
SQUAD_DIR=""; STATE_DIR=""
if [ -n "$NAME" ]; then
  if [ "$CONTEXT" = "repo" ] && [ -n "$ROOT" ]; then
    SQUAD_DIR="$ROOT/.squad"
  else
    SQUAD_DIR="$VAULT/projects/$NAME/.squad"
    # PR-mode vault (#443): Seed/Forge/Archy/Chisel write SQUAD_DIR content into the
    # project's session worktree (lore root), never the checkout, so until the vault
    # PR merges the files exist only there. A worktree holds the checkout's committed
    # files plus those writes, so readers take the newest session worktree's copy
    # when one has the folder. Read-only: nothing is created here.
    SESS_SQ="$(sess_squad_dir "$NAME")"
    [ -n "$SESS_SQ" ] && SQUAD_DIR="$SESS_SQ"
  fi
  STATE_DIR="$VAULT/projects/$NAME/$(state_name)"
fi

TRACKER_MODE="detached"
CHISEL_CONFIG="$STATE_DIR/chisel-config.json"
if [ -z "$STATE_DIR" ]; then
  : # no project: detached, nothing to report missing
elif [ ! -f "$CHISEL_CONFIG" ]; then
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
echo "STATE_DIR=$STATE_DIR"
