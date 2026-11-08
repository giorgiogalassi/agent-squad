#!/usr/bin/env bash
# tracker/jira.sh -- Jira Cloud adapter (REST v3) for squad-tracker.sh.
# SOURCED by squad_tracker (squad-common.sh); do not execute. Bash 3.2, needs
# jq and curl. This file never calls the GitHub CLI; the only vendor call is
# `curl` (the test seam is scripts/curl-shim/).
#
# Config, all under `chisel` in chisel-config.json (non-secret):
#   jira_site        host, e.g. "acme.atlassian.net"             (required)
#   jira_email       account email of the API token              (required)
#   jira_project     project key, e.g. "ABC"                     (required)
#   jira_states      squad state -> Jira status name, e.g.
#                    {"in-progress":"In Progress","needs-review":"In Review",
#                     "done":"Done","blocked":"Blocked"}
#   jira_link_type   issue link type name for dependencies, default "Blocks"
#   jira_issue_type  type of a container / child of an epic, default "Task"
#   jira_subtask_type type of a child of a standard issue, default "Sub-task"
#   jira_fields      object merged verbatim into `fields` on create (instance
#                    required custom fields, in the wire shape Jira wants)
# Token: never in a file. Read per call from the macOS keychain
# (`security find-generic-password -s squad-jira -a <jira_email> -w`), else the
# environment variable SQUAD_JIRA_TOKEN. It is passed to curl through a config
# file descriptor (not argv, so not visible in `ps`) and is never printed.
#
# Verbs: batch, get, create, create-child, link-blocking, set-state (the
# tracker_set_state hook), labels, label-list, label-create, label, comment,
# preflight, repo. Return codes: 0 ok, 2 usage, 10 precondition not met, 20
# failure. Writes are refused outside connected mode by squad_write_guard
# (inside _jr_call) and by the write policy in the facade.

# --- config and credentials -------------------------------------------------

# _jr_ready: load config and token once per process into JR_SITE/JR_EMAIL/
# JR_PROJECT/JR_AUTH (the base64 credential, a plain shell variable that is
# never exported or printed).
_jr_ready() {
  [ -n "${JR_AUTH:-}" ] && return 0
  local cfg="${STATE_DIR:-}/chisel-config.json" tok
  command -v jq >/dev/null 2>&1 || { echo "squad: jira needs jq" >&2; return 10; }
  command -v curl >/dev/null 2>&1 || { echo "squad: jira needs curl" >&2; return 10; }
  [ -n "${STATE_DIR:-}" ] && [ -f "$cfg" ] || { echo "squad: jira: chisel-config.json not found" >&2; return 10; }
  JR_SITE="$(jq -r '.chisel.jira_site // empty' "$cfg" 2>/dev/null)"
  JR_SITE="${JR_SITE#https://}"; JR_SITE="${JR_SITE%/}"
  JR_EMAIL="$(jq -r '.chisel.jira_email // empty' "$cfg" 2>/dev/null)"
  JR_PROJECT="$(jq -r '.chisel.jira_project // empty' "$cfg" 2>/dev/null)"
  [ -n "$JR_SITE" ] && [ -n "$JR_EMAIL" ] && [ -n "$JR_PROJECT" ] \
    || { echo "squad: jira: chisel.jira_site, jira_email and jira_project must be set in chisel-config.json" >&2; return 10; }
  case "$JR_SITE" in *[!A-Za-z0-9.-]*) echo "squad: jira: chisel.jira_site is not a plain host name" >&2; return 10 ;; esac
  tok="${SQUAD_JIRA_TOKEN:-}"
  if [ -z "$tok" ] && command -v security >/dev/null 2>&1; then
    tok="$(security find-generic-password -s squad-jira -a "$JR_EMAIL" -w 2>/dev/null)"
  fi
  [ -n "$tok" ] || { echo "squad: jira: no API token (keychain item 'squad-jira' for $JR_EMAIL, or env SQUAD_JIRA_TOKEN)" >&2; return 10; }
  JR_AUTH="$(printf '%s:%s' "$JR_EMAIL" "$tok" | base64 | tr -d '\n')"
  tok=""
  return 0
}

# _jr_cfg <jq filter>: a value from chisel-config.json, empty when absent.
_jr_cfg() { jq -r "$1 // empty" "$STATE_DIR/chisel-config.json" 2>/dev/null; }

# _jr_key <string>: 0 when it looks like an issue key (ABC-123).
_jr_key() { printf '%s' "$1" | grep -Eq '^[A-Z][A-Z0-9_]*-[0-9]+$'; }

