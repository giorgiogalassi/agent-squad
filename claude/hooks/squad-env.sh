#!/usr/bin/env bash
# Squad SessionStart env export. Runs path-resolve.sh once and appends the six
# resolved values to $CLAUDE_ENV_FILE as shell-quoted `export` lines, so every
# later Bash call in the session (skills and subagents included) sees
# SQUAD_VAULT_PATH, SQUAD_PROJECT_ROOT, SQUAD_DISPLAY_NAME, SQUAD_DIR and
# SQUAD_TRACKER_MODE, SQUAD_STATE_DIR and LORE_STATE_DIR (same value: the
# per-project vault state directory) and LORE_BIN (the dispatcher shim path)
# without re-running the script. path-resolve.sh stays the
# single source of the algorithm (PATH_RESOLUTION.md); this hook only transports
# its output.
#
# Registered by hooks/hooks.json (SessionStart), matcher startup|clear|compact|resume,
# in its own entry: lore-orient early-exits on resume, so it cannot share one.
# A resumed session likely gets a fresh env file, hence resume is included.
# CwdChanged is deliberately not registered: path-resolve.sh resolves a linked
# worktree to its main project, so the values do not change when the session
# works inside a `claude -w` worktree, and a Bash `cd` never changes the project.
#
# Idempotent: earlier SQUAD_* export lines are removed before the new ones are
# appended, so clear/compact never leave duplicates. Never blocks: always exit 0;
# no CLAUDE_ENV_FILE or no usable resolution is a silent no-op.

[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -f "$HOOK_DIR/path-resolve.sh" ] || exit 0

# The session's own directory comes from the hook input (cwd), when given.
HOOK_INPUT=""
if [ ! -t 0 ]; then
  IFS= read -r -t 2 -d '' HOOK_INPUT || true
fi
if [ -n "$HOOK_INPUT" ]; then
  if command -v jq >/dev/null 2>&1; then
    HOOK_CWD="$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  else
    HOOK_CWD="$(printf '%s' "$HOOK_INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  fi
  [ -n "$HOOK_CWD" ] && cd "$HOOK_CWD" 2>/dev/null
fi

# squote <value>: single-quoted shell word, safe for spaces and quotes.
squote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Dispatcher shim (#428): a stable user-level entry point to this plugin's
# `lore`, so other plugins' hooks and headless runs reach it without the session
# env. Installed only when this plugin is the same version or newer than the
# installed shim (a numeric compare, never a downgrade); replaced with temp + mv
# in the same directory so a concurrent execution never sees a partial file.
# Not added to PATH. Best-effort: every failure is silent.
LORE_BIN_PATH="${XDG_DATA_HOME:-${HOME:-}/.local/share}/lore/bin/lore"

# ver_ge <a> <b>: 0 when dotted numeric version a >= b (missing parts are 0).
ver_ge() {
  local a="$1" b="$2" x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x="${a%%.*}"; y="${b%%.*}"
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
  done
  return 0
}

install_lore_shim() {
  local plugin_dir pj v cur shim_dir tmp
  [ -n "${HOME:-}${XDG_DATA_HOME:-}" ] || return 0
  plugin_dir="$(cd "$HOOK_DIR/.." 2>/dev/null && pwd)" || return 0
  [ -f "$HOOK_DIR/lore" ] || return 0
  pj="$plugin_dir/.claude-plugin/plugin.json"
  [ -f "$pj" ] || pj="$plugin_dir/plugin.json"
  v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" 2>/dev/null | head -n 1)"
  case "$v" in ''|*[!0-9.]*) return 0 ;; esac
  if [ -f "$LORE_BIN_PATH" ]; then
    cur="$(sed -n "s/^LORE_VERSION=['\"]\{0,1\}\([0-9][0-9.]*\).*/\1/p" "$LORE_BIN_PATH" 2>/dev/null | head -n 1)"
    if [ -n "$cur" ] && ! ver_ge "$v" "$cur"; then return 0; fi
  fi
  shim_dir="$(dirname "$LORE_BIN_PATH")"
  mkdir -p "$shim_dir" 2>/dev/null || return 0
  tmp="$(mktemp "$shim_dir/.lore.XXXXXX" 2>/dev/null)" || return 0
  {
    printf '#!/bin/sh\n'
    printf '# Installed by the agent-squad plugin (SessionStart). Do not edit.\n'
    printf 'LORE_PLUGIN_DIR=%s\n' "$(squote "$plugin_dir")"
    printf "LORE_VERSION='%s'\n" "$v"
    printf '[ -x "$LORE_PLUGIN_DIR/hooks/lore" ] || exit 0\n'
    printf 'exec "$LORE_PLUGIN_DIR/hooks/lore" "$@"\n'
  } > "$tmp" 2>/dev/null && chmod 755 "$tmp" 2>/dev/null && mv -f "$tmp" "$LORE_BIN_PATH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

install_lore_shim

# Parsed line by line, never eval'd: the output is not shell-quoted.
V_VAULT=""; V_ROOT=""; V_NAME=""; V_DIR=""; V_MODE=""; V_STATE=""; GOT_ROOT=0
while IFS='=' read -r _k _v; do
  case "$_k" in
    VAULT_PATH) V_VAULT="$_v" ;;
    PROJECT_ROOT) V_ROOT="$_v"; GOT_ROOT=1 ;;
    DISPLAY_NAME) V_NAME="$_v" ;;
    SQUAD_DIR) V_DIR="$_v" ;;
    TRACKER_MODE) V_MODE="$_v" ;;
    STATE_DIR) V_STATE="$_v" ;;
  esac
done < <(bash "$HOOK_DIR/path-resolve.sh" 2>/dev/null)
[ "$GOT_ROOT" = 1 ] || exit 0


# Drop earlier lines for our own keys (idempotence), keep everything else.
TMP="$(mktemp "${TMPDIR:-/tmp}/squad-env.XXXXXX" 2>/dev/null)" || exit 0
if [ -f "$CLAUDE_ENV_FILE" ]; then
  grep -Ev '^export (SQUAD_(VAULT_PATH|PROJECT_ROOT|DISPLAY_NAME|DIR|TRACKER_MODE|STATE_DIR)|LORE_(STATE_DIR|BIN))=' "$CLAUDE_ENV_FILE" > "$TMP" 2>/dev/null || true
fi
{
  printf 'export SQUAD_VAULT_PATH=%s\n' "$(squote "$V_VAULT")"
  printf 'export SQUAD_PROJECT_ROOT=%s\n' "$(squote "$V_ROOT")"
  printf 'export SQUAD_DISPLAY_NAME=%s\n' "$(squote "$V_NAME")"
  printf 'export SQUAD_DIR=%s\n' "$(squote "$V_DIR")"
  printf 'export SQUAD_TRACKER_MODE=%s\n' "$(squote "$V_MODE")"
  printf 'export SQUAD_STATE_DIR=%s\n' "$(squote "$V_STATE")"
  printf 'export LORE_STATE_DIR=%s\n' "$(squote "$V_STATE")"
  printf 'export LORE_BIN=%s\n' "$(squote "$LORE_BIN_PATH")"
} >> "$TMP"
cat "$TMP" > "$CLAUDE_ENV_FILE" 2>/dev/null
rm -f "$TMP"
exit 0
