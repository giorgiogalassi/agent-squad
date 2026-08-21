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
#   deps <worktree-path>
#                      Populate the worktree's dependency trees from the
#                      source checkout and report lockfile staleness.
#                      Mechanism only: reports staleness, never decides
#                      what to say about it, never runs an install.
#                      Prints one DEP=<relative-path>|<outcome>|<tier>|
#                      <seconds> line per discovered dependency tree
#                      (outcome: cloned|already-present|failed; tier:
#                      clonefile|reflink|plain|-), and one
#                      STALE=<relative-path>|<kind> line per staleness
#                      finding (kind: branch-drift|presence-diff|
#                      self-stale).
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
  echo "usage: worktree.sh create|path|remove <branch> | deps <worktree-path>" >&2
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

# --- deps helpers ---

LOCKFILES="package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb"

# Portable epoch mtime (NEW-18a). BSD `stat -f %m` prints the mtime, but
# on GNU coreutils `stat -f` selects *filesystem* status, where `%m` is
# the mount point — it exits 0 and prints a path, not an epoch, so a
# bare `stat -f %m "$1" || stat -c %Y "$1"` never reaches the GNU
# fallback. Try the BSD form, but validate its output is all digits
# before trusting it; fall back to the GNU form otherwise. Prints
# nothing and returns non-zero if neither produced a numeric value.
mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# Populate one dependency tree (e.g. node_modules) at $1 (relative to
# $ROOT) into the worktree at $2. Prints one DEP= line.
deps_populate_one() {
  rel="$1"
  wt="$2"
  src="$ROOT/$rel"
  target="$wt/$rel"
  tmp="${target}.sidecar-tmp"

  # Reuse check (NEW-18b): an existing, non-empty target is authoritative.
  # A stale tmp sibling is deleted, never re-entered into the copy path
  # (which would `mv` the tmp inside the existing target).
  if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    if [ -e "$tmp" ]; then
      rm -rf "$tmp"
    fi
    echo "DEP=$rel|already-present|-|0"
    return 0
  fi

  # Remove any leftover tmp before starting; never resume into one.
  if [ -e "$tmp" ]; then
    rm -rf "$tmp"
  fi

  mkdir -p "$(dirname "$target")" 2>/dev/null

  start="$(date +%s)"
  tier=""
  if cp -Rc "$src" "$tmp" 2>/dev/null; then
    tier="clonefile"
  elif cp -R --reflink=auto "$src" "$tmp" 2>/dev/null; then
    tier="reflink"
  elif cp -R "$src" "$tmp" 2>/dev/null; then
    tier="plain"
  fi
  end="$(date +%s)"
  elapsed=$((end - start))

  if [ -n "$tier" ] && mv "$tmp" "$target" 2>/dev/null; then
    echo "DEP=$rel|cloned|$tier|$elapsed"
  else
    rm -rf "$tmp"
    echo "DEP=$rel|failed|-|$elapsed"
  fi
}

# Lockfile staleness for the dependency tree at $1 (relative to $ROOT),
# comparing source checkout ($ROOT) against worktree $2. Prints zero or
# more STALE= lines. Comparison only: never installs, never decides
# wording.
deps_check_stale_one() {
  rel="$1"
  wt="$2"
  parent_rel="$(dirname "$rel")"
  src_parent="$ROOT/$parent_rel"
  wt_parent="$wt/$parent_rel"

  lockfile=""
  for name in $LOCKFILES; do
    if [ -f "$src_parent/$name" ] || [ -f "$wt_parent/$name" ]; then
      lockfile="$name"
      break
    fi
  done

  if [ -n "$lockfile" ]; then
    src_lf="$src_parent/$lockfile"
    wt_lf="$wt_parent/$lockfile"
    if [ -f "$src_lf" ] && [ -f "$wt_lf" ]; then
      if ! diff -q "$src_lf" "$wt_lf" >/dev/null 2>&1; then
        echo "STALE=$rel|branch-drift"
      fi
    elif [ -f "$src_lf" ] || [ -f "$wt_lf" ]; then
      echo "STALE=$rel|presence-diff"
    fi

    if [ -f "$src_lf" ] && [ -d "$ROOT/$rel" ]; then
      nm_mtime="$(mtime "$ROOT/$rel")"
      lf_mtime="$(mtime "$src_lf")"
      if [ -n "$nm_mtime" ] && [ -n "$lf_mtime" ] && [ "$lf_mtime" -gt "$nm_mtime" ]; then
        echo "STALE=$rel|self-stale"
      fi
    fi
  fi
}

cmd_deps() {
  wt="$1"

  if [ ! -d "$wt" ]; then
    echo "error: worktree path does not exist: $wt" >&2
    exit "$EXIT_ERROR"
  fi

  # Discover every node_modules in the source checkout, without
  # recursing into one once found. Prune both distributions' worktree
  # trees (NEW-18c) so another worktree's deps are never mistaken for
  # project deps.
  found="$(cd "$ROOT" && find . \( -name .git -o -path './.claude/worktrees' -o -path './.codex/worktrees' \) -prune \
    -o -type d -name node_modules -print -prune 2>/dev/null)"

  if [ -z "$found" ]; then
    exit "$EXIT_OK"
  fi

  # IFS is scoped to the `read` builtin only (not reassigned for the
  # loop body), so deps_check_stale_one's own word-splitting over
  # $LOCKFILES is unaffected — unlike a loop-wide `IFS=$'\n'`.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rel="${rel#./}"
    deps_populate_one "$rel" "$wt"
    deps_check_stale_one "$rel" "$wt"
  done <<EOF
$found
EOF

  exit "$EXIT_OK"
}

# --- dispatch ---

if [ "$#" -lt 2 ]; then
  usage
  exit "$EXIT_ERROR"
fi

sub="$1"
arg="$2"

if [ -z "$arg" ]; then
  usage
  exit "$EXIT_ERROR"
fi

case "$sub" in
  create) cmd_create "$arg" ;;
  path)   cmd_path "$arg" ;;
  remove) cmd_remove "$arg" ;;
  deps)   cmd_deps "$arg" ;;
  *)
    usage
    exit "$EXIT_ERROR"
    ;;
esac