# --- HTTP ---------------------------------------------------------------------

# _jr_call <GET|POST|PUT> <path> [json body]: sets JR_BODY (response body) and
# JR_CODE (HTTP status). 0 on 2xx, 10 on 404, 20 otherwise (stderr says why; a
# message from Jira never contains the token). Non-GET calls pass the
# detached-mode guard first.
_jr_call() {
  local m="$1" p="$2" body="${3:-}" tmp rc=0
  _jr_ready || return $?
  [ "$m" = GET ] || squad_write_guard || return 20
  tmp="$(mktemp "${TMPDIR:-/tmp}/squad-jira.XXXXXX")" || { echo "squad: jira: mktemp failed" >&2; return 20; }
  if [ -n "$body" ]; then
    JR_CODE="$(printf '%s' "$body" | curl -sS -o "$tmp" -w '%{http_code}' -X "$m" \
      -K <(printf 'header = "Authorization: Basic %s"\n' "$JR_AUTH") \
      -H 'Accept: application/json' -H 'Content-Type: application/json' \
      --data-binary @- "https://$JR_SITE/rest/api/3$p")" || rc=$?
  else
    JR_CODE="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$m" \
      -K <(printf 'header = "Authorization: Basic %s"\n' "$JR_AUTH") \
      -H 'Accept: application/json' "https://$JR_SITE/rest/api/3$p")" || rc=$?
  fi
  JR_BODY="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then echo "squad: jira $m ${p%%\?*} failed (curl exit $rc)" >&2; return 20; fi
  case "$JR_CODE" in
    2??) return 0 ;;
    404) echo "squad: jira $m ${p%%\?*}: not found (HTTP 404)" >&2; return 10 ;;
    *) echo "squad: jira $m ${p%%\?*} failed (HTTP $JR_CODE): $(_jr_errors)" >&2; return 20 ;;
  esac
}

# _jr_errors: the error text of the last response, one line, "" when none.
_jr_errors() {
  printf '%s' "$JR_BODY" | jq -r '[(.errorMessages[]? // empty), ((.errors // {}) | to_entries[] | "\(.key): \(.value)")] | join("; ")' 2>/dev/null | tr '\n' ' '
}

# _jr_uri <string>: percent-encode.
_jr_uri() { jq -rn --arg s "$1" '$s | @uri'; }

# _jr_adf: plain text on stdin -> an Atlassian document (JSON). `## h` lines are
# headings, `- x` lines bullet items, blank lines separate paragraphs.
_jr_adf() {
  jq -Rs '
    def flush: if .o then .b += [.o] | .o = null else . end;
    def txt($t): {type: "text", text: $t};
    split("\n")
    | map(if test("^\\s*$") then {k: "sep"}
          elif test("^#{1,6} +\\S") then {k: "h", l: (capture("^(?<h>#+)").h | length), t: sub("^#+ +"; "")}
          elif test("^\\s*[-*] +\\S") then {k: "li", t: sub("^\\s*[-*] +"; "")}
          else {k: "p", t: .} end)
    | reduce .[] as $x ({b: [], o: null};
        if $x.k == "sep" then flush
        elif $x.k == "h" then flush | .b += [{type: "heading", attrs: {level: $x.l}, content: [txt($x.t)]}]
        elif $x.k == "li" then
          (if .o.type == "bulletList" then . else flush | .o = {type: "bulletList", content: []} end)
          | .o.content += [{type: "listItem", content: [{type: "paragraph", content: [txt($x.t)]}]}]
        else
          (if .o.type == "paragraph" then .o.content += [{type: "hardBreak"}, txt($x.t)]
           else flush | .o = {type: "paragraph", content: [txt($x.t)]} end)
        end)
    | flush | {type: "doc", version: 1, content: .b}'
}

# --- reads --------------------------------------------------------------------

_JR_FIELDS="summary,status,parent,issuelinks,labels,issuetype,subtasks"

tracker_repo() { _jr_ready || return $?; echo "REPO=$JR_SITE/$JR_PROJECT"; }

# preflight [ignored provider-neutral flags]: token valid for the exact
# endpoints used (myself, the project). 10 + reason on stderr otherwise.
tracker_preflight() {
  _jr_ready || return 10
  _jr_call GET /myself
  case $? in 0) ;; *) echo "ERROR: jira rejected the credentials for $JR_EMAIL on $JR_SITE (HTTP ${JR_CODE:-?}); check the token" >&2; return 10 ;; esac
  _jr_call GET "/project/$JR_PROJECT"
  case $? in 0) ;; *) echo "ERROR: jira project $JR_PROJECT is not reachable with this token (HTTP ${JR_CODE:-?})" >&2; return 10 ;; esac
  echo "PROVIDER=jira"; echo "VERSION=cloud-rest-v3"
}

