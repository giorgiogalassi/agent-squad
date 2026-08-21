#!/usr/bin/env bash
# Executable test harness for claude/hooks/worktree.sh.
#
# The repo has no build system and no test suite; correctness has been
# verified by prose review. worktree.sh is the first artifact where that
# is not good enough -- NEW-18a is the proof: a defective `stat`
# invocation survived two rounds of review, and a rewrite corrected the
# comment above it while leaving the bug in place. This script makes the
# hook's contract executable instead of asserted in prose.
#
# Usage: scripts/test-worktree.sh [path/to/worktree.sh]
#   With no argument, tests the real claude/hooks/worktree.sh next to
#   this checkout. An override path may be given to run the same suite
#   against a deliberately broken copy (used to verify each criterion
#   actually fails when violated); the override's directory must contain
#   its own path-resolve.sh sibling, same as the real hook expects.
#
# Every fixture is a fresh git repository built under a single mktemp -d
# root, removed unconditionally on exit (including a failure partway
# through). No network access. No dependency on the state of the
# developer's own checkout: nothing here reads or writes outside the
# temp root except the worktree.sh under test itself, which never
# touches anything outside the fixture repos it is pointed at.
#
# No new external dependency -- plain bash, git, coreutils/BSD stat,
# find, diff. No bats, no jq.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_WT="$REPO_ROOT/claude/hooks/worktree.sh"
WT="${1:-$DEFAULT_WT}"

if [ ! -f "$WT" ]; then
  echo "error: worktree.sh not found at $WT" >&2
  exit 2
fi
WT="$(cd "$(dirname "$WT")" && pwd)/$(basename "$WT")"
WT_DIR="$(dirname "$WT")"
if [ ! -f "$WT_DIR/path-resolve.sh" ]; then
  echo "error: $WT_DIR has no path-resolve.sh sibling (worktree.sh requires one)" >&2
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-worktree.XXXXXX")"
# Canonicalize: on macOS /tmp is a symlink into /private/var, and git
# resolves worktree paths through it, so raw mktemp output and git's
# reported paths would otherwise disagree on every comparison.
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT INT TERM

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s -- %s\n' "$1" "$2"
}

# Build a fresh throwaway git repo for one test case and print its path.
# A fresh fixture per case matters: reusing one after mutation produces
# false greens (this bit a prior verification pass on #108).
fresh() {
  case_name="$1"
  d="$(mktemp -d "$TMPROOT/fix-$case_name.XXXXXX")"
  git -C "$d" init -q -b main >/dev/null 2>&1
  git -C "$d" config user.email "test@example.invalid"
  git -C "$d" config user.name "Test Harness"
  git -C "$d" config commit.gpgsign false
  echo "fixture" >"$d/README.md"
  git -C "$d" add README.md >/dev/null 2>&1
  git -C "$d" commit -q -m init >/dev/null 2>&1
  printf '%s\n' "$d"
}

# Invoke worktree.sh with cwd set to the fixture repo, since
# path-resolve.sh resolves PROJECT_ROOT from the caller's cwd.
run_hook() {
  repo="$1"
  shift
  (cd "$repo" && "$WT" "$@")
}

# ---------------------------------------------------------------------
# create
# ---------------------------------------------------------------------

