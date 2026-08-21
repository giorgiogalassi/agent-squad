#!/usr/bin/env bash
# Worktree lifecycle hook, shared by Sidecar today and Ralph's future
# epic mode. Extracts the create/path/remove mechanics that used to be
# spread through Sidecar's skill prose into an executable, testable
# contract.
#
# This is mechanism only, not policy (same boundary path-resolve.sh
# documents): this script decides nothing about *when* to warn a user,
# what wording to print, what needs confirmation, or when to refuse a
# force-remove over uncommitted work. It only resolves paths, creates
# and removes worktrees, and reports outcomes. Callers (Sidecar, Ralph)
# own all of that policy.
#
# The hook resolves its own project root by invoking path-resolve.sh
# (expected next to this script) and never calls
# `git rev-parse --show-toplevel`, which returns a linked worktree's own
# directory when run from inside one — the exact bug this extraction
# exists to close.
#
# Worktree location: <project-root>/.claude/worktrees/<branch-slug>/,
# with `/` replaced by `-` in the slug. Matches Claude Code's own
# native worktree layout.
#
# Output: KEY=VALUE lines on stdout, following path-resolve.sh's
# convention. Exit codes: 0 success; 1 a refusal the caller must
# surface to the user (never forced past); 2 an internal error (a bug,
# not a policy decision).
#
# Subcommands:
#   create <branch>   Create (or reuse) the worktree for <branch>.
#                      Prints WORKTREE_PATH=<absolute> and
#                      WORKTREE_CREATED=true|false.
#   path <branch>     Print WORKTREE_PATH=<absolute> for <branch>
#                      without creating anything.
#   remove <branch>   Remove the worktree for <branch>, deleting only
#                      generated trees it can name by path (node_modules,
#                      *.sidecar-tmp). Refuses (exit 1, never --force)
#                      if the worktree has uncommitted tracked changes.
#                      Prints REMOVED=true|false and CLEANED=<paths>.
#
# Depends only on git and POSIX shell utilities. No jq.
#
# Install (Claude Code): copy to ~/.claude/hooks/worktree.sh, chmod +x,
# alongside ~/.claude/hooks/path-resolve.sh (this script invokes it as
# a sibling file).

set -u

EXIT_OK=0
EXIT_REFUSAL=1
EXIT_ERROR=2

usage() {
  echo "usage: worktree.sh create|path|remove <branch>" >&2
}

# --- resolve PROJECT_ROOT via path-resolve.sh (never git rev-parse --show-toplevel) ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATH_RESOLVE="$SCRIPT_DIR/path-resolve.sh"

if [ ! -f "$PATH_RESOLVE" ]; then
  echo "error: path-resolve.sh not found next to worktree.sh (expected $PATH_RESOLVE)" >&2
  exit "$EXIT_ERROR"
fi

RESOLVED="$("$PATH_RESOLVE" 2>/dev/null)"
ROOT="$(printf '%s\n' "$RESOLVED" | sed -n 's/^PROJECT_ROOT=//p')"

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "error: could not resolve PROJECT_ROOT (not a git repo?)" >&2
  exit "$EXIT_ERROR"
fi

# --- helpers ---

slug_for() {
  # Replace '/' with '-' in a branch name to form a filesystem-safe slug.
  printf '%s' "$1" | tr '/' '-'
}

worktree_path_for() {
  printf '%s/.claude/worktrees/%s' "$ROOT" "$(slug_for "$1")"
}

# Print the worktree path (if any) that already has <branch> checked out.
find_worktree_for_branch() {
  branch="$1"
  git -C "$ROOT" worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/$branch" '
    /^worktree / { path = substr($0, 10) }
    /^branch /   { if ($0 == "branch " want) print path }
  '
}

is_registered_worktree() {
  target="$1"
  git -C "$ROOT" worktree list --porcelain 2>/dev/null | awk -v want="$target" '
    /^worktree / { if (substr($0, 10) == want) found = 1 }
    END { exit found ? 0 : 1 }
  '
}

add_gitignore_entry() {
  gi="$ROOT/.gitignore"
  entry=".claude/worktrees/"
  if [ -f "$gi" ] && grep -qxF "$entry" "$gi" 2>/dev/null; then
    return 0
  fi
  if [ -f "$gi" ] && [ -s "$gi" ]; then
    printf '\n# Agent Squad worktrees (claude/hooks/worktree.sh)\n%s\n' "$entry" >> "$gi"
  else
    printf '# Agent Squad worktrees (claude/hooks/worktree.sh)\n%s\n' "$entry" >> "$gi"
  fi
}

