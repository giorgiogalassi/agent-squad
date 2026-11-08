#!/usr/bin/env bash
# vcs/github.sh -- GitHub pull request adapter for squad-vcs.sh.
# SOURCED by squad_vcs (squad-common.sh); do not execute. Bash 3.2.
#
# With tracker/github.sh, the ONLY place the squad calls the GitHub CLI. Auth
# is the CLI's own. Runs in the current directory (the CLI resolves the repo
# from it); callers cd first when they mean another checkout. Every verb is
# `vcs_<verb with - as _>`. Return codes: 0 ok, 2 usage, 10 precondition not
# met, 20 CLI/io failure. Stdout is KEY=VALUE lines unless a verb says
# otherwise; the CLI's own stdout never leaks.

# available: 0 when the CLI is installed.
vcs_available() { command -v gh >/dev/null 2>&1; }

# cli-name: CLI_NAME=<the provider CLI, for user-facing messages>.
vcs_cli_name() { echo "CLI_NAME=gh"; }

# auth-status: 0 when authenticated.
vcs_auth_status() { gh auth status >/dev/null 2>&1; }

# default-branch: DEFAULT_BRANCH=<name>.
vcs_default_branch() {
  local b
  b="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)" || return 20
  echo "DEFAULT_BRANCH=$b"
}

# branch-exists <branch>: EXISTS=yes|no on the remote.
vcs_branch_exists() {
  [ -n "${1:-}" ] || { echo "squad: branch-exists requires a branch" >&2; return 2; }
  if gh api "repos/{owner}/{repo}/branches/$1" --silent >/dev/null 2>&1; then echo "EXISTS=yes"; else echo "EXISTS=no"; fi
}

# pr-for-branch <branch> [--state open|all|merged] (default open): the PRs
# whose head is <branch>, newest first.
#   open    -> PR= BASE=            (the first open PR; nothing when none)
#   all     -> STATE= HEAD_OID=     (one pair per PR, STATE first)
#   merged  -> HEAD_OID=            (one per merged PR)
vcs_pr_for_branch() {
  local b="${1:-}" st=open row
  [ -n "$b" ] || { echo "squad: pr-for-branch requires a branch" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --state) st="${2:-}"; shift 2 ;; *) echo "squad: pr-for-branch: unknown argument '$1'" >&2; return 2 ;; esac
  done
  case "$st" in
    open)
      row="$(gh pr list --head "$b" --state open --json number,baseRefName --jq '.[0] | select(. != null) | "\(.number) \(.baseRefName)"' 2>/dev/null)" || return 20
      [ -n "${row%% *}" ] || return 0
      echo "PR=${row%% *}"
      case "$row" in *" "*) echo "BASE=${row#* }" ;; esac ;;
    all)
      gh pr list --head "$b" --state all --json state,headRefOid --jq '.[]|"\(.state) \(.headRefOid)"' 2>/dev/null \
        | while read -r s o || [ -n "$s" ]; do [ -n "$s" ] && { echo "STATE=$s"; echo "HEAD_OID=$o"; }; done
      return "${PIPESTATUS[0]}" ;;
    merged)
      gh pr list --head "$b" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null \
        | while read -r o || [ -n "$o" ]; do [ -n "$o" ] && echo "HEAD_OID=$o"; done
      return "${PIPESTATUS[0]}" ;;
    *) echo "squad: pr-for-branch: unknown state '$st'" >&2; return 2 ;;
  esac
}

# pr-list [--state open] [--limit N]: one display line per PR,
# `#<n> <title> (<head> -> <base>)` (display text, not KEY=VALUE).
vcs_pr_list() {
  local lim=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) [ "${2:-}" = open ] || { echo "squad: pr-list supports --state open only" >&2; return 2; }; shift 2 ;;
      --limit) lim="${2:-10}"; shift 2 ;;
      *) echo "squad: pr-list: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  gh pr list --state open --limit "$lim" --json number,title,headRefName,baseRefName \
    --jq '.[] | "#\(.number) \(.title) (\(.headRefName) -> \(.baseRefName))"' 2>/dev/null
}

# pr-view <pr|branch> --field base|changed-files|state|url|title: one field.
# Prints BASE= / CHANGED_FILES= / STATE= / URL= / TITLE=.
vcs_pr_view() {
  local ref="${1:-}" f="" q key
  [ -n "$ref" ] || { echo "squad: pr-view requires a pr or branch" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --field) f="${2:-}"; shift 2 ;; *) echo "squad: pr-view: unknown argument '$1'" >&2; return 2 ;; esac
  done
  case "$f" in
    base) q=baseRefName; key=BASE ;;
    changed-files) q=changedFiles; key=CHANGED_FILES ;;
    state) q=state; key=STATE ;;
    url) q=url; key=URL ;;
    title) q=title; key=TITLE ;;
    *) echo "squad: pr-view requires --field base|changed-files|state|url|title" >&2; return 2 ;;
  esac
  q="$(gh pr view "$ref" --json "$q" -q ".$q" 2>/dev/null)" || return 20
  echo "$key=$q"
}

