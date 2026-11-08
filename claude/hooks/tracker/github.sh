#!/usr/bin/env bash
# tracker/github.sh -- GitHub Issues adapter for squad-tracker.sh.
# SOURCED by squad_tracker (squad-common.sh); do not execute. Bash 3.2.
#
# This file and vcs/github.sh are the ONLY places the squad calls the GitHub
# CLI. Auth is the CLI's own (`gh auth login`, OS keychain); no token is read
# here. Every verb is `tracker_<verb with - as _>`; stdout is KEY=VALUE lines
# (SCRIPT_CONTRACT.md), the CLI's own stdout never leaks. Return codes:
# 0 ok, 2 usage, 10 precondition not met, 20 CLI/io failure.
#
# Squad state -> GitHub label mapping: the label names come from
# chisel-config.json (state_labels.*, review_label), read by squad-labels.sh,
# which owns the state machine and calls the label verbs below.

# tracker_write <argv...>: the ONLY mutating path. Refuses outside connected
# mode (squad_provider_write); a CLI failure is mapped to 20.
tracker_write() { squad_provider_write gh "$@"; }

# _trk_repo: owner/repo of the current checkout, cached per process.
_trk_repo() {
  [ -n "${_TRK_GH_REPO:-}" ] && return 0
  local j
  j="$(gh repo view --json nameWithOwner)" || { echo "squad: tracker repo lookup failed" >&2; return 20; }
  _TRK_GH_REPO="$(printf '%s' "$j" | sed -n 's/.*"nameWithOwner" *: *"\([^"]*\)".*/\1/p')"
  [ -n "$_TRK_GH_REPO" ] || { echo "squad: cannot determine owner/repo" >&2; return 20; }
  return 0
}

# repo: REPO=<owner/repo>. Also primes the per-process cache, so a caller that
# runs it unwrapped (not in $(...)) pays one lookup for the whole call.
tracker_repo() { _trk_repo || return 20; echo "REPO=$_TRK_GH_REPO"; }

# _trk_names: label names from CLI JSON on stdin, one per line.
_trk_names() { grep -o '"name" *: *"[^"]*"' | sed 's/^"name" *: *"//; s/"$//'; }

# preflight [--project-owner O --project-number N]: CLI present, authenticated,
# new enough for parent/blocked-by, project reachable. 10 + reason otherwise.
tracker_preflight() {
  local owner="" num="" v found auths
  while [ $# -gt 0 ]; do
    case "$1" in
      --project-owner) owner="${2:-}"; shift 2 ;;
      --project-number) num="${2:-}"; shift 2 ;;
      *) echo "squad: preflight: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found on PATH. Install gh and authenticate before running the squad." >&2; return 10; }
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh CLI is not authenticated. Run 'gh auth login' and retry." >&2; return 10; }
  v="$(gh --version 2>/dev/null | sed -n '1s/^gh version \([0-9][0-9.]*\).*/\1/p')"
  found="${v:-unknown}"
  if [ -n "$v" ] && [ "$(printf '%s\n2.95.0\n' "$v" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" != "2.95.0" ]; then
    echo "ERROR: gh CLI version $found is older than the required 2.95.0. Upgrade gh and retry." >&2; return 10
  fi
  if [ -n "$owner" ] && [ -n "$num" ]; then
    auths="$(gh auth status 2>&1)"
    case "$auths" in *project*) ;; *) echo "ERROR: gh token lacks the 'project' scope. Run: gh auth refresh -s project" >&2; return 10 ;; esac
    gh project view "$num" --owner "$owner" >/dev/null 2>&1 \
      || { echo "ERROR: project $owner/$num does not exist or is not reachable." >&2; return 10; }
  fi
  echo "PROVIDER=github"; echo "VERSION=$found"
  return 0
}

# label-list: names of the labels that exist in the repo, one per line.
tracker_label_list() {
  local repo list
  _trk_repo || return 20; repo="$_TRK_GH_REPO"
  list="$(gh label list -R "$repo" --json name)" || { echo "squad: label list failed" >&2; return 20; }
  printf '%s' "$list" | _trk_names
  return 0
}

# label-create <name>: create the label (write).
tracker_label_create() {
  [ -n "${1:-}" ] || { echo "squad: label-create requires a name" >&2; return 2; }
  _trk_repo || return 20
  tracker_write label create "$1" -R "$_TRK_GH_REPO"
}

# labels <id>: current label names of the issue, one per line (read).
tracker_labels() {
  local view
  [ -n "${1:-}" ] || { echo "squad: labels requires an id" >&2; return 2; }
  _trk_repo || return 20
  view="$(gh issue view "$1" -R "$_TRK_GH_REPO" --json labels)" || { echo "squad: issue view $1 failed" >&2; return 20; }
  printf '%s' "$view" | _trk_names
  return 0
}

# label <id> [--assign-me] [--add L]... [--remove L]...: one edit call, flags
# in the order given (write).
tracker_label() {
  local id="${1:-}" out
  [ -n "$id" ] || { echo "squad: label requires an id" >&2; return 2; }
  shift
  _trk_repo || return 20
  set -- "$@" ""   # sentinel so the loop can shift pairs safely
  out=()
  while [ $# -gt 1 ]; do
    case "$1" in
      --assign-me) out+=(--add-assignee @me); shift ;;
      --add) out+=(--add-label "$2"); shift 2 ;;
      --remove) out+=(--remove-label "$2"); shift 2 ;;
      *) echo "squad: label: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  [ "${#out[@]}" -gt 0 ] || { echo "squad: label: nothing to change" >&2; return 2; }
  tracker_write issue edit "$id" -R "$_TRK_GH_REPO" "${out[@]}"
}

