#!/usr/bin/env bash
# vcs/bitbucket.sh -- Bitbucket Cloud pull request adapter (REST 2.0) for
# squad-vcs.sh. SOURCED by squad_vcs (squad-common.sh); do not execute. Bash 3.2,
# needs jq and curl. Never calls the GitHub CLI; the only vendor call is `curl`
# through squad-http.sh, shared with tracker/jira.sh (test seam: scripts/curl-shim/).
#
# Repository: workspace and slug come from the `origin` remote of the current
# directory (git@bitbucket.org:ws/repo.git, https://[user@]bitbucket.org/ws/repo.git,
# ssh://git@bitbucket.org/ws/repo.git), overridable under `chisel` in
# chisel-config.json (all non-secret):
#   bitbucket_workspace   workspace id
#   bitbucket_repo        repository slug
#   bitbucket_user        Bitbucket username of an app password; when set the call
#                         authenticates with Basic <user>:<app password>, else
#                         with `Bearer <token>` (a repository / workspace access token)
# Token: never in a file. Read per call from the macOS keychain
# (`security find-generic-password -s squad-bitbucket -a <bitbucket_user, else the
# workspace> -w`), else the environment variable SQUAD_BITBUCKET_TOKEN. Passed to
# curl through a config file descriptor, never on argv, never printed.
#
# Verbs, same contract as vcs/github.sh: available cli-name auth-status
# default-branch branch-exists pr-for-branch pr-list pr-view pr-data pr-create
# diff description-get description-set comment merged. `stack-init` is not
# supported (Bitbucket has no stacked branches): exit 10, REASON= on stdout; Ralph
# logs it and carries on. Return codes: 0 ok, 2 usage, 10 precondition not met or
# unsupported, 20 failure. Writes are refused outside connected mode by
# squad_write_guard (inside squad_http_call) and by the write policy in the facade.
# Bitbucket's PR payloads carry 12-character commit hashes; HEAD_OID and the PR
# commit ids are expanded to full hashes where a caller compares them to git.

# shellcheck disable=SC1091
. "$SQUAD_COMMON_DIR/squad-http.sh"

BB_API="https://api.bitbucket.org/2.0"

# --- config and credentials -------------------------------------------------

# _bb_cfg <key>: chisel.<key> from chisel-config.json, empty when absent.
_bb_cfg() {
  local cfg="${STATE_DIR:-}/chisel-config.json"
  [ -n "${STATE_DIR:-}" ] && [ -f "$cfg" ] || return 0
  jq -r --arg k "$1" '.chisel[$k] // empty' "$cfg" 2>/dev/null
}

# _bb_remote: "<workspace> <repo>" parsed from the origin remote, nothing when
# it is not a Bitbucket URL.
_bb_remote() {
  local u p
  u="$(git remote get-url origin 2>/dev/null)" || return 0
  case "$u" in
    *bitbucket.org:*) p="${u#*bitbucket.org:}" ;;
    *bitbucket.org/*) p="${u#*bitbucket.org/}" ;;
    *) return 0 ;;
  esac
  p="${p%/}"; p="${p%.git}"
  case "$p" in */*/*|/*|*/) return 0 ;; */*) printf '%s %s\n' "${p%%/*}" "${p#*/}" ;; esac
}