# _jr_block <issue json>: the contract block of one issue.
_jr_block() {
  printf '%s' "$1" | jq -r --arg site "$JR_SITE" --arg lt "$(_jr_link_type)" '
    "ID=\(.key)",
    "TITLE=\(.fields.summary | gsub("[\r\n]"; " "))",
    "STATE=\(if .fields.status.statusCategory.key == "done" then "closed" else "open" end)",
    "STATUS=\(.fields.status.name)",
    "URL=https://\($site)/browse/\(.key)",
    "PARENT=\(.fields.parent.key // "")",
    "BLOCKED_BY=\([.fields.issuelinks[]? | select(.type.name == $lt) | .inwardIssue.key // empty] | join(","))",
    "BLOCKING=\([.fields.issuelinks[]? | select(.type.name == $lt) | .outwardIssue.key // empty] | join(","))",
    "LABELS=\([.fields.labels[]?] | join(","))",
    "CONTAINER=\(if ((.fields.subtasks // []) | length) > 0 or ((.fields.issuetype.hierarchyLevel // 0) >= 1) then "yes" else "no" end)"'
}

_jr_link_type() { local t; t="$(_jr_cfg .chisel.jira_link_type)"; echo "${t:-Blocks}"; }

# get <id>: one issue.
tracker_get() {
  local rc
  [ -n "${1:-}" ] || { echo "squad: get requires an id" >&2; return 2; }
  _jr_key "$1" || { echo "squad: '$1' is not a Jira issue key" >&2; return 2; }
  _jr_call GET "/issue/$1?fields=$_JR_FIELDS"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _jr_block "$JR_BODY"
}

