#!/usr/bin/env bash
# Scaffold for eval case worktree-orient (see lib/scaffold-common.sh).
set -eu
. "$(dirname "$0")/../lib/scaffold-common.sh"
squad_scaffold connected --worktree
