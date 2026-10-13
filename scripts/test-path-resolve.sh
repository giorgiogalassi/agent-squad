#!/usr/bin/env bash
# Tests TRACKER_MODE resolution in claude/hooks/path-resolve.sh.
# Plain bash + git + coreutils; no bats. Fixtures live under one mktemp root.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PR="$REPO_ROOT/claude/hooks/path-resolve.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-path-resolve.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

PROJ="$TMPROOT/proj"
git init -q "$PROJ"
VAULT="$TMPROOT/vault"
CFG="$VAULT/projects/proj/.squad/chisel-config.json"
mkdir -p "$(dirname "$CFG")"

# Shim dir with every tool the script needs except jq.
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
for t in git dirname basename wc tr grep cat; do
  p="$(command -v "$t")" && ln -s "$p" "$SHIM/$t"
done

# run <path-for-PATH-or-empty>; sets OUT, ERR
run() {
  if [ -n "$1" ]; then
    OUT="$(cd "$PROJ" && SECOND_BRAIN_PATH="$VAULT" PATH="$1" "$BASH" "$PR" 2>"$TMPROOT/err")"
  else
    OUT="$(cd "$PROJ" && SECOND_BRAIN_PATH="$VAULT" "$BASH" "$PR" 2>"$TMPROOT/err")"
  fi
  ERR="$(cat "$TMPROOT/err")"
}

# check <name> <expected mode> <expected stderr line count> [PATH override]
check() {
  run "${4:-}"
  local mode lines errn
  mode="$(printf '%s\n' "$OUT" | sed -n 's/^TRACKER_MODE=//p')"
  lines="$(printf '%s\n' "$OUT" | grep -c '^[A-Z_]*=')"
  errn="$(printf '%s' "$ERR" | grep -c .)"
  if [ "$mode" = "$2" ] && [ "$lines" = "5" ] && [ "$errn" = "$3" ]; then
    ok "$1"
  else
    bad "$1 (mode=$mode lines=$lines stderr_lines=$errn)"
  fi
}

rm -f "$CFG"
check "missing file -> detached + 1 stderr line" detached 1

echo '{"chisel":{"repo":"x/y"}}' > "$CFG"
check "missing key -> detached + 1 stderr line" detached 1

echo '{"chisel":{"mode":"conected"}}' > "$CFG"
check "typo value -> detached + 1 stderr line" detached 1

echo '{"chisel":{"mode":"connected"}}' > "$CFG"
check "jq absent -> detached + 1 stderr line" detached 1 "$SHIM"

echo '{"chisel":{"mode":"detached"}}' > "$CFG"
check "explicit detached -> detached, silent" detached 0

if command -v jq >/dev/null 2>&1; then
  echo '{"chisel":{"mode":"connected"}}' > "$CFG"
  check "connected -> connected, silent" connected 0
else
  bad "connected case needs jq on PATH"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