# _bb_ready: load config and token once per process into BB_WS/BB_REPO/BB_AUTH
# (the Authorization header value, a plain shell variable never exported or
# printed). 10 + reason on stderr when something is missing.
_bb_ready() {
  [ -n "${BB_AUTH:-}" ] && return 0
  local rem user tok
  command -v jq >/dev/null 2>&1 || { echo "squad: bitbucket needs jq" >&2; return 10; }
  command -v curl >/dev/null 2>&1 || { echo "squad: bitbucket needs curl" >&2; return 10; }
  BB_WS="$(_bb_cfg bitbucket_workspace)"; BB_REPO="$(_bb_cfg bitbucket_repo)"
  if [ -z "$BB_WS" ] || [ -z "$BB_REPO" ]; then
    rem="$(_bb_remote)"
    [ -n "$BB_WS" ] || BB_WS="${rem%% *}"
    [ -n "$BB_REPO" ] || BB_REPO="${rem#* }"
  fi
  [ -n "$BB_WS" ] && [ -n "$BB_REPO" ] \
    || { echo "squad: bitbucket: cannot tell the repository (origin is not a bitbucket.org remote; set chisel.bitbucket_workspace and bitbucket_repo)" >&2; return 10; }
  case "$BB_WS$BB_REPO" in *[!A-Za-z0-9._-]*) echo "squad: bitbucket: workspace or repository slug has unexpected characters" >&2; return 10 ;; esac
  user="$(_bb_cfg bitbucket_user)"
  tok="$(squad_http_token squad-bitbucket "${user:-$BB_WS}" SQUAD_BITBUCKET_TOKEN)"
  [ -n "$tok" ] || { echo "squad: bitbucket: no API token (keychain item 'squad-bitbucket' for ${user:-$BB_WS}, or env SQUAD_BITBUCKET_TOKEN)" >&2; return 10; }
  if [ -n "$user" ]; then BB_AUTH="Basic $(printf '%s:%s' "$user" "$tok" | base64 | tr -d '\n')"
  else BB_AUTH="Bearer $tok"; fi
  tok=""
  return 0
}

# --- HTTP ---------------------------------------------------------------------