test_create_basic() {
  repo="$(fresh create-basic)"
  out="$(run_hook "$repo" create feat-a 2>"$TMPROOT/err")"
  rc=$?
  err="$(cat "$TMPROOT/err")"
  wt_path="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_PATH=//p')"
  created="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_CREATED=//p')"

  if [ "$rc" = "0" ]; then pass "CREATE-1-exit-zero"; else fail "CREATE-1-exit-zero" "rc=$rc err=[$err]"; fi
  case "$wt_path" in
    /*) pass "CREATE-1-absolute-path" ;;
    *) fail "CREATE-1-absolute-path" "WORKTREE_PATH=[$wt_path] is not absolute" ;;
  esac
  if [ "$created" = "true" ]; then pass "CREATE-1-created-true"; else fail "CREATE-1-created-true" "WORKTREE_CREATED=[$created]"; fi
  if [ -d "$wt_path" ]; then pass "CREATE-1-dir-exists"; else fail "CREATE-1-dir-exists" "$wt_path does not exist"; fi
}

test_create_idempotent() {
  repo="$(fresh create-idempotent)"
  out1="$(run_hook "$repo" create feat-b 2>"$TMPROOT/err1")"
  path1="$(printf '%s\n' "$out1" | sed -n 's/^WORKTREE_PATH=//p')"
  # Mark the worktree so we can detect any modification on re-create.
  echo "sentinel" >"$path1/sentinel-file"
  sentinel_before="$(cat "$path1/sentinel-file" 2>/dev/null)"

  out2="$(run_hook "$repo" create feat-b 2>"$TMPROOT/err2")"
  rc2=$?
  err2="$(cat "$TMPROOT/err2")"
  path2="$(printf '%s\n' "$out2" | sed -n 's/^WORKTREE_PATH=//p')"
  created2="$(printf '%s\n' "$out2" | sed -n 's/^WORKTREE_CREATED=//p')"
  sentinel_after="$(cat "$path1/sentinel-file" 2>/dev/null)"

  if [ "$rc2" = "0" ]; then pass "CREATE-2-exit-zero"; else fail "CREATE-2-exit-zero" "rc=$rc2 err=[$err2]"; fi
  if [ "$path2" = "$path1" ]; then pass "CREATE-2-same-path"; else fail "CREATE-2-same-path" "first=[$path1] second=[$path2]"; fi
  if [ "$created2" = "false" ]; then pass "CREATE-2-created-false"; else fail "CREATE-2-created-false" "WORKTREE_CREATED=[$created2]"; fi
  if [ "$sentinel_after" = "$sentinel_before" ]; then pass "CREATE-2-not-modified"; else fail "CREATE-2-not-modified" "sentinel file changed: before=[$sentinel_before] after=[$sentinel_after]"; fi
}

test_create_branch_elsewhere() {
  repo="$(fresh create-elsewhere)"
  git -C "$repo" branch feat-c >/dev/null 2>&1
  other="$TMPROOT/elsewhere-$$"
  git -C "$repo" worktree add -q "$other" feat-c >/dev/null 2>&1

  out="$(run_hook "$repo" create feat-c 2>"$TMPROOT/err")"
  rc=$?
  err="$(cat "$TMPROOT/err")"
  target="$repo/.claude/worktrees/feat-c"

  if [ "$rc" = "1" ]; then pass "CREATE-3-exit-one"; else fail "CREATE-3-exit-one" "rc=$rc err=[$err]"; fi
  case "$err" in
    *"$other"*) pass "CREATE-3-names-other-checkout" ;;
    *) fail "CREATE-3-names-other-checkout" "stderr=[$err] does not mention $other" ;;
  esac
  if [ ! -e "$target" ]; then pass "CREATE-3-no-forced-target"; else fail "CREATE-3-no-forced-target" "$target was created despite refusal"; fi
}

test_create_gitignore_once() {
  repo="$(fresh create-gitignore)"
  run_hook "$repo" create feat-d >/dev/null 2>"$TMPROOT/err1"
  run_hook "$repo" create feat-e >/dev/null 2>"$TMPROOT/err2"
  run_hook "$repo" create feat-d >/dev/null 2>"$TMPROOT/err3"

  count="$(grep -cxF '.claude/worktrees/' "$repo/.gitignore" 2>/dev/null || true)"
  if [ "$count" = "1" ]; then pass "CREATE-4-gitignore-once"; else fail "CREATE-4-gitignore-once" "expected exactly one entry, found $count in $repo/.gitignore"; fi
}

test_create_slash_slug() {
  repo="$(fresh create-slash)"
  out="$(run_hook "$repo" create feature/nested-thing 2>"$TMPROOT/err")"
  rc=$?
  err="$(cat "$TMPROOT/err")"
  wt_path="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_PATH=//p')"
  expected="$repo/.claude/worktrees/feature-nested-thing"

  if [ "$rc" = "0" ]; then pass "CREATE-5-exit-zero"; else fail "CREATE-5-exit-zero" "rc=$rc err=[$err]"; fi
  if [ "$wt_path" = "$expected" ]; then pass "CREATE-5-slash-slugged"; else fail "CREATE-5-slash-slugged" "expected [$expected] got [$wt_path]"; fi
}

# ---------------------------------------------------------------------
# path
# ---------------------------------------------------------------------

test_path_matches_create() {
  repo="$(fresh path-matches-create)"
  create_out="$(run_hook "$repo" create feat-f 2>"$TMPROOT/err1")"
  create_path="$(printf '%s\n' "$create_out" | sed -n 's/^WORKTREE_PATH=//p')"

  path_out="$(run_hook "$repo" path feat-f 2>"$TMPROOT/err2")"
  rc=$?
  err2="$(cat "$TMPROOT/err2")"
  path_path="$(printf '%s\n' "$path_out" | sed -n 's/^WORKTREE_PATH=//p')"

  if [ "$rc" = "0" ]; then pass "PATH-1-exit-zero"; else fail "PATH-1-exit-zero" "rc=$rc err=[$err2]"; fi
  if [ "$path_path" = "$create_path" ]; then pass "PATH-1-matches-create"; else fail "PATH-1-matches-create" "create=[$create_path] path=[$path_path]"; fi
}

# ---------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------

test_remove_cleans_generated_trees() {
  repo="$(fresh remove-cleans)"
  out="$(run_hook "$repo" create feat-g 2>"$TMPROOT/err0")"
  wt_path="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_PATH=//p')"
  mkdir -p "$wt_path/node_modules/pkg" "$wt_path/build.sidecar-tmp"
  echo x >"$wt_path/node_modules/pkg/index.js"
  echo x >"$wt_path/build.sidecar-tmp/junk"

  out="$(run_hook "$repo" remove feat-g 2>"$TMPROOT/err")"
  rc=$?
  err="$(cat "$TMPROOT/err")"
  removed="$(printf '%s\n' "$out" | sed -n 's/^REMOVED=//p')"
  cleaned="$(printf '%s\n' "$out" | sed -n 's/^CLEANED=//p')"

  if [ "$rc" = "0" ]; then pass "REMOVE-1-exit-zero"; else fail "REMOVE-1-exit-zero" "rc=$rc err=[$err]"; fi
  if [ "$removed" = "true" ]; then pass "REMOVE-1-removed-true"; else fail "REMOVE-1-removed-true" "REMOVED=[$removed]"; fi
  case "$cleaned" in
    *node_modules*) pass "REMOVE-1-cleaned-names-node-modules" ;;
    *) fail "REMOVE-1-cleaned-names-node-modules" "CLEANED=[$cleaned] does not name node_modules" ;;
  esac
  case "$cleaned" in
    *.sidecar-tmp*) pass "REMOVE-1-cleaned-names-sidecar-tmp" ;;
    *) fail "REMOVE-1-cleaned-names-sidecar-tmp" "CLEANED=[$cleaned] does not name *.sidecar-tmp" ;;
  esac
  if [ ! -d "$wt_path" ]; then pass "REMOVE-1-worktree-gone"; else fail "REMOVE-1-worktree-gone" "$wt_path still exists"; fi
}

test_remove_refuses_on_uncommitted_tracked() {
  repo="$(fresh remove-refuses)"
  out="$(run_hook "$repo" create feat-h 2>"$TMPROOT/err0")"
  wt_path="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_PATH=//p')"
  echo "dirty" >>"$wt_path/README.md"

  out="$(run_hook "$repo" remove feat-h 2>"$TMPROOT/err")"
  rc=$?
  err="$(cat "$TMPROOT/err")"
  removed="$(printf '%s\n' "$out" | sed -n 's/^REMOVED=//p')"
  cleaned="$(printf '%s\n' "$out" | sed -n 's/^CLEANED=//p')"

  if [ "$rc" = "1" ]; then pass "REMOVE-2-exit-one"; else fail "REMOVE-2-exit-one" "rc=$rc err=[$err]"; fi
  if [ "$removed" = "false" ]; then pass "REMOVE-2-removed-false"; else fail "REMOVE-2-removed-false" "REMOVED=[$removed]"; fi
  if [ -z "$cleaned" ]; then pass "REMOVE-2-nothing-cleaned"; else fail "REMOVE-2-nothing-cleaned" "CLEANED=[$cleaned], expected empty"; fi
  if [ -d "$wt_path" ]; then pass "REMOVE-2-worktree-still-present"; else fail "REMOVE-2-worktree-still-present" "$wt_path was removed despite refusal"; fi
  content="$(cat "$wt_path/README.md" 2>/dev/null)"
  case "$content" in
    *dirty*) pass "REMOVE-2-content-untouched" ;;
    *) fail "REMOVE-2-content-untouched" "README.md content=[$content] lost the uncommitted change" ;;
  esac
  case "$err" in
    *--force*) fail "REMOVE-2-never-force" "stderr mentions --force: [$err]" ;;
    *) pass "REMOVE-2-never-force" ;;
  esac
}

test_remove_succeeds_on_foreign_worktree() {
  repo="$(fresh remove-foreign)"
  git -C "$repo" branch feat-i >/dev/null 2>&1
  target="$repo/.claude/worktrees/feat-i"
  mkdir -p "$(dirname "$target")"
  git -C "$repo" worktree add -q "$target" feat-i >/dev/null 2>&1
  # This worktree was never created via the hook, so no .gitignore entry
  # exists for it.
  gitignore_before="$([ -f "$repo/.gitignore" ] && cat "$repo/.gitignore" || echo "")"

  out="$(run_hook "$repo" remove feat-i 2>"$TMPROOT/err")"
  rc=$?
  err="$(cat "$TMPROOT/err")"
  removed="$(printf '%s\n' "$out" | sed -n 's/^REMOVED=//p')"

  if [ "$rc" = "0" ]; then pass "REMOVE-3-exit-zero"; else fail "REMOVE-3-exit-zero" "rc=$rc err=[$err] gitignore-before=[$gitignore_before]"; fi
  if [ "$removed" = "true" ]; then pass "REMOVE-3-removed-true"; else fail "REMOVE-3-removed-true" "REMOVED=[$removed]"; fi
  if [ ! -d "$target" ]; then pass "REMOVE-3-worktree-gone"; else fail "REMOVE-3-worktree-gone" "$target still exists"; fi
}

# ---------------------------------------------------------------------
# deps
# ---------------------------------------------------------------------

test_deps_prunes_both_worktree_trees() {
  repo="$(fresh deps-prune)"
  mkdir -p "$repo/node_modules/real-pkg"
  echo "real" >"$repo/node_modules/real-pkg/index.js"
  mkdir -p "$repo/.claude/worktrees/decoy1/node_modules"
  echo "decoy" >"$repo/.claude/worktrees/decoy1/node_modules/decoy-claude.js"
  mkdir -p "$repo/.codex/worktrees/decoy2/node_modules"
  echo "decoy" >"$repo/.codex/worktrees/decoy2/node_modules/decoy-codex.js"
  target="$repo/.claude/worktrees/target-wt"
  mkdir -p "$target"

  out="$(run_hook "$repo" deps "$target" 2>"$TMPROOT/err")"
  rc=$?
  err="$(cat "$TMPROOT/err")"
  dep_lines="$(printf '%s\n' "$out" | grep -c '^DEP=')"

  if [ "$rc" = "0" ]; then pass "DEPS-1-exit-zero"; else fail "DEPS-1-exit-zero" "rc=$rc err=[$err]"; fi
  if [ "$dep_lines" = "1" ]; then pass "DEPS-1-only-real-tree-discovered"; else fail "DEPS-1-only-real-tree-discovered" "expected exactly 1 DEP= line, got $dep_lines: [$out]"; fi
  decoys_found="$(find "$target" -name 'decoy-*' 2>/dev/null)"
  if [ -z "$decoys_found" ]; then pass "DEPS-1-no-decoys-copied"; else fail "DEPS-1-no-decoys-copied" "found decoy content under target: [$decoys_found]"; fi
}

test_deps_stale_tmp_no_nesting() {
  repo="$(fresh deps-stale-tmp)"
  mkdir -p "$repo/node_modules"
  echo x >"$repo/node_modules/source-marker.js"
  target="$repo/.claude/worktrees/target-wt"
  mkdir -p "$target/node_modules"
  echo "original" >"$target/node_modules/existing-marker.js"
  mkdir -p "$target/node_modules.sidecar-tmp/junk"
  echo x >"$target/node_modules.sidecar-tmp/junk/x"

  out="$(run_hook "$repo" deps "$target" 2>"$TMPROOT/err")"
  rc=$?
  err="$(cat "$TMPROOT/err")"

  if [ "$rc" = "0" ]; then pass "DEPS-2-exit-zero"; else fail "DEPS-2-exit-zero" "rc=$rc err=[$err]"; fi
  case "$out" in
    *"DEP=node_modules|already-present|-|0"*) pass "DEPS-2-reports-already-present" ;;
    *) fail "DEPS-2-reports-already-present" "output=[$out]" ;;
  esac
  if [ ! -e "$target/node_modules.sidecar-tmp" ]; then pass "DEPS-2-stale-tmp-deleted"; else fail "DEPS-2-stale-tmp-deleted" "$target/node_modules.sidecar-tmp still exists"; fi
  entries="$(find "$target/node_modules" -mindepth 1 -maxdepth 1 2>/dev/null)"
  if [ "$entries" = "$target/node_modules/existing-marker.js" ]; then
    pass "DEPS-2-no-nesting"
  else
    fail "DEPS-2-no-nesting" "expected only existing-marker.js under target/node_modules, got: [$entries]"
  fi
  content="$(cat "$target/node_modules/existing-marker.js" 2>/dev/null)"
  if [ "$content" = "original" ]; then pass "DEPS-2-target-content-untouched"; else fail "DEPS-2-target-content-untouched" "content=[$content]"; fi
}

test_deps_dep_line_format() {
  repo="$(fresh deps-format)"
  mkdir -p "$repo/node_modules/pkg"
  echo x >"$repo/node_modules/pkg/index.js"
  target="$repo/.claude/worktrees/target-wt"
  mkdir -p "$target"

  out="$(run_hook "$repo" deps "$target" 2>"$TMPROOT/err")"
  dep_line="$(printf '%s\n' "$out" | grep '^DEP=' | head -n1)"
  fields="$(printf '%s\n' "$dep_line" | sed 's/^DEP=//')"
  rel="$(printf '%s\n' "$fields" | cut -d'|' -f1)"
  outcome="$(printf '%s\n' "$fields" | cut -d'|' -f2)"
  tier="$(printf '%s\n' "$fields" | cut -d'|' -f3)"
  seconds="$(printf '%s\n' "$fields" | cut -d'|' -f4)"

  if [ "$rel" = "node_modules" ]; then pass "DEPS-3-rel-path"; else fail "DEPS-3-rel-path" "rel=[$rel]"; fi
  case "$outcome" in
    cloned|already-present|failed) pass "DEPS-3-outcome-valid" ;;
    *) fail "DEPS-3-outcome-valid" "outcome=[$outcome]" ;;
  esac
  case "$tier" in
    clonefile|reflink|plain|-) pass "DEPS-3-tier-valid" ;;
    *) fail "DEPS-3-tier-valid" "tier=[$tier]" ;;
  esac
  case "$seconds" in
    ''|*[!0-9]*) fail "DEPS-3-seconds-numeric" "seconds=[$seconds] is not all digits" ;;
    *) pass "DEPS-3-seconds-numeric" ;;
  esac
}

test_deps_no_symlinks_no_install() {
  repo="$(fresh deps-no-symlink)"
  mkdir -p "$repo/node_modules/pkg/sub"
  echo "content-a" >"$repo/node_modules/pkg/index.js"
  echo "content-b" >"$repo/node_modules/pkg/sub/nested.js"
  target="$repo/.claude/worktrees/target-wt"
  mkdir -p "$target"

  run_hook "$repo" deps "$target" >"$TMPROOT/deps-out" 2>"$TMPROOT/err"

  symlinks="$(find "$target" -type l 2>/dev/null)"
  if [ -z "$symlinks" ]; then pass "DEPS-4-no-symlinks"; else fail "DEPS-4-no-symlinks" "found symlinks: [$symlinks]"; fi

  # Mechanism only: the copy must be byte-for-byte identical to the
  # source. Any install command run against the target would add,
  # rewrite, or reorder files (e.g. a rebuilt lockfile or .bin shim);
  # diff -r catches all of those, not just symlink creation.
  if diff -rq "$repo/node_modules" "$target/node_modules" >"$TMPROOT/diffout" 2>&1; then
    pass "DEPS-5-copy-identical-no-install-side-effects"
  else
    fail "DEPS-5-copy-identical-no-install-side-effects" "diff: [$(cat "$TMPROOT/diffout")]"
  fi
}

test_deps_mtime_all_digits() {
  # Extract the actual mtime() function body from the script under test
  # so this exercises whatever implementation is currently shipped, not
  # a hand-copied stand-in.
  fn_src="$(sed -n '/^mtime() {/,/^}/p' "$WT")"
  if [ -z "$fn_src" ]; then
    fail "DEPS-6-mtime-function-found" "could not locate mtime() in $WT"
    return
  fi
  pass "DEPS-6-mtime-function-found"

  repo="$(fresh deps-mtime)"
  probe="$repo/README.md"

  # Direct call against a real file. On macOS, BSD `stat -f %m`
  # legitimately succeeds here, so this assertion cannot fail on this
  # platform even against the pre-fix buggy form -- that GNU-only
  # failure path is exercised by issue #110's ubuntu-latest CI, not by
  # this harness run locally. Kept here as the straightforward case.
  real_out="$(bash -c "$fn_src"$'\n''mtime "$1"' -- "$probe" 2>/dev/null)"
  case "$real_out" in
    ''|*[!0-9]*) fail "DEPS-6-mtime-real-file-all-digits" "mtime output=[$real_out] is not all digits" ;;
    *) pass "DEPS-6-mtime-real-file-all-digits" ;;
  esac

  # Mocked-GNU-stat call: reproduces GNU coreutils' documented behavior
  # (`stat -f %m FILE` succeeds and prints a mount path, not an epoch;
  # `stat -c %Y FILE` succeeds and prints the real per-file mtime) via a
  # PATH-shadowing `stat` shell function. This DOES distinguish the
  # fixed implementation (falls back correctly, all-digit output) from
  # the historical NEW-18a bug (trusts the mount-path output because it
  # exited 0) on any host OS, independent of the platform blind spot
  # above.
  mock_out="$(bash -c '
    stat() {
      case "$1" in
        -f) echo "/dev/disk1s1"; return 0 ;;
        -c) echo "1700000000"; return 0 ;;
      esac
      return 1
    }
    '"$fn_src"'
    mtime "$1"
  ' -- "$probe" 2>/dev/null)"
  case "$mock_out" in
    ''|*[!0-9]*) fail "DEPS-6-mtime-mocked-gnu-fallback" "mtime output=[$mock_out] is not all digits under mocked GNU stat -- NEW-18a would reproduce here" ;;
    *) pass "DEPS-6-mtime-mocked-gnu-fallback" ;;
  esac
}

# ---------------------------------------------------------------------
# run everything
# ---------------------------------------------------------------------

test_create_basic
test_create_idempotent
test_create_branch_elsewhere
test_create_gitignore_once
test_create_slash_slug
test_path_matches_create
test_remove_cleans_generated_trees
test_remove_refuses_on_uncommitted_tracked
test_remove_succeeds_on_foreign_worktree
test_deps_prunes_both_worktree_trees
test_deps_stale_tmp_no_nesting
test_deps_dep_line_format
test_deps_no_symlinks_no_install
test_deps_mtime_all_digits

echo "---"
echo "$PASS_COUNT passed, $FAIL_COUNT failed (against $WT)"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
