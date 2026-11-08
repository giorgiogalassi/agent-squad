#!/usr/bin/env bash
# Tests the Jira Cloud tracker adapter (claude/hooks/tracker/jira.sh) through the
# facades, over recorded responses (scripts/fixtures/jira/) and the curl shim
# (scripts/curl-shim/curl): no network, no real Jira. Also proves that no `gh` is
# called on the Jira path, that the token appears on no argv, output, log or file,
# and that an adapter that does not load fails instead of falling back to labels.
# Plain bash 3.2; jq needed.
set -u
export SQUAD_INCIDENTS=off
unset SQUAD_VAULT_PATH SQUAD_PROJECT_ROOT SQUAD_DISPLAY_NAME SQUAD_DIR SQUAD_TRACKER_MODE SQUAD_TRACKER_PROVIDER SQUAD_VCS_PROVIDER SQUAD_JIRA_TOKEN
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
TRK="$REPO_ROOT/claude/hooks/squad-tracker.sh"
LAB="$REPO_ROOT/claude/hooks/squad-labels.sh"
FX="$REPO_ROOT/scripts/fixtures/jira"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-tracker-jira
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
command -v jq >/dev/null 2>&1 || { echo "skip - jq missing"; exit 0; }

TOKEN="TESTTOKEN-must-never-leak-7f3a"
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >> "$GHLOG"
exit 1
STUB
chmod +x "$BIN/gh"
export GHLOG="$TMPROOT/gh.log"; : > "$GHLOG"
export CURL_SHIM_FIXTURES="$FX" CURL_SHIM_LOG="$TMPROOT/curl.log" CURL_SHIM_ARGV="$TMPROOT/argv.log" CURL_SHIM_ROUTES="$TMPROOT/routes"
: > "$CURL_SHIM_LOG"; : > "$CURL_SHIM_ARGV"
ALL="$TMPROOT/all.out"; : > "$ALL"

