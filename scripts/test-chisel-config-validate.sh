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

C='"mode":"connected","review_label":"needs-review","state_labels":{"in_progress":"a","in_review":"b","blocked":"c"}'
check "writes with known verbs is clean" \
  "{\"chisel\":{$C,\"writes\":{\"tracker\":[\"create\",\"comment\"],\"vcs\":[\"pr-create\",\"stack-init\"]}}}" CLEAN
check "writes empty list is clean" \
  "{\"chisel\":{$C,\"writes\":{\"tracker\":[]}}}" CLEAN
check "writes unknown tracker verb rejected" \
  "{\"chisel\":{$C,\"writes\":{\"tracker\":[\"delete\"]}}}" "chisel.writes.tracker: unknown verb 'delete'"
check "writes vcs verb under tracker rejected" \
  "{\"chisel\":{$C,\"writes\":{\"tracker\":[\"description-set\"]}}}" "unknown verb 'description-set'"
check "writes unknown facade key rejected" \
  "{\"chisel\":{$C,\"writes\":{\"forge\":[]}}}" "chisel.writes.forge: unknown key"
check "writes list of non-strings rejected" \
  "{\"chisel\":{$C,\"writes\":{\"vcs\":\"comment\"}}}" "expected a list of verb names"
check "writes not an object rejected" \
  "{\"chisel\":{$C,\"writes\":[]}}" "chisel.writes: expected an object"

J='"jira_site":"acme.atlassian.net","jira_email":"me@example.com","jira_project":"ABC"'
check "jira keys with states are clean" \
  "{\"chisel\":{$C,\"tracker\":\"jira\",$J,\"jira_states\":{\"in-progress\":\"In Progress\",\"done\":\"Done\"},\"jira_link_type\":\"Blocks\",\"jira_fields\":{\"customfield_1\":0}}}" CLEAN
check "jira_site must be a string" \
  "{\"chisel\":{$C,\"jira_site\":3}}" "chisel.jira_site: expected a non-empty string"
check "jira_states unknown squad state rejected" \
  "{\"chisel\":{$C,\"jira_states\":{\"wip\":\"x\"}}}" "chisel.jira_states.wip: unknown key"
check "jira_states value must be a status name" \
  "{\"chisel\":{$C,\"jira_states\":{\"done\":7}}}" "chisel.jira_states.done: expected a Jira status name"
check "jira_fields must be an object" \
  "{\"chisel\":{$C,\"jira_fields\":[]}}" "chisel.jira_fields: expected an object"

check "bitbucket keys are clean" \
  "{\"chisel\":{$C,\"vcs\":\"bitbucket\",\"bitbucket_workspace\":\"acme\",\"bitbucket_repo\":\"app\",\"bitbucket_user\":\"bob\"}}" CLEAN
check "bitbucket_workspace must be a string" \
  "{\"chisel\":{$C,\"bitbucket_workspace\":3}}" "chisel.bitbucket_workspace: expected a non-empty string"
check "bitbucket_repo must not be empty" \
  "{\"chisel\":{$C,\"bitbucket_repo\":\" \"}}" "chisel.bitbucket_repo: expected a non-empty string"
check "mode list rejected" '{"chisel":{"mode":[]}}' "mode: invalid value"
check "mode object rejected" '{"chisel":{"mode":{}}}' "mode: invalid value"
check "mode number rejected" '{"chisel":{"mode":3}}' "mode: invalid value"
check "top-level array rejected" '[]' "config is not an object"
check "top-level string rejected" '"x"' "config is not an object"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
