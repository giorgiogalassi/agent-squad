#!/usr/bin/env bash
# Tests for scripts/plugin-version-guard.sh with fixture repos. Plain bash 3.2.
set -u
SUT="${1:-$(cd "$(dirname "$0")" && pwd)/plugin-version-guard.sh}"
fail=0; n=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
M=claude/.claude-plugin/plugin.json

setver() { # version (empty = no version key)
  mkdir -p claude/.claude-plugin
  if [ -n "$1" ]; then printf '{"name":"x","version":"%s"}\n' "$1" > "$M"
  else printf '{"name":"x"}\n' > "$M"; fi
}
mkrepo() { # dir initial-version
  mkdir -p "$1"
  ( cd "$1" && git init -q -b main && git config user.email t@t && git config user.name t \
    && setver "$2" && git add . && git commit -qm init )
}
run() { # dir args...
  local d="$1"; shift
  out="$(cd "$d" && bash "$SUT" "$@" 2>/dev/null)"; rc=$?
  out="$(printf '%s\n' "$out" | tr '\n' ' ')"
}
check() { # name expected-outcome expected-rc
  n=$((n + 1))
  case "$out" in *"OUTCOME=$2 "*) ok=1 ;; *) ok=0 ;; esac
  if [ "$ok" = 1 ] && [ "$rc" = "$3" ]; then echo "ok $n - $1"
  else echo "not ok $n - $1 (rc=$rc out='$out')"; fail=1; fi
}

# PR branched before a bump landed on main, never touches version -> pass
d="$tmp/a"; mkrepo "$d" 1.0.0
( cd "$d" && git checkout -q -b pr && echo hi > f && git add f && git commit -qm pr \
  && git checkout -q main && setver 1.1.0 && git commit -qam bump )
run "$d" --base main --head pr
check "PR branched before a bump, version untouched: pass" pass 0

# PR edits version -> fail
d="$tmp/b"; mkrepo "$d" 1.0.0
( cd "$d" && git checkout -q -b pr && setver 9.9.9 && git commit -qam hand )
run "$d" --base main --head pr
check "PR edits version: fail" fail 10

# chore/plugin-v head -> skip (even though it edits the version)
run "$d" --base main --head pr --head-branch chore/plugin-v9.9.9
check "bump branch: skip" skip 0

# base without version -> skip
d="$tmp/c"; mkrepo "$d" ""
( cd "$d" && git checkout -q -b pr && setver 1.0.0 && git commit -qam add )
run "$d" --base main --head pr
check "base without version: skip" skip 0

# manifest absent at merge-base -> skip
d="$tmp/e"; mkrepo "$d" 1.0.0
( cd "$d" && git rm -q "$M" && git commit -qm rm && git checkout -q -b pr \
  && setver 1.0.0 && git add . && git commit -qm add )
run "$d" --base main --head pr
check "manifest absent at merge-base: skip" skip 0

# usage error
run "$tmp/a"
n=$((n + 1))
if [ "$rc" = 2 ]; then echo "ok $n - missing --base: usage"; else echo "not ok $n - rc=$rc"; fail=1; fi
exit "$fail"
