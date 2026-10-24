#!/usr/bin/env bash
# Compute the next plugin version from the current one and a label set.
# Pure: no git, no gh, no file access. Used by .github/workflows/plugin-version.yml.
#
# Usage: scripts/plugin-version-bump.sh --version X.Y.Z --labels "a,b,c"
#
# Rule (owner decision, #293), highest match wins:
#   breaking-change -> major   (X+1.0.0)
#   enhancement     -> minor   (X.Y+1.0)
#   bug             -> patch   (X.Y.Z+1)
#   anything else (documentation only, no labels) -> none
#
# Stdout (SCRIPT_CONTRACT.md): KEY=value lines
#   BUMP=major|minor|patch|none
#   NEW_VERSION=<version>      (equals the input when BUMP=none)
#   CHANGED=yes|no
# Exit: 0 ok (including no bump), 2 usage error, 10 malformed version.
set -u

version="" labels="" have_v=0 have_l=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || { echo "error: --version needs a value" >&2; exit 2; }
               version="$2"; have_v=1; shift 2 ;;
    --labels)  [ $# -ge 2 ] || { echo "error: --labels needs a value" >&2; exit 2; }
               labels="$2"; have_l=1; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$have_v" = 1 ] && [ "$have_l" = 1 ] || { echo "usage: $0 --version X.Y.Z --labels a,b,c" >&2; exit 2; }

case "$version" in
  ''|*[!0-9.]*|.*|*.|*..*) echo "error: malformed version: $version" >&2; exit 10 ;;
esac
IFS=. read -r major minor patch extra <<EOV
$version
EOV
if [ -z "$major" ] || [ -z "$minor" ] || [ -z "$patch" ] || [ -n "$extra" ]; then
  echo "error: malformed version: $version" >&2; exit 10
fi

bump=none
case ",$labels," in *,breaking-change,*) bump=major ;; esac
if [ "$bump" = none ]; then case ",$labels," in *,enhancement,*) bump=minor ;; esac; fi
if [ "$bump" = none ]; then case ",$labels," in *,bug,*) bump=patch ;; esac; fi

# 10# forces base 10 so a leading zero is never read as octal.
major=$((10#$major)); minor=$((10#$minor)); patch=$((10#$patch))
case "$bump" in
  major) new="$((major + 1)).0.0" ;;
  minor) new="$major.$((minor + 1)).0" ;;
  patch) new="$major.$minor.$((patch + 1))" ;;
  none)  new="$version" ;;
esac

echo "BUMP=$bump"
echo "NEW_VERSION=$new"
if [ "$bump" = none ]; then echo "CHANGED=no"; else echo "CHANGED=yes"; fi
