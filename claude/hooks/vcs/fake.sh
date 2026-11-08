#!/usr/bin/env bash
# vcs/fake.sh -- minimal VCS adapter for tests (scripts/test-cody-checkpoint.sh,
# scripts/test-squad-tracker.sh). SOURCED by squad_vcs when VCS_PROVIDER=fake.
# No network, no CLI. The open PR of every branch is $SQUAD_FAKE_VCS_PR
# ("<number> <base>"), none when unset.

vcs_available() { return 0; }
vcs_cli_name() { echo "CLI_NAME=fake"; }
vcs_auth_status() { return 0; }
vcs_pr_for_branch() {
  [ -n "${1:-}" ] || { echo "squad: pr-for-branch requires a branch" >&2; return 2; }
  [ -n "${SQUAD_FAKE_VCS_PR:-}" ] || return 0
  echo "PR=${SQUAD_FAKE_VCS_PR%% *}"
  case "$SQUAD_FAKE_VCS_PR" in *" "*) echo "BASE=${SQUAD_FAKE_VCS_PR#* }" ;; esac
}
