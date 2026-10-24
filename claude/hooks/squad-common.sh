#!/usr/bin/env bash
# squad-common.sh -- shared guard and output helpers for squad scripts.
# SOURCE this file; do not execute it. Bash 3.2 compatible. Contract:
# see SCRIPT_CONTRACT.md at the repo root.
#
# Functions that EXIT the calling script:   squad_fail
# Functions that RETURN a code (no exit):   squad_resolve, squad_gh_write,
#                                           squad_record_local, squad_emit
# Return codes: squad_resolve 0/20; squad_gh_write 0/20;
#   squad_record_local 0 changed / 1 unchanged / 20 I/O error;
#   squad_emit 0/2. The 1 is library-only, never a script exit code; callers
#   under `set -e` must guard it (`squad_record_local ... || rc=$?`).
#
# path-resolve.sh is located in the same directory as the file that
# sources this one, so it works from the repo and from the plugin root.

# Directory of the sourcing script (BASH_SOURCE[1] when sourced).
SQUAD_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"

# Directory of this file (squad-incidents.sh lives beside it).
SQUAD_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# squad_fail <code> <reason>: one stderr line, then exit <code>.
squad_fail() {
  local code="$1"; shift
  local reason
  reason="$(printf '%s' "$*" | tr '\n' ' ')"
  printf '%s\n' "$reason" >&2
  exit "$code"
}

# squad_incident <component> <exit> <reason> [kind]: record an incident via
# squad-incidents.sh (same dir as this file). Opt-in; silent, never fails,
# safe under set -e and before squad_resolve (store path has its own fallback).
squad_incident() {
  bash "$SQUAD_COMMON_DIR/squad-incidents.sh" record --source script \
    --kind "${4:-failure}" --component "${1:-}" --exit "${2:-}" --reason "${3:-}" \
    --project "${DISPLAY_NAME:-}" --session "${CLAUDE_SESSION_ID:-}" \
    >/dev/null 2>&1 || true
  return 0
}

# squad_fail_incident <component> <code> <reason>: squad_incident, then squad_fail.
squad_fail_incident() {
  squad_incident "$1" "$2" "$3"
  squad_fail "$2" "$3"
}

# squad_resolve: run path-resolve.sh and export VAULT_PATH, PROJECT_ROOT,
# DISPLAY_NAME, SQUAD_DIR, TRACKER_MODE. Returns 0, or 20 if resolution fails.
squad_resolve() {
  local out line key val
  unset TRACKER_MODE
  if ! out="$(bash "$SQUAD_HOOKS_DIR/path-resolve.sh" 2>/dev/null)"; then
    echo "squad: path-resolve.sh failed" >&2
    return 20
  fi
  while IFS= read -r line; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      VAULT_PATH|PROJECT_ROOT|DISPLAY_NAME|SQUAD_DIR|TRACKER_MODE)
        export "$key=$val" ;;
    esac
  done <<EOF2
$out
EOF2
  if [ -z "${TRACKER_MODE:-}" ]; then
    echo "squad: path-resolve.sh did not emit TRACKER_MODE" >&2
    return 20
  fi
  return 0
}

# squad_gh_write <argv...>: the ONLY place a mutating gh verb may run.
# Detached (or unresolved) mode: refuses, executes nothing, returns 20.
# Connected: runs `gh <argv>`; returns 0 on success, 20 on any gh failure
# (gh's own exit code is never passed through). gh stdout goes to stderr so
# stdout stays contract-only.
squad_gh_write() {
  if [ "${TRACKER_MODE:-}" != "connected" ]; then
    echo "squad: refused gh write in ${TRACKER_MODE:-unresolved} mode" >&2
    return 20
  fi
  if gh "$@" >&2; then
    return 0
  fi
  echo "squad: gh $1 failed" >&2
  return 20
}

# squad_record_local <handoff> <line>: append <line> to <handoff> unless an
# identical line is already present. Creates parent dirs.
# Returns 0 if appended (changed), 1 if already present (unchanged),
# 20 on I/O error.
squad_record_local() {
  local file="$1" line="$2"
  case "$line" in *'
'*) echo "squad: record line must be single-line" >&2; return 20 ;; esac
  mkdir -p "$(dirname "$file")" 2>/dev/null || { echo "squad: cannot create dir for $file" >&2; return 20; }
  if [ -f "$file" ] && grep -qxF -- "$line" "$file"; then
    return 1
  fi
  printf '%s\n' "$line" >> "$file" || { echo "squad: cannot write $file" >&2; return 20; }
  return 0
}

# squad_emit KEY value: print KEY=value on stdout. KEY must match
# ^[A-Z_]+$ ([[:upper:]] class: a-z range globs accept lowercase under UTF-8
# locales in bash 3.2), value must be single-line; backslash is escaped as \\.
# Returns 0, or 2 (with a stderr reason) on invalid input.
squad_emit() {
  local key="${1:-}" val="${2-}"
  case "$key" in
    ''|*[![:upper:]_]*) echo "squad: invalid output key '$key'" >&2; return 2 ;;
  esac
  case "$val" in *'
'*) echo "squad: multi-line value for $key" >&2; return 2 ;; esac
  case "$val" in *$'\r'*) echo "squad: CR in value for $key" >&2; return 2 ;; esac
  val="$(printf '%s' "$val" | sed 's/\\/\\\\/g')"
  printf '%s=%s\n' "$key" "$val"
}
