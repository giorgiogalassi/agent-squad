#!/usr/bin/env bash
# Tests for scripts/plugin-version-bump.sh. Plain bash 3.2.
set -u
SUT="${1:-$(cd "$(dirname "$0")" && pwd)/plugin-version-bump.sh}"
fail=0; n=0
check() { # name expected-stdout expected-exit version labels
  n=$((n + 1))
  out="$(bash "$SUT" --version "$4" --labels "$5" 2>/dev/null)"; rc=$?
  out="$(printf '%s\n' "$out" | tr '\n' ' ')"
  if [ "$rc" = "$3" ] && [ "$out" = "$2" ]; then echo "ok $n - $1"
  else echo "not ok $n - $1 (rc=$rc out='$out')"; fail=1; fi
}
check "breaking-change -> major"   "BUMP=major NEW_VERSION=2.0.0 CHANGED=yes OUTCOME=applied " 0 1.4.7 breaking-change
check "enhancement -> minor"       "BUMP=minor NEW_VERSION=1.5.0 CHANGED=yes OUTCOME=applied " 0 1.4.7 enhancement
check "bug -> patch"               "BUMP=patch NEW_VERSION=1.4.8 CHANGED=yes OUTCOME=applied " 0 1.4.7 bug
check "breaking wins over all"     "BUMP=major NEW_VERSION=2.0.0 CHANGED=yes OUTCOME=applied " 0 1.4.7 "bug,enhancement,breaking-change"
check "enhancement wins over bug"  "BUMP=minor NEW_VERSION=1.5.0 CHANGED=yes OUTCOME=applied " 0 1.4.7 "bug,enhancement"
check "documentation only: none"   "BUMP=none NEW_VERSION=1.4.7 CHANGED=no OUTCOME=unchanged " 0 1.4.7 documentation
check "no labels: none"            "BUMP=none NEW_VERSION=1.4.7 CHANGED=no OUTCOME=unchanged " 0 1.4.7 ""
check "docs plus bug -> patch"     "BUMP=patch NEW_VERSION=1.4.8 CHANGED=yes OUTCOME=applied " 0 1.4.7 "documentation,bug"
check "no substring match"         "BUMP=none NEW_VERSION=1.0.0 CHANGED=no OUTCOME=unchanged " 0 1.0.0 "bugfix,enhancements"
check "patch reaches double digits" "BUMP=patch NEW_VERSION=1.0.10 CHANGED=yes OUTCOME=applied " 0 1.0.9 bug
check "minor resets patch"         "BUMP=minor NEW_VERSION=0.3.0 CHANGED=yes OUTCOME=applied " 0 0.2.9 enhancement
check "malformed: two parts" " " 10 1.0 bug
check "malformed: four parts" " " 10 1.0.0.1 bug
check "malformed: prerelease" " " 10 1.0.0-rc1 bug
check "malformed: empty" " " 10 "" bug
n=$((n + 1))
bash "$SUT" --labels bug >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then echo "ok $n - missing --version: usage"; else echo "not ok $n - usage rc=$rc"; fail=1; fi
n=$((n + 1))
bash "$SUT" --version 1.0.0 --labels bug --bogus >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then echo "ok $n - unknown arg: usage"; else echo "not ok $n - unknown rc=$rc"; fail=1; fi
exit "$fail"