# pr-data <pr> --fields a,b,c: ONE JSON object on stdout with the requested
# fields, in the PR JSON vocabulary the squad's readers use (number state title
# body url createdAt mergedAt mergeCommit commits files reviews comments
# headRefName baseRefName). The one verb whose stdout is JSON, not KEY=VALUE:
# the Python readers (stats, retro, atlas) consume it; other adapters map
# their API into this shape.
vcs_pr_data() {
  local pr="${1:-}" f=""
  [ -n "$pr" ] || { echo "squad: pr-data requires a pr" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --fields) f="${2:-}"; shift 2 ;; *) echo "squad: pr-data: unknown argument '$1'" >&2; return 2 ;; esac
  done
  [ -n "$f" ] || { echo "squad: pr-data requires --fields" >&2; return 2; }
  gh pr view "$pr" --json "$f" || return 20
}

# stack-init <branch>...: adopt the branches as a stacked chain (the gh-stack
# extension; write, not gated on tracker mode, like pr-create). 10 when the
# extension is missing.
vcs_stack_init() {
  [ $# -gt 0 ] || { echo "squad: stack-init requires branches" >&2; return 2; }
  gh stack --help >/dev/null 2>&1 || { echo "squad: the gh-stack extension is not installed" >&2; return 10; }
  gh stack init "$@" >&2 || return 20
}

# merged <pr>: MERGED=yes|no.
vcs_merged() {
  local s
  [ -n "${1:-}" ] || { echo "squad: merged requires a pr" >&2; return 2; }
  s="$(gh pr view "$1" --json state -q .state 2>/dev/null)" || return 20
  if [ "$s" = MERGED ]; then echo "MERGED=yes"; else echo "MERGED=no"; fi
}

# description-get <pr>: the PR body on stdout, verbatim (not KEY=VALUE).
vcs_description_get() {
  [ -n "${1:-}" ] || { echo "squad: description-get requires a pr" >&2; return 2; }
  gh pr view "$1" --json body -q .body
}

# description-set <pr> --body-file <path>: replace the PR body (write).
vcs_description_set() {
  local pr="${1:-}" file=""
  [ -n "$pr" ] || { echo "squad: description-set requires a pr" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --body-file) file="${2:-}"; shift 2 ;; *) echo "squad: description-set: unknown argument '$1'" >&2; return 2 ;; esac
  done
  [ -n "$file" ] || { echo "squad: description-set requires --body-file" >&2; return 2; }
  squad_provider_write gh pr edit "$pr" --body-file "$file"
}

# comment <pr> --body <text>: comment on a PR (write).
vcs_comment() {
  [ -n "${1:-}" ] && [ "${2:-}" = --body ] || { echo "squad: usage: comment <pr> --body <text>" >&2; return 2; }
  squad_provider_write gh pr comment "$1" --body "${3:-}"
}

# diff --base B --head H: the unified diff of H against B on stdout.
vcs_diff() {
  local base="" head=""
  while [ $# -gt 0 ]; do
    case "$1" in --base) base="${2:-}"; shift 2 ;; --head) head="${2:-}"; shift 2 ;; *) echo "squad: diff: unknown argument '$1'" >&2; return 2 ;; esac
  done
  [ -n "$base" ] && [ -n "$head" ] || { echo "squad: diff requires --base and --head" >&2; return 2; }
  gh api "repos/{owner}/{repo}/compare/$base...$head" -H "Accept: application/vnd.github.diff"
}

# pr-create --head H --base B --title T --body B: open a PR. Not gated on
# tracker mode: callers decide (Cody's `open pr`, the vault's own repo). The
# CLI output goes to stderr, URL= to stdout.
vcs_pr_create() {
  local out url
  out=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --head|--base|--title|--body) [ $# -ge 2 ] || { echo "squad: $1 requires a value" >&2; return 2; }
        out+=("$1" "$2"); shift 2 ;;
      *) echo "squad: pr-create: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  url="$(gh pr create "${out[@]}")" || { echo "squad: pr create failed" >&2; return 20; }
  printf '%s\n' "$url" >&2
  echo "URL=$(printf '%s\n' "$url" | tail -n 1)"
}
