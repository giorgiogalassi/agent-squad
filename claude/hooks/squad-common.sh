#!/usr/bin/env bash
# squad-common.sh -- shared guard and output helpers for squad scripts.
# SOURCE this file; do not execute it. Bash 3.2 compatible. Contract:
# see SCRIPT_CONTRACT.md at the repo root.
#
# Functions that EXIT the calling script:   squad_fail
# Functions that RETURN a code (no exit):   squad_resolve, squad_gh_write,
#                                           squad_record_local, squad_emit,
#                                           squad_local_only, squad_public_name,
#                                           squad_vault_pr_mode, squad_vault_wt,
#                                           squad_vault_commit, squad_vault_finish
# Return codes: squad_resolve 0/20; squad_gh_write 0/20;
#   squad_record_local 0 changed / 1 unchanged / 20 I/O error;
#   squad_emit 0/2. The 1 is library-only, never a script exit code; callers
#   under `set -e` must guard it (`squad_record_local ... || rc=$?`).
#
# path-resolve.sh is located in the same directory as the file that
# sources this one, so it works from the repo and from the plugin root.

# Directory of the sourcing script (BASH_SOURCE[1] when sourced).
SQUAD_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"

# Directory of this file (squad-incidents.sh lives beside it).
SQUAD_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# squad_fail <code> <reason>: one stderr line, then exit <code>.
squad_fail() {
  local code="$1"; shift
  local reason
  reason="$(printf '%s' "$*" | tr '\n' ' ')"
  printf '%s\n' "$reason" >&2
  exit "$code"
}

# squad_incident <component> <exit> <reason> [kind]: record an incident via
# squad-incidents.sh (same dir as this file). Opt-in; silent, never fails,
# safe under set -e and before squad_resolve (store path has its own fallback).
squad_incident() {
  bash "$SQUAD_COMMON_DIR/squad-incidents.sh" record --source script \
    --kind "${4:-failure}" --component "${1:-}" --exit "${2:-}" --reason "${3:-}" \
    --project "${DISPLAY_NAME:-}" --session "${CLAUDE_SESSION_ID:-}" \
    >/dev/null 2>&1 || true
  return 0
}

# squad_fail_incident <component> <code> <reason>: squad_incident, then squad_fail.
squad_fail_incident() {
  squad_incident "$1" "$2" "$3"
  squad_fail "$2" "$3"
}

# squad_resolve: run path-resolve.sh and export VAULT_PATH, PROJECT_ROOT,
# DISPLAY_NAME, SQUAD_DIR, TRACKER_MODE. Returns 0, or 20 if resolution fails.
squad_resolve() {
  local out line key val
  unset TRACKER_MODE
  if ! out="$(bash "$SQUAD_HOOKS_DIR/path-resolve.sh" 2>/dev/null)"; then
    echo "squad: path-resolve.sh failed" >&2
    return 20
  fi
  while IFS= read -r line; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      VAULT_PATH|PROJECT_ROOT|DISPLAY_NAME|SQUAD_DIR|TRACKER_MODE)
        export "$key=$val" ;;
    esac
  done <<EOF2
$out
EOF2
  if [ -z "${TRACKER_MODE:-}" ]; then
    echo "squad: path-resolve.sh did not emit TRACKER_MODE" >&2
    return 20
  fi
  return 0
}

# squad_gh_write <argv...>: the ONLY place a mutating gh verb may run.
# Detached (or unresolved) mode: refuses, executes nothing, returns 20.
# Connected: runs `gh <argv>`; returns 0 on success, 20 on any gh failure
# (gh's own exit code is never passed through). gh stdout goes to stderr so
# stdout stays contract-only.
squad_gh_write() {
  if [ "${TRACKER_MODE:-}" != "connected" ]; then
    echo "squad: refused gh write in ${TRACKER_MODE:-unresolved} mode" >&2
    return 20
  fi
  if gh "$@" >&2; then
    return 0
  fi
  echo "squad: gh $1 failed" >&2
  return 20
}

# squad_record_local <handoff> <line>: append <line> to <handoff> unless an
# identical line is already present. Creates parent dirs.
# Returns 0 if appended (changed), 1 if already present (unchanged),
# 20 on I/O error.
squad_record_local() {
  local file="$1" line="$2"
  case "$line" in *'
'*) echo "squad: record line must be single-line" >&2; return 20 ;; esac
  mkdir -p "$(dirname "$file")" 2>/dev/null || { echo "squad: cannot create dir for $file" >&2; return 20; }
  if [ -f "$file" ] && grep -qxF -- "$line" "$file"; then
    return 1
  fi
  printf '%s\n' "$line" >> "$file" || { echo "squad: cannot write $file" >&2; return 20; }
  return 0
}

