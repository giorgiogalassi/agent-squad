#!/usr/bin/env bash
# Tests the chisel.ralph.review_rounds key in claude/hooks/chisel-config-validate.py:
# the schema is parsed from claude/skills/chisel/SKILL.md, then configs are checked.
# Usage: scripts/test-chisel-config-validate.sh   (bash 3.2, needs python3)
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

py() {
  python3 -I - "$REPO_ROOT" "$1" <<'PY'
import importlib.util, json, sys
from pathlib import Path
root, cfg = Path(sys.argv[1]), json.loads(sys.argv[2])
spec = importlib.util.spec_from_file_location("v", root / "claude/hooks/chisel-config-validate.py")
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
schema = v.parse_schema(root / "claude/skills/chisel/SKILL.md")
violations, _ = v.validate_config(cfg, schema)
print("\n".join(x["message"] for x in violations) or "CLEAN")
PY
}

check() { # name config expected-substring-or-CLEAN
  local out; out="$(py "$2")"
  case "$out" in
    *"$3"*) PASS=$((PASS+1)); echo "ok   $1" ;;
    *) FAIL=$((FAIL+1)); echo "FAIL $1: got '$out', wanted '$3'" ;;
  esac
}

check "connected with ralph.review_rounds 2 is clean" \
  '{"chisel":{"mode":"connected","review_label":"needs-review","state_labels":{"in_progress":"a","in_review":"b","blocked":"c"},"ralph":{"review_rounds":2}}}' CLEAN
check "detached with ralph.review_rounds 0 is clean" \
  '{"chisel":{"mode":"detached","issue_prefix":"SQ","ralph":{"review_rounds":0}}}' CLEAN
check "config without ralph is clean" \
  '{"chisel":{"mode":"detached","issue_prefix":"SQ"}}' CLEAN
check "review_rounds string rejected" \
  '{"chisel":{"mode":"detached","ralph":{"review_rounds":"2"}}}' "chisel.ralph.review_rounds: expected an integer"
check "review_rounds negative rejected" \
  '{"chisel":{"mode":"detached","ralph":{"review_rounds":-1}}}' "chisel.ralph.review_rounds: expected an integer"
check "review_rounds bool rejected" \
  '{"chisel":{"mode":"detached","ralph":{"review_rounds":true}}}' "chisel.ralph.review_rounds: expected an integer"
check "unknown ralph key rejected" \
  '{"chisel":{"mode":"detached","ralph":{"rounds":2}}}' "chisel.ralph.rounds: unknown key"
check "ralph not an object rejected" \
  '{"chisel":{"mode":"detached","ralph":3}}' "chisel.ralph: expected an object"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
