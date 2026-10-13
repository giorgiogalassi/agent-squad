#!/usr/bin/env bash
# Scaffold for eval case detached-claim (see lib/scaffold-common.sh).
set -eu
. "$(dirname "$0")/../lib/scaffold-common.sh"
squad_scaffold detached