# squad_local_only <vault> <project>: 0 when the vault git-ignores the project
# folder (a local-only project, #351), so its name must stay out of tracked files.
squad_local_only() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  git -C "$1" check-ignore -q "projects/$2/status.md" >/dev/null 2>&1
}

# squad_shared_projects <vault>: project names on stdin, the non-local-only ones on
# stdout; one git call, since a fork per project breaks the vault-check time budget.
squad_shared_projects() {
  local names ign
  names="$(cat)"; [ -n "$names" ] || return 0
  ign="$(printf '%s\n' "$names" | sed 's|.*|projects/&/status.md|' \
    | git -C "$1" check-ignore --stdin 2>/dev/null | sed 's|^projects/||; s|/status.md$||')"
  [ -n "$ign" ] || { printf '%s\n' "$names"; return 0; }
  printf '%s\n' "$names" | grep -vxF "$ign"
  return 0
}

# squad_public_name <vault> <project>: the project name, or "local" when local-only.
squad_public_name() {
  if squad_local_only "$1" "$2"; then printf 'local'; else printf '%s' "$2"; fi
}

# --- vault commits (#350): the one owner of "where a vault write is committed" ---

# squad_vault_pr_mode <vault>: 0 when the vault's main cannot take direct commits:
# `"vault_main": "pr"` in lore-config.json, or (unless "direct") a pre-push hook that
# rejects refs/heads/<branch>. Only while the checkout sits on main/master. An
# explicit setting never runs the hook. A detected answer is cached per process and
# per day in <git-dir>/lore-pr-mode (keyed on the hook's checksum), and a detected
# PR mode is named on stderr once per process, so it never flips silently.
squad_vault_pr_mode() {
  local v="$1" cfg="$1/lore-config.json" br hook sha url key hk cf cached rc=0 day
  br="$(git -C "$v" symbolic-ref -q --short HEAD 2>/dev/null)" || return 1
  case "$br" in main|master) ;; *) return 1 ;; esac
  if [ -f "$cfg" ]; then
    grep -Eq '"vault_main"[[:space:]]*:[[:space:]]*"direct"' "$cfg" && return 1
    grep -Eq '"vault_main"[[:space:]]*:[[:space:]]*"pr"' "$cfg" && return 0
  fi
  hook="$(git -C "$v" rev-parse --git-path hooks/pre-push 2>/dev/null)"
  case "$hook" in /*) ;; *) hook="$v/$hook" ;; esac
  [ -x "$hook" ] || return 1
  hk="$(cksum < "$hook" 2>/dev/null | tr ' ' '-')"; key="$v|$br|$hk"; day="$(date +%Y-%m-%d)"
  if [ "${_SQUAD_PRM_KEY:-}" = "$key" ]; then return "$_SQUAD_PRM_RC"; fi
  cf="$(git -C "$v" rev-parse --git-path lore-pr-mode 2>/dev/null)"
  case "$cf" in /*) ;; *) cf="$v/$cf" ;; esac
  cached="$(sed -n "s/^$day $hk \([01]\)\$/\1/p" "$cf" 2>/dev/null | head -n 1)"
  if [ -n "$cached" ]; then
    rc="$cached"
  else
    sha="$(git -C "$v" rev-parse HEAD 2>/dev/null)" || return 1
    url="$(git -C "$v" remote get-url origin 2>/dev/null || echo origin)"
    if ( cd "$v" && printf 'refs/heads/%s %s refs/heads/%s 0000000000000000000000000000000000000000\n' "$br" "$sha" "$br" \
        | "$hook" origin "$url" ) >/dev/null 2>&1; then rc=1; else rc=0; fi
    printf '%s %s %s\n' "$day" "$hk" "$rc" > "$cf" 2>/dev/null
  fi
  _SQUAD_PRM_KEY="$key"; _SQUAD_PRM_RC="$rc"
  [ "$rc" = 0 ] && echo "squad: vault PR mode detected from the pre-push hook (it rejects $br); set \"vault_main\": \"pr\" or \"direct\" in lore-config.json to make it explicit" >&2
  return "$rc"
}

# squad_vault_landed <vault> <branch> [gh]: 0 when the branch's work already reached
# origin's main (merge, squash or rebase): its commits are ahead of main but every
# file it changed equals main's, or (gh given, connected) a merged PR has this tip
# as its head. A branch with no commits and a tip equal to main is empty, not landed.
squad_vault_landed() {
  local v="$1" b="$2" br0 base n tip mb f any=0 oid
  br0="$(git -C "$v" symbolic-ref -q --short HEAD)" || return 1
  base="$br0"; git -C "$v" rev-parse -q --verify "origin/$br0" >/dev/null 2>&1 && base="origin/$br0"
  tip="$(git -C "$v" rev-parse -q --verify "refs/heads/$b")" || return 1
  n="$(git -C "$v" rev-list --count "$base..$b" 2>/dev/null)"
  if [ "${n:-0}" -eq 0 ]; then
    [ "$tip" != "$(git -C "$v" rev-parse "$base")" ]; return
  fi
  if [ "${3:-}" = gh ]; then
    oid="$(cd "$v" && gh pr list --head "$b" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null)"
    case "
$oid
" in *"
$tip
"*) return 0 ;; esac
  fi
  mb="$(git -C "$v" merge-base "$base" "$b" 2>/dev/null)" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    [ "$(git -C "$v" rev-parse -q --verify "$b:$f" 2>/dev/null)" = "$(git -C "$v" rev-parse -q --verify "$base:$f" 2>/dev/null)" ] || return 1
  done <<EOL
$(git -C "$v" diff --name-only "$mb" "$b" 2>/dev/null)
EOL
  [ "$any" = 1 ]
}

# squad_vault_drop <vault> <worktree> <branch>: remove a landed session worktree and
# its local branch. Never forced: uncommitted changes make it refuse (returns 1).
squad_vault_drop() {
  git -C "$1" worktree remove "$2" >/dev/null 2>&1 \
    || { echo "squad: $3 already landed but $2 has uncommitted changes; left in place" >&2; return 1; }
  git -C "$1" branch -D "$3" >/dev/null 2>&1
  return 0
}

# squad_vault_level <vault> <main> <branch> <worktree>: when local main is strictly
# ahead of origin/main (origin is an ancestor), make sure the session branch holds
# main's tip (merged inside its worktree; a conflict is aborted and main left as is),
# then level main with `reset --keep`, which refuses rather than touch uncommitted
# work (main then stays ahead and the next call retries). A diverged main is untouched.
squad_vault_level() {
  local v="$1" m="$2" b="$3" wt="$4" _id=""
  git -C "$v" rev-parse -q --verify "origin/$m" >/dev/null 2>&1 || return 0
  [ "$(git -C "$v" rev-parse "$m")" != "$(git -C "$v" rev-parse "origin/$m")" ] || return 0
  git -C "$v" merge-base --is-ancestor "origin/$m" "$m" 2>/dev/null || return 0
  if ! git -C "$v" merge-base --is-ancestor "$m" "$b" 2>/dev/null; then
    git -C "$wt" config user.name >/dev/null 2>&1 || _id="$_id -c user.name=lore"
    git -C "$wt" config user.email >/dev/null 2>&1 || _id="$_id -c user.email=lore@localhost"
    # shellcheck disable=SC2086
    if ! git -C "$wt" $_id merge -q --no-edit "$m" >/dev/null 2>&1; then
      git -C "$wt" merge --abort >/dev/null 2>&1
      echo "squad: vault $m is ahead of origin but merging it into $b conflicts; left as is" >&2
      return 0
    fi
  fi
  git -C "$v" reset -q --keep "origin/$m" >/dev/null 2>&1 \
    || echo "squad: vault $m is ahead of origin and could not be levelled (uncommitted changes); its commits are on $b" >&2
  return 0
}

# squad_vault_wt <vault> <project>: print the session worktree (lore-<name>-<date>
# on branch lore/<name>-<date>), creating it from origin's main when absent. When
# that day's branch already landed (merged), later writes use lore/<name>-<date>-2,
# -3, ... so a merged branch is never reused.
squad_vault_wt() {
  local v="$1" pub d br0 base b wt ex i=1 sfx
  pub="$(squad_public_name "$v" "${2:-vault}" | tr -c 'A-Za-z0-9._-' '-')"
  d="$(date +%Y-%m-%d)"
  br0="$(git -C "$v" symbolic-ref -q --short HEAD)" || return 1
  while :; do
    sfx=""; [ "$i" -gt 1 ] && sfx="-$i"
    b="lore/$pub-$d$sfx"; wt="$v/.claude/worktrees/lore-$pub-$d$sfx"
    if git -C "$v" show-ref -q --verify "refs/heads/$b"; then
      # Pushed before: the PR may have merged meanwhile, so look at origin again.
      if git -C "$v" show-ref -q --verify "refs/remotes/origin/$b"; then
        git -C "$v" fetch -q --prune origin >/dev/null 2>&1
      fi
      if squad_vault_landed "$v" "$b"; then i=$((i+1)); continue; fi
    fi
    break
  done
  if [ ! -d "$wt" ]; then
    git -C "$v" remote get-url origin >/dev/null 2>&1 && git -C "$v" fetch -q origin >/dev/null 2>&1
    base="$br0"; git -C "$v" rev-parse -q --verify "origin/$br0" >/dev/null 2>&1 && base="origin/$br0"
    mkdir -p "$v/.claude/worktrees" || return 1
    # Without this the worktrees show up as untracked vault changes.
    ex="$(git -C "$v" rev-parse --git-path info/exclude)"; case "$ex" in /*) ;; *) ex="$v/$ex" ;; esac
    grep -qxF '.claude/worktrees/' "$ex" 2>/dev/null || { mkdir -p "$(dirname "$ex")"; echo '.claude/worktrees/' >> "$ex"; }
    if git -C "$v" show-ref -q --verify "refs/heads/$b"; then
      git -C "$v" worktree add -q "$wt" "$b" >/dev/null 2>&1 || return 1
    else
      git -C "$v" worktree add -q -b "$b" "$wt" "$base" >/dev/null 2>&1 || return 1
    fi
  fi
  squad_vault_level "$v" "$br0" "$b" "$wt"
  printf '%s' "$wt"
}

# squad_vault_commit <vault> <project> <message> <path>...: commit vault-relative
# paths by pathspec. Direct mode commits in the vault. PR mode moves the written
# files onto the session branch (3-way merged with that branch's earlier commits),
# restores them in the main checkout and commits there, so main stays level with
# origin. Never fails the caller; on a worktree failure the change stays uncommitted.
squad_vault_commit() {
  local v="$1" proj="$2" msg="$3" root="$1" wt p base ours _id=""
  shift 3
  git -C "$v" rev-parse --git-dir >/dev/null 2>&1 || return 0
  if ! squad_local_only "$v" "$proj" && squad_vault_pr_mode "$v"; then
    wt="$(squad_vault_wt "$v" "$proj")" || { echo "squad: vault worktree failed; change left uncommitted" >&2; return 1; }
    base="$wt.base.$$"; ours="$wt.ours.$$"
    for p in "$@"; do
      [ -f "$v/$p" ] || continue
      mkdir -p "$(dirname "$wt/$p")"
      git -C "$v" show "HEAD:$p" > "$base" 2>/dev/null || : > "$base"
      if [ -f "$wt/$p" ] && ! cmp -s "$wt/$p" "$base" && ! cmp -s "$wt/$p" "$v/$p"; then
        cp "$wt/$p" "$ours"
        if ! git merge-file -p "$ours" "$base" "$v/$p" > "$wt/$p" 2>/dev/null; then
          # Append-only logs keep both sides; rewritten files take the newest write.
          case "$p" in
            */decisions.md|*/decisions-archive.md|*/progress.txt|*/session.log)
              git merge-file -p --union "$ours" "$base" "$v/$p" > "$wt/$p.m" 2>/dev/null; mv "$wt/$p.m" "$wt/$p" ;;
            *) cp "$v/$p" "$wt/$p" ;;
          esac
        fi
      else
        cp "$v/$p" "$wt/$p"
      fi
      if git -C "$v" cat-file -e "HEAD:$p" 2>/dev/null; then git -C "$v" checkout -q HEAD -- "$p" >/dev/null 2>&1; else rm -f "$v/$p"; fi
    done
    rm -f "$base" "$ours"
    root="$wt"
  fi
  git -C "$root" add -- "$@" >/dev/null 2>&1
  # No git identity (fresh CI runner) would fail the commit silently.
  git -C "$root" config user.name >/dev/null 2>&1 || _id="$_id -c user.name=lore"
  git -C "$root" config user.email >/dev/null 2>&1 || _id="$_id -c user.email=lore@localhost"
  # shellcheck disable=SC2086
  git -C "$root" $_id commit -q -m "$msg" -- "$@" >/dev/null 2>&1 || true
  return 0
}