# batch <container>: the open children of a parent issue or epic, in dependency
# order (a blocker before what it blocks; ties keep creation order). A
# dependency cycle is reported (10) and nothing is emitted. `latest` is not
# supported: name the container.
tracker_batch() {
  local c="${1:-}" all="[]" tok="" page n=0 q rc ordered i cnt
  [ -n "$c" ] || { echo "squad: batch requires a container id" >&2; return 2; }
  [ "$c" != latest ] || { echo "squad: jira has no 'latest' container; give an explicit key" >&2; return 10; }
  _jr_key "$c" || { echo "squad: '$c' is not a Jira issue key" >&2; return 2; }
  q="$(_jr_uri "parent = $c AND statusCategory != Done ORDER BY created ASC")"
  while :; do
    _jr_call GET "/search/jql?jql=$q&fields=$_JR_FIELDS&maxResults=100${tok:+&nextPageToken=$tok}"; rc=$?
    [ "$rc" -eq 0 ] || return 20
    all="$(jq -n --argjson a "$all" --argjson p "$JR_BODY" '$a + ($p.issues // [])')" || return 20
    tok="$(printf '%s' "$JR_BODY" | jq -r 'if (.isLast // true) then empty else (.nextPageToken // empty) end')"
    n=$((n + 1))
    [ -n "$tok" ] || break
    if [ "$n" -ge 20 ]; then echo "TRUNCATED=yes"; break; fi
  done
  ordered="$(printf '%s' "$all" | jq -c --arg lt "$(_jr_link_type)" '
    . as $all | map(.key) as $keys
    | def deps: [.fields.issuelinks[]? | select(.type.name == $lt) | .inwardIssue.key // empty | select(. as $k | $keys | index($k))];
      {out: [], rest: $all, stuck: false}
    | until(.stuck or (.rest | length) == 0;
        (.out | map(.key)) as $done
        | ([.rest[] | select((deps - $done) | length == 0)]) as $ready
        | if ($ready | length) == 0 then .stuck = true
          else .out += [$ready[0]] | .rest |= map(select(.key != $ready[0].key)) end)')" || return 20
  if [ "$(printf '%s' "$ordered" | jq -r .stuck)" = true ]; then
    echo "REASON=dependency cycle among $(printf '%s' "$ordered" | jq -r '[.rest[].key] | join(",")')"
    echo "squad: jira batch of $c has a dependency cycle" >&2
    return 10
  fi
  cnt="$(printf '%s' "$ordered" | jq '.out | length')"
  i=0
  while [ "$i" -lt "$cnt" ]; do
    echo ""
    _jr_block "$(printf '%s' "$ordered" | jq -c ".out[$i]")"
    i=$((i + 1))
  done
  return 0
}

tracker_labels() {
  local rc
  [ -n "${1:-}" ] || { echo "squad: labels requires an id" >&2; return 2; }
  _jr_key "$1" || { echo "squad: '$1' is not a Jira issue key" >&2; return 2; }
  _jr_call GET "/issue/$1?fields=labels"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$JR_BODY" | jq -r '.fields.labels[]?'
  return 0
}

tracker_label_list() {
  local rc
  _jr_call GET "/label?maxResults=1000"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$JR_BODY" | jq -r '.values[]?'
  return 0
}

# label-create <name>: Jira creates a label the first time it is used; nothing to do.
tracker_label_create() {
  [ -n "${1:-}" ] || { echo "squad: label-create requires a name" >&2; return 2; }
  squad_write_guard || return 20
  echo "squad: jira labels exist once used; nothing to create for '$1'" >&2
  return 0
}

# --- writes -------------------------------------------------------------------

# _jr_me: accountId of the token's user into JR_ME.
_jr_me() {
  local rc
  _jr_call GET /myself; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  JR_ME="$(printf '%s' "$JR_BODY" | jq -r '.accountId // empty')"
  [ -n "$JR_ME" ] || { echo "squad: jira: /myself returned no accountId" >&2; return 20; }
}

# _jr_label_name <label>: Jira labels cannot contain spaces.
_jr_label_name() { printf '%s' "$1" | tr ' ' '-'; }

# _jr_labels_edit <id> <add|remove> <label>...: one PUT.
_jr_labels_edit() {
  local id="$1" ops="[]" op="$2" l; shift 2
  for l in "$@"; do
    ops="$(jq -nc --argjson o "$ops" --arg l "$(_jr_label_name "$l")" --arg op "$op" '$o + [{($op): $l}]')"
  done
  _jr_call PUT "/issue/$id" "$(jq -nc --argjson o "$ops" '{update: {labels: $o}}')"
}

# label <id> [--assign-me] [--add L]... [--remove L]...
tracker_label() {
  local id="${1:-}" assign=0 ops="[]" l rc
  [ -n "$id" ] || { echo "squad: label requires an id" >&2; return 2; }
  _jr_key "$id" || { echo "squad: '$id' is not a Jira issue key" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --assign-me) assign=1; shift ;;
      --add|--remove)
        [ -n "${2:-}" ] || { echo "squad: label: $1 requires a value" >&2; return 2; }
        ops="$(jq -nc --argjson o "$ops" --arg l "$(_jr_label_name "$2")" --arg op "${1#--}" '$o + [{($op): $l}]')"
        shift 2 ;;
      *) echo "squad: label: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  [ "$assign" = 1 ] || [ "$ops" != "[]" ] || { echo "squad: label: nothing to change" >&2; return 2; }
  if [ "$assign" = 1 ]; then
    _jr_me || return $?
    _jr_call PUT "/issue/$id/assignee" "$(jq -nc --arg a "$JR_ME" '{accountId: $a}')"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  fi
  if [ "$ops" != "[]" ]; then
    _jr_call PUT "/issue/$id" "$(jq -nc --argjson o "$ops" '{update: {labels: $o}}')"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  fi
  return 0
}

# comment <id> --body <text>: ADF comment.
tracker_comment() {
  local id="${1:-}"
  [ -n "$id" ] && [ "${2:-}" = --body ] || { echo "squad: usage: comment <id> --body <text>" >&2; return 2; }
  _jr_key "$id" || { echo "squad: '$id' is not a Jira issue key" >&2; return 2; }
  _jr_call POST "/issue/$id/comment" "$(printf '%s' "${3:-}" | _jr_adf | jq -c '{body: .}')"
}

# link-blocking <blocker> <dependent>: an issue link of the configured type; the
# blocker is the inward issue (the dependent then reads "is blocked by <blocker>").
tracker_link_blocking() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "squad: usage: link-blocking <blocker> <dependent>" >&2; return 2; }
  _jr_key "$1" && _jr_key "$2" || { echo "squad: link-blocking needs Jira issue keys" >&2; return 2; }
  _jr_call POST /issueLink "$(jq -nc --arg t "$(_jr_link_type)" --arg b "$1" --arg d "$2" \
    '{type: {name: $t}, inwardIssue: {key: $b}, outwardIssue: {key: $d}}')"
}

