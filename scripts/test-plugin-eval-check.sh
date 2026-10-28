#!/usr/bin/env bash
# Tests for scripts/plugin-eval-check.sh with fixture results.json. Plain bash 3.2 + jq.
set -u
SUT="${1:-$(cd "$(dirname "$0")" && pwd)/plugin-eval-check.sh}"
fail=0; n=0
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-plugin-eval-check tmp

run() { # file
  out="$(bash "$SUT" "$@" 2>/dev/null)"; rc=$?
  out="$(printf '%s\n' "$out" | tr '\n' ' ')"
}
check() { # name expected-outcome expected-rc
  n=$((n + 1))
  case "$out" in *"OUTCOME=$2 "*) ok=1 ;; *) ok=0 ;; esac
  if [ "$3" = 20 ] || [ "$3" = 2 ]; then ok=1; fi
  if [ "$ok" = 1 ] && [ "$rc" = "$3" ]; then echo "ok $n - $1"
  else echo "not ok $n - $1 (rc=$rc out='$out')"; fail=1; fi
}

SANDBOX_ERR='Sandbox required but unavailable: bubblewrap (bwrap) not installed'
cat > "$tmp/good.json" <<'J'
{"costUsd":0.5,"cases":[{"name":"a","arms":{"with":[{"score":1,"error":null,"costUsd":0.1},{"score":0.5,"error":null,"costUsd":0.1}]}},{"name":"b","arms":{"with":[{"score":1,"error":null,"costUsd":0.1}]}}]}
J
cat > "$tmp/allerr.json" <<J
{"costUsd":0,"cases":[{"name":"a","arms":{"with":[{"score":null,"error":"$SANDBOX_ERR","costUsd":0}]}},{"name":"b","arms":{"with":[{"score":0,"error":"$SANDBOX_ERR","costUsd":0},{"score":0,"error":"$SANDBOX_ERR","costUsd":0}]}}]}
J
cat > "$tmp/cost0.json" <<'J'
{"costUsd":0,"cases":[{"name":"a","arms":{"with":[{"score":1,"error":null,"costUsd":0}]}}]}
J
cat > "$tmp/partial.json" <<J
{"costUsd":0.2,"cases":[{"name":"a","arms":{"with":[{"score":null,"error":"$SANDBOX_ERR","costUsd":0}]}},{"name":"b","arms":{"with":[{"score":0,"error":null,"costUsd":0.2}]}}]}
J
echo '{"costUsd":0.3,"cases":[]}' > "$tmp/nocases.json"
echo 'not json' > "$tmp/bad.json"

run "$tmp/good.json";    check "scored runs with cost: pass" pass 0
run "$tmp/allerr.json";  check "every case errored: fail" fail 10
run "$tmp/cost0.json";   check "costUsd 0: fail" fail 10
run "$tmp/partial.json"; check "one scored run among errors: pass" pass 0
run "$tmp/nocases.json"; check "no cases at all: fail" fail 10
run "$tmp/bad.json";     check "invalid JSON: exit 20" x 20
run "$tmp/missing.json"; check "missing file: exit 20" x 20
run;                     check "no argument: exit 2" x 2

exit "$fail"
