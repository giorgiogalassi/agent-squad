#!/usr/bin/env bash
# Report a hand edit of "version" in claude/.claude-plugin/plugin.json (#293).
# Used by .github/workflows/plugin-version-guard.yml. Needs a git checkout with
# enough history to find the merge-base.
#
# Usage: scripts/plugin-version-guard.sh --base <ref> [--head <ref>] [--head-branch <name>]
#
# The "before" version is read at `git merge-base <base> <head>`, not at the
# base tip, so a bump that landed on the base after the PR branched is not
# mistaken for an edit by the PR.
#
# Stdout (SCRIPT_CONTRACT.md): KEY=value lines
#   OUTCOME=pass|skip|fail
#   REASON=<short text>
#   BEFORE=<version at merge-base>   AFTER=<version at head>   (when read)
# Exit: 0 pass or skip, 2 usage error, 10 version edited (OUTCOME=fail),
#       20 git failure (no merge-base, unreadable ref).
set -u
base="" head="HEAD" head_branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)        [ $# -ge 2 ] || { echo "error: --base needs a value" >&2; exit 2; }
                   base="$2"; shift 2 ;;
    --head)        [ $# -ge 2 ] || { echo "error: --head needs a value" >&2; exit 2; }
                   head="$2"; shift 2 ;;
    --head-branch) [ $# -ge 2 ] || { echo "error: --head-branch needs a value" >&2; exit 2; }
                   head_branch="$2"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$base" ] || { echo "usage: $0 --base <ref> [--head <ref>] [--head-branch <name>]" >&2; exit 2; }

manifest=claude/.claude-plugin/plugin.json
case "$head_branch" in
  chore/plugin-v*) echo "OUTCOME=skip"; echo "REASON=bump branch"; exit 0 ;;
esac

mb="$(git merge-base "$base" "$head" 2>/dev/null)" || { echo "error: no merge-base for $base and $head (shallow clone?)" >&2; exit 20; }

if ! git cat-file -e "$mb:$manifest" 2>/dev/null; then
  echo "OUTCOME=skip"; echo "REASON=manifest absent at merge-base"; exit 0
fi
before="$(git show "$mb:$manifest" | jq -r '.version // empty')" || exit 20
if [ -z "$before" ]; then
  echo "OUTCOME=skip"; echo "REASON=no version at merge-base"; exit 0
fi
after="$(git show "$head:$manifest" 2>/dev/null | jq -r '.version // empty')" || exit 20
echo "BEFORE=$before"; echo "AFTER=$after"
if [ "$before" != "$after" ]; then
  echo "OUTCOME=fail"; echo "REASON=version changed"; exit 10
fi
echo "OUTCOME=pass"; echo "REASON=version untouched"