# create --title T --body B [--parent KEY] [--blocked-by KEY[,KEY]] [--label L]...
# Prints ID= and URL= as soon as the issue exists; a failure after that (squad
# label, links) is reported with exit 20 and the ID is still on stdout, so a
# half-created graph is visible, never silent.
tracker_create() {
  local title="" body="" parent="" blocked="" labels="[]" type extra fields adf rc b key
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { echo "squad: create: $1 requires a value" >&2; return 2; }
    case "$1" in
      --title) title="$2" ;;
      --body) body="$2" ;;
      --parent) parent="$2" ;;
      --blocked-by) blocked="$2" ;;
      --label) labels="$(jq -nc --argjson l "$labels" --arg v "$(_jr_label_name "$2")" '$l + [$v]')" ;;
      *) echo "squad: create: unknown argument '$1'" >&2; return 2 ;;
    esac
    shift 2
  done
  [ -n "$title" ] || { echo "squad: create requires --title" >&2; return 2; }
  [ -z "$parent" ] || _jr_key "$parent" || { echo "squad: '$parent' is not a Jira issue key" >&2; return 2; }
  for b in $(printf '%s' "$blocked" | tr ',' ' '); do
    _jr_key "$b" || { echo "squad: '$b' is not a Jira issue key" >&2; return 2; }
  done
  _jr_ready || return $?
  type="$(_jr_cfg .chisel.jira_issue_type)"; type="${type:-Task}"
  if [ -n "$parent" ]; then
    _jr_call GET "/issue/$parent?fields=issuetype"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    case "$(printf '%s' "$JR_BODY" | jq -r '(.fields.issuetype.hierarchyLevel // (if .fields.issuetype.name == "Epic" then 1 else 0 end)) | tostring')" in
      -*) echo "squad: jira: parent $parent is a sub-task and cannot have children" >&2; return 10 ;;
      0) type="$(_jr_cfg .chisel.jira_subtask_type)"; type="${type:-Sub-task}" ;;
    esac
  fi
  extra="$(_jr_cfg '.chisel.jira_fields | objects')"; [ -n "$extra" ] || extra="{}"
  adf="$(printf '%s' "$body" | _jr_adf)" || return 20
  fields="$(jq -nc --arg p "$JR_PROJECT" --arg t "$title" --arg ty "$type" --arg par "$parent" \
    --argjson d "$adf" --argjson l "$labels" --argjson x "$extra" '
    $x + {project: {key: $p}, summary: $t, issuetype: {name: $ty}, description: $d, labels: $l}
    + (if $par == "" then {} else {parent: {key: $par}} end)
    | {fields: .}')" || return 20
  _jr_call POST /issue "$fields"; rc=$?
  [ "$rc" -eq 0 ] || return 20
  key="$(printf '%s' "$JR_BODY" | jq -r '.key // empty')"
  [ -n "$key" ] || { echo "squad: jira create returned no key" >&2; return 20; }
  echo "ID=$key"; echo "URL=https://$JR_SITE/browse/$key"
  _jr_labels_edit "$key" add "squad-$key" \
    || { echo "squad: created $key but adding its squad label failed" >&2; return 20; }
  for b in $(printf '%s' "$blocked" | tr ',' ' '); do
    tracker_link_blocking "$b" "$key" \
      || { echo "squad: created $key but linking it as blocked by $b failed" >&2; return 20; }
  done
  return 0
}

# create-child <parent> --title T --body B [--blocked-by KEY[,KEY]] [--label L]...
tracker_create_child() {
  local p="${1:-}"
  [ -n "$p" ] || { echo "squad: create-child requires a parent id" >&2; return 2; }
  shift
  tracker_create "$@" --parent "$p"
}

# --- state transitions ---------------------------------------------------------

# _jr_status_of <id>: current status name into JR_STATUS.
_jr_status_of() {
  local rc
  _jr_call GET "/issue/$1?fields=status"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  JR_STATUS="$(printf '%s' "$JR_BODY" | jq -r '.fields.status.name // empty')"
}