# --- subcommands ---

cmd_create() {
  branch="$1"
  target="$(worktree_path_for "$branch")"

  existing="$(find_worktree_for_branch "$branch")"
  if [ -n "$existing" ]; then
    if [ "$existing" = "$target" ]; then
      # Idempotent re-create: fetch and verify the checked-out branch matches.
      if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
        git -C "$ROOT" fetch origin "$branch" --quiet 2>/dev/null || true
      fi
      current="$(git -C "$target" symbolic-ref --quiet --short HEAD 2>/dev/null)"
      if [ "$current" != "$branch" ]; then
        echo "error: worktree at $target no longer has '$branch' checked out (found '$current')" >&2
        exit "$EXIT_ERROR"
      fi
      echo "WORKTREE_PATH=$target"
      echo "WORKTREE_CREATED=false"
      exit "$EXIT_OK"
    else
      echo "refusal: branch '$branch' is already checked out at $existing" >&2
      exit "$EXIT_REFUSAL"
    fi
  fi

  if [ -e "$target" ]; then
    echo "error: $target already exists but is not a registered worktree for '$branch'" >&2
    exit "$EXIT_ERROR"
  fi

  mkdir -p "$(dirname "$target")" || {
    echo "error: could not create $(dirname "$target")" >&2
    exit "$EXIT_ERROR"
  }

  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$ROOT" worktree add "$target" "$branch" >/dev/null 2>&1
  elif git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$ROOT" worktree add "$target" -b "$branch" "origin/$branch" >/dev/null 2>&1
  else
    git -C "$ROOT" worktree add "$target" -b "$branch" >/dev/null 2>&1
  fi
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "error: git worktree add failed for '$branch'" >&2
    exit "$EXIT_ERROR"
  fi

  add_gitignore_entry

  echo "WORKTREE_PATH=$target"
  echo "WORKTREE_CREATED=true"
  exit "$EXIT_OK"
}

cmd_path() {
  branch="$1"
  target="$(worktree_path_for "$branch")"
  echo "WORKTREE_PATH=$target"
  exit "$EXIT_OK"
}

cmd_remove() {
  branch="$1"
  target="$(worktree_path_for "$branch")"

  if [ ! -d "$target" ]; then
    echo "REMOVED=false"
    echo "CLEANED="
    exit "$EXIT_OK"
  fi

  if ! is_registered_worktree "$target"; then
    echo "error: $target is not a registered git worktree" >&2
    exit "$EXIT_ERROR"
  fi

  # Refuse on any uncommitted change to a tracked file. Untracked
  # generated trees (node_modules, *.sidecar-tmp) are handled below and
  # do not block removal.
  dirty="$(git -C "$target" status --porcelain --untracked-files=no 2>/dev/null)"
  if [ -n "$dirty" ]; then
    echo "refusal: worktree at $target has uncommitted tracked changes" >&2
    echo "REMOVED=false"
    echo "CLEANED="
    exit "$EXIT_REFUSAL"
  fi

  cleaned=""
  # Only ever delete generated trees this script can name by path.
  # Never a blanket force over the worktree's untracked content.
  find_output="$(find "$target" -mindepth 1 \( -name node_modules -o -name '*.sidecar-tmp' \) -type d 2>/dev/null)"
  if [ -n "$find_output" ]; then
    old_ifs="$IFS"
    IFS='
'
    for p in $find_output; do
      [ -n "$p" ] || continue
      rm -rf "$p"
      if [ -z "$cleaned" ]; then
        cleaned="$p"
      else
        cleaned="$cleaned,$p"
      fi
    done
    IFS="$old_ifs"
  fi

  if git -C "$ROOT" worktree remove "$target" >/dev/null 2>&1; then
    echo "REMOVED=true"
    echo "CLEANED=$cleaned"
    exit "$EXIT_OK"
  else
    echo "refusal: git worktree remove refused $target (untracked content remains); never forced" >&2
    echo "REMOVED=false"
    echo "CLEANED=$cleaned"
    exit "$EXIT_REFUSAL"
  fi
}

# --- dispatch ---

if [ "$#" -lt 2 ]; then
  usage
  exit "$EXIT_ERROR"
fi

sub="$1"
branch="$2"

if [ -z "$branch" ]; then
  usage
  exit "$EXIT_ERROR"
fi

case "$sub" in
  create) cmd_create "$branch" ;;
  path)   cmd_path "$branch" ;;
  remove) cmd_remove "$branch" ;;
  *)
    usage
    exit "$EXIT_ERROR"
    ;;
esac