# _bb_call <GET|POST|PUT> <path or next-page URL> [json body]: sets BB_BODY and
# BB_CODE. 0 on 2xx, 10 on 404, 20 otherwise. A URL is followed only on the API host.
_bb_call() {
  local m="$1" p="$2" body="${3:-}" url rc=0
  _bb_ready || return $?
  case "$p" in
    "$BB_API"/*) url="$p"; p="${p#"$BB_API"}" ;;
    https://*) echo "squad: bitbucket: refusing to follow a link off the API host" >&2; return 20 ;;
    *) url="$BB_API$p" ;;
  esac
  squad_http_call "$m" "$url" "$BB_AUTH" "$body" || rc=$?
  BB_CODE="$SQUAD_HTTP_CODE"; BB_BODY="$SQUAD_HTTP_BODY"
  if [ "$rc" -ne 0 ]; then
    [ "$SQUAD_HTTP_RC" -eq 0 ] || echo "squad: bitbucket $m ${p%%\?*} failed (curl exit $SQUAD_HTTP_RC)" >&2
    return 20
  fi
  case "$BB_CODE" in
    2??) return 0 ;;
    404) echo "squad: bitbucket $m ${p%%\?*}: not found (HTTP 404)" >&2; return 10 ;;
    *) echo "squad: bitbucket $m ${p%%\?*} failed (HTTP $BB_CODE): $(printf '%s' "$BB_BODY" | jq -r '.error.message // empty' 2>/dev/null | tr '\n' ' ')" >&2; return 20 ;;
  esac
}

# _bb_pages <path>: every `values` element of a paginated list into BB_ALL (a JSON
# array), following `next` up to 20 pages.
_bb_pages() {
  local url="$1" n=0 rc
  BB_ALL="[]"
  while [ -n "$url" ] && [ "$n" -lt 20 ]; do
    _bb_call GET "$url"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    BB_ALL="$(jq -nc --argjson a "$BB_ALL" --argjson p "$BB_BODY" '$a + ($p.values // [])')" || return 20
    url="$(printf '%s' "$BB_BODY" | jq -r '.next // empty')"
    n=$((n + 1))
  done
}

_bb_repo() { echo "/repositories/$BB_WS/$BB_REPO"; }
_bb_uri() { jq -rn --arg s "$1" '$s | @uri'; }
# _bb_path <branch>: percent-encode each segment, keep the slashes.
_bb_path() { jq -rn --arg s "$1" '$s | split("/") | map(@uri) | join("/")'; }
# _bb_ts: normalise Bitbucket timestamps (fractions, +00:00) to 2026-01-02T03:04:05Z.
_BB_TS='def ts: if . == null then null else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") end;'
_bb_state_jq='(if .state == "DECLINED" or .state == "SUPERSEDED" then "CLOSED" else .state end)'

# _bb_full_hash <hash>: the full commit hash (PR payloads carry 12 characters).
_bb_full_hash() {
  if _bb_call GET "$(_bb_repo)/commit/$1"; then
    printf '%s\n' "$BB_BODY" | jq -r '.hash // empty'
  else printf '%s\n' "$1"; fi
}

# _bb_pr <pr|branch>: PR number into BB_PR and its object into BB_PRJ. A number is
# taken as is; a branch resolves to its open PR, else its newest PR of any state.
_bb_pr() {
  local ref="$1" rc q
  case "$ref" in
    ''|*[!0-9]*)
      case "$ref" in *'"'*) echo "squad: bitbucket: invalid branch name" >&2; return 2 ;; esac
      q="$(_bb_uri "source.branch.name=\"$ref\"")"
      _bb_pages "$(_bb_repo)/pullrequests?q=$q&state=OPEN&sort=-created_on&pagelen=50"; rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      BB_PRJ="$(printf '%s' "$BB_ALL" | jq -c '.[0] // empty')"
      if [ -z "$BB_PRJ" ]; then
        _bb_pages "$(_bb_repo)/pullrequests?q=$q&state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED&sort=-created_on&pagelen=50"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        BB_PRJ="$(printf '%s' "$BB_ALL" | jq -c '.[0] // empty')"
      fi
      [ -n "$BB_PRJ" ] || { echo "squad: bitbucket: no pull request for branch '$ref'" >&2; return 20; }
      BB_PR="$(printf '%s' "$BB_PRJ" | jq -r .id)" ;;
    *)
      BB_PR="$ref"
      _bb_call GET "$(_bb_repo)/pullrequests/$ref"; rc=$?
      [ "$rc" -eq 0 ] || { [ "$rc" -ne 10 ] || echo "squad: bitbucket: no pull request $ref" >&2; return 20; }
      BB_PRJ="$BB_BODY" ;;
  esac
}

# --- facade verbs -----------------------------------------------------------------

vcs_available() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; }
vcs_cli_name() { echo "CLI_NAME=curl"; }

# auth-status: 0 when the credential can read the repository.
vcs_auth_status() { _bb_ready >/dev/null 2>&1 && _bb_call GET "$(_bb_repo)" >/dev/null 2>&1; }

vcs_default_branch() {
  local rc b
  _bb_ready || return $?
  _bb_call GET "$(_bb_repo)"; rc=$?
  [ "$rc" -eq 0 ] || return 20
  b="$(printf '%s' "$BB_BODY" | jq -r '.mainbranch.name // empty')"
  [ -n "$b" ] || { echo "squad: bitbucket: repository has no main branch" >&2; return 20; }
  echo "DEFAULT_BRANCH=$b"
}

vcs_branch_exists() {
  local rc
  [ -n "${1:-}" ] || { echo "squad: branch-exists requires a branch" >&2; return 2; }
  _bb_ready || return $?
  _bb_call GET "$(_bb_repo)/refs/branches/$(_bb_path "$1")" 2>/dev/null; rc=$?
  case "$rc" in 0) echo "EXISTS=yes" ;; 10) echo "EXISTS=no" ;; *) return 20 ;; esac
}

# pr-for-branch <branch> [--state open|all|merged]: as vcs/github.sh. HEAD_OID is
# the full source commit hash.
vcs_pr_for_branch() {
  local b="${1:-}" st=open q states rc s o
  [ -n "$b" ] || { echo "squad: pr-for-branch requires a branch" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --state) st="${2:-}"; shift 2 ;; *) echo "squad: pr-for-branch: unknown argument '$1'" >&2; return 2 ;; esac
  done
  case "$b" in *'"'*) echo "squad: bitbucket: invalid branch name" >&2; return 2 ;; esac
  case "$st" in
    open) states="state=OPEN" ;;
    all) states="state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED" ;;
    merged) states="state=MERGED" ;;
    *) echo "squad: pr-for-branch: unknown state '$st'" >&2; return 2 ;;
  esac
  _bb_ready || return $?
  q="$(_bb_uri "source.branch.name=\"$b\"")"
  _bb_pages "$(_bb_repo)/pullrequests?q=$q&$states&sort=-created_on&pagelen=50"; rc=$?
  [ "$rc" -eq 0 ] || return 20
  case "$st" in
    open)
      printf '%s' "$BB_ALL" | jq -r '.[0] | select(. != null) | "PR=\(.id)", "BASE=\(.destination.branch.name)"' ;;
    all|merged)
      printf '%s' "$BB_ALL" | jq -r '.[]
        | (if .state == "DECLINED" or .state == "SUPERSEDED" then "CLOSED" else .state end) as $s
        | "\($s) \(.source.commit.hash)"' \
      | while read -r s o || [ -n "$s" ]; do
          o="$(_bb_full_hash "$o")"
          [ "$st" = all ] && echo "STATE=$s"
          echo "HEAD_OID=$o"
        done ;;
  esac
}

# pr-list [--state open] [--limit N]: `#<n> <title> (<head> -> <base>)`.
vcs_pr_list() {
  local lim=10 rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) [ "${2:-}" = open ] || { echo "squad: pr-list supports --state open only" >&2; return 2; }; shift 2 ;;
      --limit) lim="${2:-10}"; shift 2 ;;
      *) echo "squad: pr-list: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  case "$lim" in ''|*[!0-9]*) echo "squad: pr-list: --limit needs a number" >&2; return 2 ;; esac
  _bb_ready || return $?
  _bb_call GET "$(_bb_repo)/pullrequests?state=OPEN&sort=-created_on&pagelen=$lim"; rc=$?
  [ "$rc" -eq 0 ] || return 20
  printf '%s' "$BB_BODY" | jq -r --argjson n "$lim" '[.values[]?][:$n][] | "#\(.id) \(.title | gsub("[\r\n]"; " ")) (\(.source.branch.name) -> \(.destination.branch.name))"'
}

# pr-view <pr|branch> --field base|changed-files|state|url|title.
vcs_pr_view() {
  local ref="${1:-}" f="" rc
  [ -n "$ref" ] || { echo "squad: pr-view requires a pr or branch" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --field) f="${2:-}"; shift 2 ;; *) echo "squad: pr-view: unknown argument '$1'" >&2; return 2 ;; esac
  done
  case "$f" in base|changed-files|state|url|title) ;; *) echo "squad: pr-view requires --field base|changed-files|state|url|title" >&2; return 2 ;; esac
  _bb_ready || return $?
  _bb_pr "$ref"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case "$f" in
    base) echo "BASE=$(printf '%s' "$BB_PRJ" | jq -r '.destination.branch.name')" ;;
    state) echo "STATE=$(printf '%s' "$BB_PRJ" | jq -r "$_bb_state_jq")" ;;
    url) echo "URL=$(printf '%s' "$BB_PRJ" | jq -r '.links.html.href')" ;;
    title) echo "TITLE=$(printf '%s' "$BB_PRJ" | jq -r '.title | gsub("[\r\n]"; " ")')" ;;
    changed-files)
      _bb_pages "$(_bb_repo)/pullrequests/$BB_PR/diffstat?pagelen=100" || return 20
      echo "CHANGED_FILES=$(printf '%s' "$BB_ALL" | jq 'length')" ;;
  esac
}

# pr-data <pr> --fields a,b,c: one JSON object in the GitHub PR vocabulary.
vcs_pr_data() {
  local pr="${1:-}" f="" rc fld extra='{}' want
  [ -n "$pr" ] || { echo "squad: pr-data requires a pr" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --fields) f="${2:-}"; shift 2 ;; *) echo "squad: pr-data: unknown argument '$1'" >&2; return 2 ;; esac
  done
  [ -n "$f" ] || { echo "squad: pr-data requires --fields" >&2; return 2; }
  for fld in $(printf '%s' "$f" | tr ',' ' '); do
    case "$fld" in
      number|state|title|body|url|createdAt|mergedAt|mergeCommit|commits|files|reviews|comments|headRefName|baseRefName) ;;
      *) echo "squad: pr-data: unsupported field '$fld'" >&2; return 2 ;;
    esac
  done
  _bb_ready || return $?
  _bb_pr "$pr"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case ",$f," in *,commits,*)
    _bb_pages "$(_bb_repo)/pullrequests/$BB_PR/commits?pagelen=100" || return 20
    extra="$(jq -nc --argjson e "$extra" --argjson v "$BB_ALL" "$_BB_TS"'
      $e + {commits: [$v[] | {oid: .hash, committedDate: (.date | ts), messageHeadline: (.message | split("\n")[0])}]}')" ;; esac
  case ",$f," in *,files,*)
    _bb_pages "$(_bb_repo)/pullrequests/$BB_PR/diffstat?pagelen=100" || return 20
    extra="$(jq -nc --argjson e "$extra" --argjson v "$BB_ALL" '$e + {files: [$v[] | {path: (.new.path // .old.path)}]}')" ;; esac
  case ",$f," in *,comments,*)
    _bb_pages "$(_bb_repo)/pullrequests/$BB_PR/comments?pagelen=100" || return 20
    extra="$(jq -nc --argjson e "$extra" --argjson v "$BB_ALL" "$_BB_TS"'
      $e + {comments: [$v[] | select(.deleted | not) | {body: .content.raw, author: {login: (.user.nickname // .user.display_name // "")}, createdAt: (.created_on | ts)}]}')" ;; esac
  printf '%s' "$BB_PRJ" | jq -c --argjson x "$extra" --arg want ",$f," "$_BB_TS"'
    {number: .id, state: '"$_bb_state_jq"', title: .title, body: (.description // ""), url: .links.html.href,
     createdAt: (.created_on | ts), mergedAt: (if .state == "MERGED" then (.updated_on | ts) else null end),
     mergeCommit: (if .merge_commit then {oid: .merge_commit.hash} else null end),
     reviews: [.participants[]? | select(.approved) | {author: {login: (.user.nickname // .user.display_name // "")}, state: "APPROVED", body: ""}],
     headRefName: .source.branch.name, baseRefName: .destination.branch.name} + $x
    | with_entries(select($want | contains("," + .key + ",")))'
}

# stack-init: Bitbucket has no stacked branches. Unsupported, not an error.
vcs_stack_init() {
  echo "REASON=bitbucket has no native stacked branches; the branches keep their PR bases"
  echo "squad: stack-init is not supported on bitbucket" >&2
  return 10
}

vcs_merged() {
  local rc
  [ -n "${1:-}" ] || { echo "squad: merged requires a pr" >&2; return 2; }
  _bb_ready || return $?
  _bb_pr "$1"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if [ "$(printf '%s' "$BB_PRJ" | jq -r .state)" = MERGED ]; then echo "MERGED=yes"; else echo "MERGED=no"; fi
}

# description-get <pr>: the PR description on stdout, verbatim.
vcs_description_get() {
  local rc
  [ -n "${1:-}" ] || { echo "squad: description-get requires a pr" >&2; return 2; }
  _bb_ready || return $?
  _bb_pr "$1"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$BB_PRJ" | jq -r '.description // ""'
}

# description-set <pr> --body-file <path> (write): PUT title + description (the
# title is re-sent so the update never depends on Bitbucket's optional-field rules).
vcs_description_set() {
  local pr="${1:-}" file="" rc
  [ -n "$pr" ] || { echo "squad: description-set requires a pr" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --body-file) file="${2:-}"; shift 2 ;; *) echo "squad: description-set: unknown argument '$1'" >&2; return 2 ;; esac
  done
  [ -n "$file" ] && [ -r "$file" ] || { echo "squad: description-set requires a readable --body-file" >&2; return 2; }
  squad_write_guard || return 20
  _bb_ready || return $?
  _bb_pr "$pr"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _bb_call PUT "$(_bb_repo)/pullrequests/$BB_PR" \
    "$(jq -nc --arg t "$(printf '%s' "$BB_PRJ" | jq -r .title)" --rawfile d "$file" '{title: $t, description: $d}')" || return 20
}

# comment <pr> --body <text> (write).
vcs_comment() {
  local rc
  [ -n "${1:-}" ] && [ "${2:-}" = --body ] || { echo "squad: usage: comment <pr> --body <text>" >&2; return 2; }
  squad_write_guard || return 20
  _bb_ready || return $?
  _bb_pr "$1"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _bb_call POST "$(_bb_repo)/pullrequests/$BB_PR/comments" "$(jq -nc --arg r "${3:-}" '{content: {raw: $r}}')" || return 20
}

# --- diff ---------------------------------------------------------------------------

# _bb_diff_api <base> <head>: the diff of the open PR from <head> into <base>, from
# the API, on stdout. 1 (reason in BB_WHY) when there is no such PR or the API fails.
_bb_diff_api() {
  local base="$1" head="$2" rc id
  _bb_ready 2>/dev/null || { BB_WHY="no credentials or repository"; return 1; }
  _bb_pages "$(_bb_repo)/pullrequests?q=$(_bb_uri "source.branch.name=\"$head\"")&state=OPEN&sort=-created_on&pagelen=50"; rc=$?
  [ "$rc" -eq 0 ] || { BB_WHY="pull request lookup failed"; return 1; }
  id="$(printf '%s' "$BB_ALL" | jq -r --arg b "$base" '[.[] | select(.destination.branch.name == $b)][0].id // empty')"
  [ -n "$id" ] || { BB_WHY="no open PR from $head into $base"; return 1; }
  SQUAD_HTTP_ACCEPT="text/plain" SQUAD_HTTP_FOLLOW=1 _bb_call GET "$(_bb_repo)/pullrequests/$id/diff"; rc=$?
  [ "$rc" -eq 0 ] || { BB_WHY="diff request failed"; return 1; }
  printf '%s\n' "$BB_BODY"
}

# _bb_ref <name>: the local branch, else origin's, as a git ref.
_bb_ref() {
  if git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1; then echo "$1"
  elif git rev-parse -q --verify "origin/$1^{commit}" >/dev/null 2>&1; then echo "origin/$1"
  else return 1; fi
}

# diff --base B --head H: the unified diff of the PR from H into B (its own diff,
# so a stacked PR shows only its changes). When the API cannot give it, the diff
# of local git (`B...H`) is printed instead, labelled by a first `# squad:` line on
# stdout and by a stderr line.
vcs_diff() {
  local base="" head="" b h
  while [ $# -gt 0 ]; do
    case "$1" in --base) base="${2:-}"; shift 2 ;; --head) head="${2:-}"; shift 2 ;; *) echo "squad: diff: unknown argument '$1'" >&2; return 2 ;; esac
  done
  [ -n "$base" ] && [ -n "$head" ] || { echo "squad: diff requires --base and --head" >&2; return 2; }
  case "$head" in *'"'*) echo "squad: bitbucket: invalid branch name" >&2; return 2 ;; esac
  BB_WHY=""
  _bb_diff_api "$base" "$head" && return 0
  b="$(_bb_ref "$base")" && h="$(_bb_ref "$head")" \
    || { echo "squad: bitbucket diff: ${BB_WHY:-API unavailable} and $base / $head are not in the local clone" >&2; return 20; }
  echo "squad: bitbucket: ${BB_WHY:-API unavailable}; diff computed from local git ($b...$h)" >&2
  echo "# squad: local git diff $b...$h (Bitbucket API unavailable: ${BB_WHY:-unknown})"
  git diff "$b...$h" || return 20
}

# pr-create --head H --base B --title T --body B: open a PR (write). URL= and PR=.
vcs_pr_create() {
  local head="" base="" title="" body="" rc payload
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { echo "squad: $1 requires a value" >&2; return 2; }
    case "$1" in
      --head) head="$2" ;; --base) base="$2" ;; --title) title="$2" ;; --body) body="$2" ;;
      *) echo "squad: pr-create: unknown argument '$1'" >&2; return 2 ;;
    esac
    shift 2
  done
  [ -n "$head" ] && [ -n "$base" ] && [ -n "$title" ] || { echo "squad: pr-create requires --head, --base and --title" >&2; return 2; }
  squad_write_guard || return 20
  _bb_ready || return $?
  payload="$(jq -nc --arg h "$head" --arg b "$base" --arg t "$title" --arg d "$body" \
    '{title: $t, description: $d, source: {branch: {name: $h}}, destination: {branch: {name: $b}}}')" || return 20
  _bb_call POST "$(_bb_repo)/pullrequests" "$payload"; rc=$?
  [ "$rc" -eq 0 ] || { echo "squad: pr create failed" >&2; return 20; }
  printf '%s' "$BB_BODY" | jq -r '"PR=\(.id)", "URL=\(.links.html.href)"'
}