# _jr_move <id> <target status name>: transition by the TARGET status found in
# the live transition list, never by a remembered id. Emits OUTCOME/CHANGED
# data into JR_OUTCOME/JR_FROM. 10 + REASON when no transition leads there.
_jr_move() {
  local id="$1" target="$2" tid rc names
  _jr_status_of "$id" || return $?
  JR_FROM="$JR_STATUS"
  if [ "$(printf '%s' "$JR_FROM" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" ]; then
    JR_OUTCOME=unchanged; return 0
  fi
  _jr_call GET "/issue/$id/transitions"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  tid="$(printf '%s' "$JR_BODY" | jq -r --arg t "$target" '[.transitions[]? | select((.to.name | ascii_downcase) == ($t | ascii_downcase)) | .id][0] // empty')"
  if [ -z "$tid" ]; then
    names="$(printf '%s' "$JR_BODY" | jq -r '[.transitions[]?.to.name] | join(", ")')"
    echo "REASON=no transition from \"$JR_FROM\" to \"$target\" on $id (available targets: ${names:-none})"
    echo "squad: jira: no transition from \"$JR_FROM\" to \"$target\" on $id; fix jira_states or the workflow" >&2
    return 10
  fi
  _jr_call POST "/issue/$id/transitions" "$(jq -nc --arg i "$tid" '{transition: {id: $i}}')" || return 20
  JR_OUTCOME=applied
}

# tracker_set_state <id> <claim|review|needs-review|escalate> [--reason T] [--handoff P]
# Hook used by squad-tracker.sh and squad-labels.sh instead of the label state
# machine. claim: transition jira_states."in-progress" and assign the token's
# user. review: jira_states."in-review" else "needs-review". needs-review (the
# review loop gave up): add the configured review_label. escalate: comment the
# reason when the policy allows it, add state_labels.blocked, and transition
# jira_states."blocked" when mapped. A state with no mapping, or no live
# transition to it, is reported (10, REASON=), never guessed.
tracker_set_state() {
  local id="${1:-}" verb="${2:-}" reason="" key target lab rl rc
  [ -n "$id" ] && [ -n "$verb" ] || { echo "squad: usage: set-state <id> <state>" >&2; return 2; }
  _jr_key "$id" || { echo "squad: '$id' is not a Jira issue key" >&2; return 2; }
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      --handoff) shift 2 ;;
      *) echo "squad: set-state: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  _jr_ready || return $?
  JR_OUTCOME=unchanged; JR_FROM=""
  case "$verb" in
    claim|review|escalate)
      case "$verb" in claim) key="in-progress" ;; review) key="in-review" ;; escalate) key="blocked" ;; esac
      target="$(_jr_cfg ".chisel.jira_states[\"$key\"]")"
      [ -n "$target" ] || [ "$verb" != review ] || target="$(_jr_cfg '.chisel.jira_states["needs-review"]')"
      if [ -z "$target" ] && [ "$verb" != escalate ]; then
        echo "REASON=no jira_states mapping for \"$key\" in chisel-config.json"
        echo "squad: jira: chisel.jira_states has no \"$key\" entry; add it" >&2
        return 10
      fi ;;
    needs-review) target="" ;;
    *) echo "squad: set-state: unknown transition '$verb'" >&2; return 2 ;;
  esac
  if [ "$verb" = escalate ]; then
    if squad_policy_allows tracker comment; then
      tracker_comment "$id" --body "$reason" || return 20
    else
      echo "COMMENT=skipped"
      echo "REASON=policy: comment not allowed on ${DISPLAY_NAME:-project}"
    fi
    lab="$(_jr_cfg .chisel.state_labels.blocked)"
    if [ -n "$lab" ]; then _jr_labels_edit "$id" add "$lab" || return 20; JR_OUTCOME=applied; fi
    if [ -z "$target" ]; then
      echo "TRANSITION=skipped"
      echo "squad: jira: chisel.jira_states has no \"blocked\" entry; $id keeps its status" >&2
    fi
  fi
  if [ "$verb" = needs-review ]; then
    rl="$(_jr_cfg .chisel.review_label)"
    if [ -z "$rl" ] || [ "$rl" = none ]; then
      echo "squad: needs-review: review_label is not configured" >&2; return 10
    fi
    _jr_labels_edit "$id" add "$rl" || return 20
    JR_OUTCOME=applied
  fi
  if [ -n "$target" ]; then
    _jr_move "$id" "$target"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ "$verb" = claim ]; then
      tracker_label "$id" --assign-me || return 20
    fi
  fi
  echo "OUTCOME=$JR_OUTCOME"
  [ "$JR_OUTCOME" = applied ] && echo "CHANGED=yes" || echo "CHANGED=no"
  echo "ISSUE=$id"
  [ -z "$JR_FROM" ] || echo "FROM_STATE=$JR_FROM"
  [ -z "$target" ] || echo "TO_STATE=$target"
  return 0
}