# squad_vault_finish <vault>: push each lore/* session branch that is ahead of main
# and open its PR (an open one is updated by the push). Branches whose work already
# landed are dropped (worktree and local branch) instead of pushed. Gated on the
# vault's PR mode and an origin remote, not on TRACKER_MODE: the vault is the user's
# own repo, so pushing to it is not a tracker write (hence plain gh, not squad_gh_write). Sets SQUAD_VAULT_PUSHED to the number of pushes plus PRs created.
# A branch of a local-only project (#351) is never pushed; the project is read from each
# branch name (lore/<project>-<YYYY-MM-DD>[-N]), not from the caller. Without gh on PATH the
# branch is still pushed and one stderr notice names the manual step: not a failure.
# Returns 0 done or nothing to do, 20 on push failure or a failure of a present gh.
squad_vault_finish() {
  local v="$1" wt b bproj br0 base n open tip rtip rc=0 hasgh=1 url
  SQUAD_VAULT_PUSHED=0
  command -v gh >/dev/null 2>&1 || hasgh=0
  squad_vault_pr_mode "$v" || return 0
  git -C "$v" remote get-url origin >/dev/null 2>&1 || return 0
  br0="$(git -C "$v" symbolic-ref -q --short HEAD)" || return 0
  git -C "$v" fetch -q --prune origin >/dev/null 2>&1
  base="$br0"; git -C "$v" rev-parse -q --verify "origin/$br0" >/dev/null 2>&1 && base="origin/$br0"
  for wt in "$v"/.claude/worktrees/lore-*; do
    [ -d "$wt" ] || continue
    b="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)"
    case "$b" in lore/*) ;; *) continue ;; esac
    bproj="$(printf '%s' "${b#lore/}" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?$//')"
    squad_local_only "$v" "$bproj" && continue
    if squad_vault_landed "$v" "$b" "$([ "$hasgh" = 1 ] && echo gh)"; then squad_vault_drop "$v" "$wt" "$b" || rc=20; continue; fi
    n="$(git -C "$v" rev-list --count "$base..$b" 2>/dev/null)"
    [ "${n:-0}" -gt 0 ] || continue
    tip="$(git -C "$v" rev-parse "refs/heads/$b")"
    rtip="$(git -C "$v" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null)"
    if [ "$tip" != "$rtip" ]; then
      git -C "$wt" push -q -u origin "$b" >&2 || { echo "squad: push of $b failed" >&2; rc=20; continue; }
      SQUAD_VAULT_PUSHED=$((SQUAD_VAULT_PUSHED+1))
    fi
    if [ "$hasgh" = 0 ]; then
      url="$(git -C "$v" remote get-url origin | sed -n 's|^git@github.com:\(.*\)$|https://github.com/\1|p; s|^\(https://github.com/.*\)$|\1|p' | sed 's|\.git$||')"
      echo "squad: gh not found; $b pushed, open its PR manually${url:+: $url/compare/$br0...$b}" >&2
      continue
    fi
    open="$(cd "$v" && gh pr list --head "$b" --state open --json number --jq '.[0].number // empty' 2>/dev/null)"
    case "$open" in ''|*[!0-9]*) ;; *) continue ;; esac
    ( cd "$v" && gh pr create --head "$b" --base "$br0" --title "lore: ${b#lore/}" \
        --body "Vault changes written by Lore during one session ($n commit(s))." >&2 ) \
      && SQUAD_VAULT_PUSHED=$((SQUAD_VAULT_PUSHED+1)) || rc=20
  done
  return "$rc"
}

# squad_emit KEY value: print KEY=value on stdout. KEY must match
# ^[A-Z_]+$ ([[:upper:]] class: a-z range globs accept lowercase under UTF-8
# locales in bash 3.2), value must be single-line; backslash is escaped as \\.
# Returns 0, or 2 (with a stderr reason) on invalid input.
squad_emit() {
  local key="${1:-}" val="${2-}"
  case "$key" in
    ''|*[![:upper:]_]*) echo "squad: invalid output key '$key'" >&2; return 2 ;;
  esac
  case "$val" in *'
'*) echo "squad: multi-line value for $key" >&2; return 2 ;; esac
  case "$val" in *$'\r'*) echo "squad: CR in value for $key" >&2; return 2 ;; esac
  val="$(printf '%s' "$val" | sed 's/\\/\\\\/g')"
  printf '%s=%s\n' "$key" "$val"
}
