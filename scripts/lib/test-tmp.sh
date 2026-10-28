#!/usr/bin/env bash
# test-tmp.sh -- safe scratch directory for scripts/test-*.sh. Source it; do
# not run it. Plain bash 3.2.
#
#   . "$(dirname "$0")/lib/test-tmp.sh"
#   test_tmp_init test-foo            # sets TMPROOT; trap removes it on EXIT
#   test_tmp_init test-foo TMP        # same, into $TMP
#
# Why: `TMPROOT="$(mktemp -d ...)"; TMPROOT="$(cd "$TMPROOT" && pwd -P)"` turns
# a failed mktemp into TMPROOT=$PWD (cd "" succeeds), and the EXIT trap then
# deletes the working directory. This helper validates the raw mktemp result
# (non-empty, an existing directory physically under the temp base) BEFORE any
# cd or trap, exits 2 with a stderr reason otherwise, and installs a trap that
# refuses to delete anything outside the temp base. Paths listed in $FIXROOTS
# (space-separated fixture roots) are cleaned under the same guard.

test_tmp_base() {
  local b="${TMPDIR:-/tmp}"
  (cd "$b" 2>/dev/null && pwd -P)
}

# test_tmp_safe <path>: success when <path> is absolute, an existing directory,
# and strictly inside the physical temp base.
test_tmp_safe() {
  local p="$1" base real
  case "$p" in /*) ;; *) return 1 ;; esac
  [ -d "$p" ] || return 1
  base="$(test_tmp_base)" || return 1
  [ -n "$base" ] || return 1
  real="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  case "$real" in
    "$base"/?*) return 0 ;;
    *) return 1 ;;
  esac
}

TEST_TMP_ROOTS=""

test_tmp_cleanup() {
  local p
  for p in $TEST_TMP_ROOTS ${FIXROOTS:-}; do
    if test_tmp_safe "$p"; then
      rm -rf "$p"
    elif [ -e "$p" ]; then
      echo "test-tmp: refusing to delete '$p' (not inside the temp base)" >&2
    fi
  done
}

test_tmp_init() {
  local prefix="${1:?test_tmp_init needs a name prefix}" var="${2:-TMPROOT}" base raw real
  base="${TMPDIR:-/tmp}"
  raw="$(mktemp -d "$base/$prefix.XXXXXX" 2>/dev/null)"
  if [ -z "$raw" ]; then
    echo "$prefix: mktemp -d failed or printed nothing; refusing to continue" >&2
    exit 2
  fi
  if ! test_tmp_safe "$raw"; then
    echo "$prefix: mktemp returned '$raw', not an existing directory under $base; refusing to continue" >&2
    exit 2
  fi
  real="$(cd "$raw" && pwd -P)"
  TEST_TMP_ROOTS="$TEST_TMP_ROOTS $real"
  trap test_tmp_cleanup EXIT
  printf -v "$var" '%s' "$real"
}