setcfg() { local f="$1"; shift; jq "$@" "$f" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"; }
out="$(TMPDIR="$TMPROOT" "$MK" connected)" || exit 1
P="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"; V="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
CFG="$V/projects/fixture/.squad/chisel-config.json"
setcfg '.chisel.tracker = "jira" | .chisel.jira_site = "acme.atlassian.net" | .chisel.jira_email = "bot@example.com" | .chisel.jira_project = "ABC"
  | .chisel.jira_states = {"in-progress": "In Progress", "needs-review": "In Review", "done": "Done"}'
RC=0
# jr <cmd...>: run in the fixture project with the shims first on PATH; stdout in OUT, rc in RC.
jr() {
  OUT="$(cd "$P" && PATH="$REPO_ROOT/scripts/curl-shim:$BIN:$PATH" SECOND_BRAIN_PATH="$V" SQUAD_JIRA_TOKEN="${TOK-$TOKEN}" "$@" 2>"$TMPROOT/err")"; RC=$?
  { printf '%s\n' "$OUT"; cat "$TMPROOT/err"; } >> "$ALL"
}
routes() { cat > "$CURL_SHIM_ROUTES"; : > "$CURL_SHIM_LOG"; }
key() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
calls() { grep -c "^$1" "$CURL_SHIM_LOG"; }
callsx() { grep -cxF "$1" "$CURL_SHIM_LOG"; }
body_of() { grep -xF -A1 "$1" "$CURL_SHIM_LOG" | sed -n 's/^BODY //p' | head -n 1; }

# --- credentials and preflight
TOK="" routes <<R
GET /myself myself.json
R
TOK="" jr bash "$TRK" preflight
check "no token: exit 10" 10 "$RC"
check "no token: reason names the keychain item, makes no call" 0 "$(wc -l < "$CURL_SHIM_LOG" | tr -d ' ')"
grep -q "squad-jira" "$TMPROOT/err" && ok "no token: stderr says where to put it" || bad "no token: stderr says where to put it"

# keychain: a `security` stub on PATH supplies the token (macOS path)
mkdir -p "$TMPROOT/kc"
cat > "$TMPROOT/kc/security" <<STUB
#!/bin/sh
[ "\$1 \$2 \$3 \$4 \$5 \$6" = "find-generic-password -s squad-jira -a bot@example.com -w" ] && echo "$TOKEN" && exit 0
exit 44
STUB
chmod +x "$TMPROOT/kc/security"
routes <<R
GET /myself myself.json
GET /project/ABC project.json
R
OUT="$(cd "$P" && PATH="$REPO_ROOT/scripts/curl-shim:$TMPROOT/kc:$BIN:$PATH" SECOND_BRAIN_PATH="$V" bash "$TRK" preflight 2>"$TMPROOT/err")"; RC=$?
{ printf '%s\n' "$OUT"; cat "$TMPROOT/err"; } >> "$ALL"
check "keychain token: preflight exit 0" 0 "$RC"
check "keychain token: PROVIDER" jira "$(key "$OUT" PROVIDER)"

jr bash "$TRK" preflight
check "preflight: exit 0" 0 "$RC"
routes <<R
GET /myself - - 401
R
jr bash "$TRK" preflight
check "preflight: rejected token is 10" 10 "$RC"
grep -q "ERROR: jira rejected" "$TMPROOT/err" && ok "preflight: reason" || bad "preflight: reason"

# --- reads
routes <<R
GET /issue/ABC-12?fields=* issue-ABC-12.json
GET /issue/ABC-10?fields=* issue-ABC-10.json
R
jr bash "$TRK" get ABC-12
check "get: exit 0" 0 "$RC"
check "get: ID" ABC-12 "$(key "$OUT" ID)"
check "get: TITLE" "Wire the form" "$(key "$OUT" TITLE)"
check "get: STATE open" open "$(key "$OUT" STATE)"
check "get: PARENT" ABC-10 "$(key "$OUT" PARENT)"
check "get: BLOCKED_BY uses the configured link type only" "ABC-11,ABC-9" "$(key "$OUT" BLOCKED_BY)"
check "get: BLOCKING" ABC-13 "$(key "$OUT" BLOCKING)"
check "get: URL" "https://acme.atlassian.net/browse/ABC-12" "$(key "$OUT" URL)"
check "get: CONTAINER no" no "$(key "$OUT" CONTAINER)"
jr bash "$TRK" get ABC-10
check "get: a story with sub-tasks is a CONTAINER" yes "$(key "$OUT" CONTAINER)"
jr bash "$TRK" get "abc;rm"
check "get: a malformed key is a usage error" 2 "$RC"
check "get: ...and no call was made" 0 "$(calls "GET /issue/abc")"

routes <<R
GET /search/jql* search-children.json
R
jr bash "$TRK" batch ABC-10
check "batch: exit 0" 0 "$RC"
check "batch: dependency order, not creation order" "ABC-11 ABC-12 ABC-13" "$(printf '%s\n' "$OUT" | sed -n 's/^ID=//p' | tr '\n' ' ' | sed 's/ $//')"
check "batch: blocks separated by a blank line" 3 "$(printf '%s\n' "$OUT" | grep -c '^$')"
grep -q 'GET /search/jql?jql=parent%20%3D%20ABC-10' "$CURL_SHIM_LOG" && ok "batch: JQL is parent = KEY, open work only" || bad "batch: JQL is parent = KEY"
grep -q 'statusCategory%20%21%3D%20Done' "$CURL_SHIM_LOG" && ok "batch: done issues excluded in the query" || bad "batch: done issues excluded"
routes <<R
GET /search/jql*nextPageToken=tok2* search-page2.json
GET /search/jql* search-page1.json
R
jr bash "$TRK" batch ABC-10
check "batch: follows nextPageToken" "ABC-11 ABC-13" "$(printf '%s\n' "$OUT" | sed -n 's/^ID=//p' | tr '\n' ' ' | sed 's/ $//')"
routes <<R
GET /search/jql* search-cycle.json
R
jr bash "$TRK" batch ABC-10
check "batch: dependency cycle is 10" 10 "$RC"
check "batch: cycle emits no blocks" "" "$(key "$OUT" ID)"
jr bash "$TRK" batch latest
check "batch latest: not supported, 10" 10 "$RC"
routes <<R
GET /search/jql* search-empty.json
R
jr bash "$TRK" batch ABC-10
check "batch: empty container, exit 0, no output" "0:" "$RC:$OUT"

# --- writes: create / create-child
routes <<R
GET /issue/ABC-1?fields=issuetype issue-ABC-1-epic.json
POST /issue create-ABC-20.json 201
PUT /issue/ABC-20 - 204
POST /issueLink - 201
R
jr bash "$TRK" create-child ABC-1 --title "Add the endpoint" --body "$(printf '## Acceptance criteria\n- returns 200\n- logs the call\n\n## Test specs\nGiven x\nwhen y')" --blocked-by ABC-11 --label backend
check "create-child of an epic: exit 0" 0 "$RC"
check "create-child: ID" ABC-20 "$(key "$OUT" ID)"
check "create-child: URL" "https://acme.atlassian.net/browse/ABC-20" "$(key "$OUT" URL)"
B="$(body_of 'POST /issue')"
check "create: project" ABC "$(printf '%s' "$B" | jq -r .fields.project.key)"
check "create: child of an epic is a Task" Task "$(printf '%s' "$B" | jq -r .fields.issuetype.name)"
check "create: parent" ABC-1 "$(printf '%s' "$B" | jq -r .fields.parent.key)"
check "create: description is ADF" "doc:1" "$(printf '%s' "$B" | jq -r '.fields.description | "\(.type):\(.version)"')"
check "create: ADF heading and bullet list" "heading,bulletList,heading,paragraph" "$(printf '%s' "$B" | jq -r '[.fields.description.content[].type] | join(",")')"
check "create: ADF bullets" 2 "$(printf '%s' "$B" | jq '.fields.description.content[1].content | length')"
check "create: label passed through" '["backend"]' "$(printf '%s' "$B" | jq -c .fields.labels)"
check "create: squad ID label added after the create" '{"update":{"labels":[{"add":"squad-ABC-20"}]}}' "$(body_of 'PUT /issue/ABC-20')"
LB="$(body_of 'POST /issueLink')"
check "create: blocked-by link type" Blocks "$(printf '%s' "$LB" | jq -r .type.name)"
check "create: blocker is the inward issue" "ABC-11>ABC-20" "$(printf '%s' "$LB" | jq -r '"\(.inwardIssue.key)>\(.outwardIssue.key)"')"

routes <<R
GET /issue/ABC-10?fields=issuetype issue-ABC-10-type.json
POST /issue create-ABC-21.json 201
PUT /issue/ABC-21 - 204
R
setcfg '.chisel.jira_fields = {"customfield_10037": 0}' 
jr bash "$TRK" create-child ABC-10 --title "Sub" --body ""
B="$(body_of 'POST /issue')"
check "create-child of a story is a Sub-task" Sub-task "$(printf '%s' "$B" | jq -r .fields.issuetype.name)"
check "create: jira_fields merged in its wire shape" "0" "$(printf '%s' "$B" | jq -r .fields.customfield_10037)"
setcfg 'del(.chisel.jira_fields) | .chisel.jira_subtask_type = "Sottoattivita"'
: > "$CURL_SHIM_LOG"
jr bash "$TRK" create-child ABC-10 --title "Sub" --body "x"
check "create-child: sub-task type is configurable" Sottoattivita "$(body_of 'POST /issue' | jq -r .fields.issuetype.name)"
setcfg 'del(.chisel.jira_subtask_type)'
routes <<R
GET /issue/ABC-11?fields=issuetype issue-ABC-11-type.json
R
jr bash "$TRK" create-child ABC-11 --title "Sub of sub" --body "x"
check "create-child under a sub-task: 10" 10 "$RC"
check "create-child under a sub-task: nothing created" 0 "$(calls POST)"
routes <<R
POST /issue error-400.json 400
R
jr bash "$TRK" create --title "T" --body "x"
check "create: Jira 400 is 20" 20 "$RC"
grep -q "customfield_10037" "$TMPROOT/err" && ok "create: Jira's error text is reported" || bad "create: Jira's error text is reported"
check "create: failure prints no ID" "" "$(key "$OUT" ID)"
routes <<R
POST /issue create-ABC-20.json 201
PUT /issue/ABC-20 - 204
POST /issueLink error-400.json 400
R
jr bash "$TRK" create --title "T" --body "x" --blocked-by ABC-11
check "create: a failed link after the create is 20" 20 "$RC"
check "create: ...but the created ID is still reported" ABC-20 "$(key "$OUT" ID)"

# --- labels and comment
routes <<R
GET /myself myself.json
PUT /issue/ABC-11/assignee - 204
PUT /issue/ABC-11 - 204
R
jr bash "$TRK" label ABC-11 --assign-me --add "needs review" --remove old
check "label: exit 0" 0 "$RC"
check "label: assignee" '{"accountId":"acc-123"}' "$(body_of 'PUT /issue/ABC-11/assignee')"
check "label: add/remove, spaces become hyphens" '{"update":{"labels":[{"add":"needs-review"},{"remove":"old"}]}}' "$(body_of 'PUT /issue/ABC-11')"
routes <<R
GET /issue/ABC-11?fields=labels labels-ABC-11.json
GET /label* label-list.json
R
jr bash "$TRK" labels ABC-11
check "labels: one per line" "squad-ABC-11 needs-review" "$(printf '%s\n' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
jr bash "$TRK" label-list
check "label-list: values" "3" "$(printf '%s\n' "$OUT" | grep -c .)"

routes <<R
POST /issue/ABC-11/comment comment-ok.json 201
R
jr bash "$TRK" comment ABC-11 --body "hello"
check "comment: refused by the default jira policy" 20 "$RC"
check "comment: REASON=policy on stdout" "policy: comment not allowed on fixture" "$(key "$OUT" REASON)"
check "comment: no call reached Jira" 0 "$(wc -l < "$CURL_SHIM_LOG" | tr -d ' ')"
setcfg '.chisel.writes.tracker = ["create","create-child","set-state","claim","label","comment"]'
jr bash "$TRK" comment ABC-11 --body "hello"
check "comment: allowed when the project lists it" 0 "$RC"
check "comment: ADF body" "paragraph" "$(body_of 'POST /issue/ABC-11/comment' | jq -r '.body.content[0].type')"
setcfg 'del(.chisel.writes)'

# --- state transitions
routes <<R
GET /issue/ABC-11?fields=status status-todo.json
GET /issue/ABC-11/transitions transitions-todo.json
POST /issue/ABC-11/transitions - 204
GET /myself myself.json
PUT /issue/ABC-11/assignee - 204
R
jr bash "$TRK" claim ABC-11
check "claim: exit 0" 0 "$RC"
check "claim: OUTCOME" applied "$(key "$OUT" OUTCOME)"
check "claim: transition id resolved from the live list" '{"transition":{"id":"21"}}' "$(body_of 'POST /issue/ABC-11/transitions')"
check "claim: assigns the token's user" '{"accountId":"acc-123"}' "$(body_of 'PUT /issue/ABC-11/assignee')"
check "claim: TO_STATE" "In Progress" "$(key "$OUT" TO_STATE)"
jr bash "$LAB" claim --issue ABC-11
check "squad-labels claim reaches the jira hook" "0:applied" "$RC:$(key "$OUT" OUTCOME)"
check "squad-labels claim: made no label edit" 0 "$(callsx 'PUT /issue/ABC-11')"

routes <<R
GET /issue/ABC-11?fields=status status-inprogress.json
GET /issue/ABC-11/transitions transitions-inprogress.json
POST /issue/ABC-11/transitions - 204
R
jr bash "$TRK" set-state ABC-11 in-review
check "set-state in-review: falls back to the needs-review mapping" "0:In Review" "$RC:$(key "$OUT" TO_STATE)"
check "set-state in-review: transition 31" '{"transition":{"id":"31"}}' "$(body_of 'POST /issue/ABC-11/transitions')"
routes <<R
GET /issue/ABC-11?fields=status status-inprogress.json
GET /issue/ABC-11/transitions transitions-todo.json
GET /myself myself.json
PUT /issue/ABC-11/assignee - 204
R
jr bash "$TRK" claim ABC-11
check "claim: already in the target status is unchanged" "0:unchanged" "$RC:$(key "$OUT" OUTCOME)"
check "claim: ...and posts no transition" 0 "$(calls POST)"
routes <<R
GET /issue/ABC-11?fields=status status-todo.json
GET /issue/ABC-11/transitions transitions-inprogress.json
R
jr bash "$TRK" claim ABC-11
check "claim: no live transition to the status is 10" 10 "$RC"
check "claim: REASON names the missing transition" yes "$(key "$OUT" REASON | grep -q 'no transition from "To Do" to "In Progress"' && echo yes)"
check "claim: nothing guessed, no POST" 0 "$(calls POST)"
setcfg 'del(.chisel.jira_states["in-progress"])'
jr bash "$TRK" claim ABC-11
check "claim: unmapped state is 10" 10 "$RC"
check "claim: unmapped state reason" yes "$(key "$OUT" REASON | grep -q 'no jira_states mapping' && echo yes)"
setcfg '.chisel.jira_states["in-progress"] = "In Progress"'

# escalate: label + transition when mapped; comment skipped by policy
setcfg '.chisel.state_labels.blocked = "blocked" | .chisel.jira_states.blocked = "Done"'
routes <<R
GET /issue/ABC-11?fields=status status-todo.json
GET /issue/ABC-11/transitions transitions-inprogress.json
POST /issue/ABC-11/transitions - 204
PUT /issue/ABC-11 - 204
R
jr bash "$LAB" escalate --issue ABC-11 --reason "boom"
check "escalate: exit 0" 0 "$RC"
check "escalate: COMMENT=skipped by the jira default policy" skipped "$(key "$OUT" COMMENT)"
check "escalate: blocked label added" '{"update":{"labels":[{"add":"blocked"}]}}' "$(body_of 'PUT /issue/ABC-11')"
check "escalate: transitioned to the mapped status" '{"transition":{"id":"41"}}' "$(body_of 'POST /issue/ABC-11/transitions')"
check "escalate: no comment call" 0 "$(calls 'POST /issue/ABC-11/comment')"
setcfg 'del(.chisel.jira_states.blocked)'
routes <<R
PUT /issue/ABC-11 - 204
R
jr bash "$LAB" escalate --issue ABC-11 --reason "boom"
check "escalate: unmapped blocked still labels, reports the skipped transition" "0:skipped" "$RC:$(key "$OUT" TRANSITION)"
setcfg '.chisel.review_label = "needs-review"'
: > "$CURL_SHIM_LOG"
jr bash "$LAB" needs-review --issue ABC-11
check "needs-review: adds the review label" '{"update":{"labels":[{"add":"needs-review"}]}}' "$(body_of 'PUT /issue/ABC-11')"

# --- detached: writes are refused, nothing reaches Jira
setcfg '.chisel.mode = "detached"'
routes <<R
POST /issue create-ABC-20.json 201
R
jr bash "$TRK" create --title "T" --body "x"
check "detached: create refused" 20 "$RC"
check "detached: no HTTP call" 0 "$(wc -l < "$CURL_SHIM_LOG" | tr -d ' ')"
setcfg '.chisel.mode = "connected"'

# --- an adapter that does not load is a failure, not a label fallback
setcfg '.chisel.tracker = "nosuch"'
jr bash "$TRK" claim ABC-11
check "unloadable adapter: squad-tracker claim fails 20" 20 "$RC"
jr bash "$TRK" set-state ABC-11 in-review
check "unloadable adapter: squad-tracker set-state fails 20" 20 "$RC"
jr bash "$LAB" claim --issue ABC-11
check "unloadable adapter: squad-labels claim fails 20" 20 "$RC"
setcfg '.chisel.tracker = "jira"'

# --- the whole run: no gh, no token anywhere
check "no gh call anywhere on the Jira path" 0 "$(wc -l < "$GHLOG" | tr -d ' ')"
check "no REJECTED curl call (every request had a route)" 0 "$(grep -c '^REJECTED' "$CURL_SHIM_LOG")"
if grep -rqF -- "$TOKEN" "$ALL" "$CURL_SHIM_ARGV" "$CURL_SHIM_LOG"; then bad "the token appears in an output, log or argv"; else ok "the token appears in no output, log or argv"; fi
if grep -rqF -- "$TOKEN" "$V" "$P" "$FX" "$REPO_ROOT/scripts/curl-shim" 2>/dev/null; then bad "the token is in a file"; else ok "the token is in no config, vault, project or fixture file"; fi
if grep -nE '(^|[^a-zA-Z_./-])gh +(issue|pr|api|repo|label|project|auth)' "$REPO_ROOT/claude/hooks/tracker/jira.sh" | grep -v '^[0-9]*:#' | grep -q .; then bad "jira.sh mentions a gh command"; else ok "jira.sh has no gh command"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
