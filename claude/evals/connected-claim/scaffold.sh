#!/usr/bin/env bash
# Scaffold for eval case connected-claim (see lib/scaffold-common.sh).
set -eu
. "$(dirname "$0")/../lib/scaffold-common.sh"
squad_scaffold connected
