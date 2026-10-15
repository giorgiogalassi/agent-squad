#!/usr/bin/env bash
# squad-doctor.sh - report-only install-freshness check (issue #119).
# Compares the installed ~/.claude/{agents,skills,hooks} with the source
# repo's claude/{agents,skills,hooks} by content hash. Never modifies
# anything. Contract: SCRIPT_CONTRACT.md (stdout KEY=value only).
#
# Usage: squad-doctor.sh            (no arguments)
#
# Stdout:
#   STALE=<n>              files differing, missing (agents/skills only) or orphaned
#   CHECKED=yes|no         no = nothing compared (silent skip)
#   STALE_FILE=<rel>       installed file differs from, or is absent in, the repo copy
#   ORPHAN_FILE=<rel>      installed file the repo once shipped (git history) but no longer does
# Exit: 0 success or silent skip; 2 usage; 20 no sha256 tool.
#
# Silent skip (STALE=0, CHECKED=no, exit 0, no stderr) when the source
# record, the repo path or the install directory is missing.
#
# Install dir: $SQUAD_DOCTOR_HOME, default $HOME/.claude. The README
# install step writes the absolute repo path to <install dir>/.agent-squad-source.
# Hooks are only compared when installed (some are optional); agents and
# skills missing from the install count as stale. User files the repo never
# shipped are never flagged. Bash 3.2 / BSD+GNU portable.

if [ "$#" -gt 0 ]; then
  echo "usage: squad-doctor.sh" >&2
  exit 2
fi

INSTALL="${SQUAD_DOCTOR_HOME:-$HOME/.claude}"
SUBDIRS="agents skills hooks"

emit() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | sed 's/\\/\\\\/g')"; }
skip() { emit STALE 0; emit CHECKED no; exit 0; }

[ -f "$INSTALL/.agent-squad-source" ] || skip
REPO="$(head -n 1 "$INSTALL/.agent-squad-source" 2>/dev/null)"
[ -n "$REPO" ] && [ -d "$REPO/claude" ] || skip
for d in $SUBDIRS; do
  [ -d "$INSTALL/$d" ] || skip
  [ -d "$REPO/claude/$d" ] || skip
done

if command -v sha256sum >/dev/null 2>&1; then
  hash_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  hash_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
else
  echo "squad-doctor: no sha256sum or shasum on PATH" >&2
  exit 20
fi

STALE=0
LINES=""
NL='
'
add() {  # add <KEY> <rel>
  STALE=$((STALE + 1))
  LINES="${LINES}$(emit "$1" "$2")${NL}"
}

# Repo files vs installed copies.
for d in $SUBDIRS; do
  while IFS= read -r f; do
    rel="${f#$REPO/claude/}"
    case "$rel" in */.DS_Store|.DS_Store) continue ;; esac
    if [ ! -f "$INSTALL/$rel" ]; then
      [ "$d" = hooks ] || add STALE_FILE "$rel"
      continue
    fi
    [ "$(hash_of "$f")" = "$(hash_of "$INSTALL/$rel")" ] || add STALE_FILE "$rel"
  done < <(find "$REPO/claude/$d" -type f | LC_ALL=C sort)
done

# Orphans: paths once shipped by the repo (deleted somewhere in history),
# absent from the repo now, still present in the install.
if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r p; do
    case "$p" in claude/agents/*|claude/skills/*|claude/hooks/*) ;; *) continue ;; esac
    [ -e "$REPO/$p" ] && continue
    rel="${p#claude/}"
    [ -f "$INSTALL/$rel" ] && add ORPHAN_FILE "$rel"
  done < <(git -C "$REPO" log --no-renames --diff-filter=D --name-only --pretty=format: -- claude/agents claude/skills claude/hooks 2>/dev/null | LC_ALL=C sort -u)
fi

emit STALE "$STALE"
emit CHECKED yes
printf '%s' "$LINES"
exit 0
