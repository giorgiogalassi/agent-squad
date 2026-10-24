#!/usr/bin/env bash
# Shared scaffold for the tier-2 eval cases (sourced by each case's
# scaffold.sh). Runs as the invoking user with HOME set to the run's temp
# home and cwd = the run's workspace ($HOME/cwd), limit 120 s. Bash 3.2.
#
# Usage (from a case scaffold.sh):  . lib/scaffold-common.sh; squad_scaffold <make-fixture args>
#
# Result in the workspace (cwd):
#   project/    symlink to the fixture repo (main + local bare origin)
#   worktree/   symlink to the fixture worktree (only with --worktree)
#   bin/gh      copy of scripts/gh-shim/gh (belt and braces; the real PATH
#               prefix comes from the launcher: PATH="$PWD/scripts/gh-shim:$PATH")
# and under $HOME: second-brain/ (lore-config.json
# mapping project/worktree/workspace to "fixture", plus the fixture's
# chisel-config.json). The vault lives under HOME because the eval sandbox
# allows Bash writes there (verified; see README "Evals (tier 2)").
set -eu

squad_scaffold() {
  local self repo out key val
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo="$(cd "$self/../../.." && pwd)"
  WORKSPACE="$(pwd -P)"

  # Hooks are not copied: the eval loads claude/ as a plugin, so
  # ${CLAUDE_PLUGIN_ROOT}/hooks/ resolves to the checkout.
  mkdir -p "$WORKSPACE/bin"
  cp "$repo/scripts/gh-shim/gh" "$WORKSPACE/bin/gh"
  chmod +x "$WORKSPACE/bin/gh"

  # The fixture is built INSIDE the workspace (TMPDIR points at it).
  out="$(TMPDIR="$WORKSPACE" bash "$repo/scripts/fixtures/make-fixture.sh" "$@")"
  PROJECT=""; WORKTREE=""; VAULT=""
  while IFS='=' read -r key val; do
    case "$key" in
      PROJECT) PROJECT="$val" ;;
      WORKTREE) WORKTREE="$val" ;;
      VAULT) VAULT="$val" ;;
    esac
  done <<EOT
$out
EOT
  [ -n "$PROJECT" ] && [ -n "$VAULT" ] || { echo "scaffold: make-fixture.sh gave no PROJECT/VAULT" >&2; exit 1; }

  mkdir -p "$HOME/second-brain"
  cp -R "$VAULT/projects" "$HOME/second-brain/projects"
  {
    printf '{"projects":{"%s":"fixture","%s":"fixture"' "$PROJECT" "$WORKSPACE"
    [ -z "$WORKTREE" ] || printf ',"%s":"fixture"' "$WORKTREE"
    printf '}}\n'
  } > "$HOME/second-brain/lore-config.json"

  ln -s "$PROJECT" "$WORKSPACE/project"
  [ -z "$WORKTREE" ] || ln -s "$WORKTREE" "$WORKSPACE/worktree"
}
