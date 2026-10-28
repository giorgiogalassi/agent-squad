#!/usr/bin/env bash
# Builds a reproducible fixture under ONE mktemp root, shared by tier-1
# tests and tier-2 scaffolds.
#
# Usage: make-fixture.sh connected|detached [--worktree] [--labels-custom]
#
# Creates: a project repo with an initial commit on main, a local bare
# `origin` (main pushed), a vault with lore-config.json (maps the project
# path to display name "fixture") and chisel-config.json for the mode.
# Default state_labels: in-progress / in-review / blocked, review_label
# "needs-review". --labels-custom: in_progress "wip", review_label "none".
# --worktree adds a `git worktree` on branch `fixture-wt`.
#
# Output (stdout, one KEY=VALUE per line):
#   FIXTURE_ROOT=  PROJECT=  VAULT=  WORKTREE=  SECOND_BRAIN_PATH=
# WORKTREE is empty without --worktree. A child process cannot export into
# its parent, so SECOND_BRAIN_PATH is printed (equal to VAULT); callers
# `eval` the output or parse by key. Cleanup is the caller's trap:
# rm -rf "$FIXTURE_ROOT". Bash 3.2, git, coreutils only; no jq.
set -eu

MODE="${1:-}"
case "$MODE" in connected|detached) shift ;; *)
  echo "usage: make-fixture.sh connected|detached [--worktree] [--labels-custom]" >&2; exit 2 ;;
esac
WT=0; CUSTOM=0
for a in "$@"; do
  case "$a" in
    --worktree) WT=1 ;;
    --labels-custom) CUSTOM=1 ;;
    *) echo "make-fixture.sh: unknown option $a" >&2; exit 2 ;;
  esac
done

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/squad-fixture.XXXXXX")"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "make-fixture.sh: mktemp failed; refusing to build in the working directory" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)"
PROJECT="$ROOT/project"; ORIGIN="$ROOT/origin.git"; VAULT="$ROOT/vault"
NAME="fixture"

GIT="git -c user.name=Fixture -c user.email=fixture@example.com -c init.defaultBranch=main"
$GIT init -q "$PROJECT"
(
  cd "$PROJECT"
  echo "fixture" > README.md
  git add README.md
  $GIT commit -q -m "Initial commit"
  git branch -M main
)
$GIT init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$PROJECT" remote add origin "$ORIGIN"
git -C "$PROJECT" push -q origin main
git -C "$PROJECT" fetch -q origin

SQUAD="$VAULT/projects/$NAME/.squad"
mkdir -p "$SQUAD"
printf '{"projects":{"%s":"%s"}}\n' "$PROJECT" "$NAME" > "$VAULT/lore-config.json"

if [ "$CUSTOM" = 1 ]; then IP="wip"; RL="none"; else IP="in-progress"; RL="needs-review"; fi
cat > "$SQUAD/chisel-config.json" <<JSON
{
  "chisel": {
    "mode": "$MODE",
    "repo": "fixture-owner/fixture-repo",
    "review_label": "$RL",
    "state_labels": {
      "in_progress": "$IP",
      "in_review": "in-review",
      "blocked": "blocked"
    }
  }
}
JSON

WORKTREE=""
if [ "$WT" = 1 ]; then
  WORKTREE="$ROOT/worktree"
  git -C "$PROJECT" worktree add -q -b fixture-wt "$WORKTREE"
  WORKTREE="$(cd "$WORKTREE" && pwd -P)"
fi

printf 'FIXTURE_ROOT=%s\nPROJECT=%s\nVAULT=%s\nWORKTREE=%s\nSECOND_BRAIN_PATH=%s\n' \
  "$ROOT" "$PROJECT" "$VAULT" "$WORKTREE" "$VAULT"