# comment <id> --body <text>: add a comment (write).
tracker_comment() {
  local id="${1:-}"
  [ -n "$id" ] && [ "${2:-}" = --body ] || { echo "squad: usage: comment <id> --body <text>" >&2; return 2; }
  _trk_repo || return 20
  tracker_write issue comment "$id" -R "$_TRK_GH_REPO" --body "${3:-}"
}

# _trk_block <json>: ID/TITLE/STATE/URL/PARENT/BLOCKED_BY/LABELS/CONTAINER from
# one issue's JSON (needs jq).
_trk_block() {
  printf '%s' "$1" | jq -r '
    "ID=\(.number)",
    "TITLE=\(.title | gsub("[\r\n]"; " "))",
    "STATE=\(.state | ascii_downcase)",
    "URL=\(.url)",
    "PARENT=\(.parent.number // "")",
    "BLOCKED_BY=\([.blockedBy[]?.number] | map(tostring) | join(","))",
    "BLOCKING=\([.blocking[]?.number] | map(tostring) | join(","))",
    "LABELS=\([.labels[]?.name] | join(","))",
    "CONTAINER=\(if (.subIssuesSummary.total // 0) > 0 then "yes" else "no" end)"'
}

# get <id>: one issue (read; needs jq).
tracker_get() {
  local j
  [ -n "${1:-}" ] || { echo "squad: get requires an id" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "squad: get needs jq" >&2; return 10; }
  _trk_repo || return 20
  j="$(gh issue view "$1" -R "$_TRK_GH_REPO" --json number,title,state,url,labels,parent,blockedBy,blocking,subIssuesSummary)" \
    || { echo "squad: issue view $1 failed" >&2; return 20; }
  _trk_block "$j"
}

# batch <container|latest>: the open sub-issues of a container, creation
# order, one KEY=VALUE block per issue separated by a blank line. `latest`
# picks the most recently created open container and emits CONTAINER_ID /
# CONTAINER_TITLE first. A container that has no sub-issues emits nothing.
# Limit 200 (the CLI default of 30 truncates silently); TRUNCATED=yes at 200.
tracker_batch() {
  local c="${1:-}" list n title count
  [ -n "$c" ] || { echo "squad: batch requires a container id or 'latest'" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "squad: batch needs jq" >&2; return 10; }
  _trk_repo || return 20
  list="$(gh issue list -R "$_TRK_GH_REPO" --state open -L 200 --json number,title,labels,subIssuesSummary,parent,createdAt)" \
    || { echo "squad: issue list failed" >&2; return 20; }
  count="$(printf '%s' "$list" | jq 'length')"
  if [ "$c" = latest ]; then
    n="$(printf '%s' "$list" | jq -r '[.[] | select((.subIssuesSummary.total // 0) > 0)] | sort_by(.createdAt) | last | .number // empty')"
    [ -n "$n" ] || { echo "squad: no open container found; give an explicit id" >&2; return 10; }
    title="$(printf '%s' "$list" | jq -r --argjson n "$n" '.[] | select(.number == $n) | .title | gsub("[\r\n]"; " ")')"
    echo "CONTAINER_ID=$n"; echo "CONTAINER_TITLE=$title"
    c="$n"
  fi
  [ "$count" -ge 200 ] && echo "TRUNCATED=yes"
  printf '%s' "$list" | jq -r --argjson p "$c" '.[] | select(.parent.number == $p) | .number' | while IFS= read -r n; do
    echo ""
    tracker_get "$n" || return 20
  done
}

# create --title T --body B [--parent N] [--blocked-by N[,N]] [--label L]...:
# create an issue (write). Prints ID= and URL=.
tracker_create() {
  local out url
  out=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --title|--body|--parent|--blocked-by|--label) [ $# -ge 2 ] || { echo "squad: $1 requires a value" >&2; return 2; }
        out+=("$1" "$2"); shift 2 ;;
      *) echo "squad: create: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  _trk_repo || return 20
  squad_write_guard || return 20
  url="$(gh issue create -R "$_TRK_GH_REPO" ${out[@]+"${out[@]}"})" || { echo "squad: issue create failed" >&2; return 20; }
  url="$(printf '%s\n' "$url" | tail -n 1)"
  echo "ID=${url##*/}"; echo "URL=$url"
}

# create-child <parent> --title T --body B [--blocked-by N[,N]] [--label L]...
tracker_create_child() {
  local p="${1:-}"
  [ -n "$p" ] || { echo "squad: create-child requires a parent id" >&2; return 2; }
  shift
  tracker_create "$@" --parent "$p"
}

# link-blocking <blocker> <dependent>: record that <blocker> blocks <dependent> (write).
tracker_link_blocking() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "squad: usage: link-blocking <blocker> <dependent>" >&2; return 2; }
  _trk_repo || return 20
  tracker_write issue edit "$1" -R "$_TRK_GH_REPO" --add-blocking "$2"
}

# project-add <issue-url> --owner O --number N: add an issue to a GitHub
# Project (write). Separate from create so a project failure never loses the issue.
tracker_project_add() {
  local url="${1:-}" owner="" num=""
  [ -n "$url" ] || { echo "squad: project-add requires an issue url" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2 ;;
      --number) num="${2:-}"; shift 2 ;;
      *) echo "squad: project-add: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$owner" ] && [ -n "$num" ] || { echo "squad: project-add requires --owner and --number" >&2; return 2; }
  tracker_write project item-add "$num" --owner "$owner" --url "$url"
}
