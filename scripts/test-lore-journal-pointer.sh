#!/usr/bin/env bash
# Tests claude/hooks/lore-journal-pointer.sh (#330). Plain bash 3.2; fixture
# vaults only, nothing touches ~/second-brain.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-journal-pointer.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

export SQUAD_INCIDENTS=off
mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{lore-journal-pointer.sh,vault-check.sh,decisions-lint.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
JP="$TMPROOT/hooks/lore-journal-pointer.sh"
VC="$TMPROOT/hooks/vault-check.sh"

mkvault() {  # mkvault <dir>
  mkdir -p "$1/projects/p"
  printf -- '---\ntitle: p\n---\n\n# Decisions -- p\n\n## [2026-10-20] First\nbody one\n\n## [2026-10-21] Second\nbody two\n' > "$1/projects/p/decisions.md"
  printf '# Status\nLast updated: 2026-10-25 21:58 by claude-code\n\n## Goal\nx\n\n## Context refs\n\n\xe2\x80\x94\n\n## Blocked\nnone\n' > "$1/projects/p/status.md"
}
HDR="Decisions for this project live in $TMPROOT/root/JOURNAL.md (context: repo); this file holds vault-only rules."

V="$TMPROOT/v"; mkvault "$V"; mkdir -p "$TMPROOT/root"
git -C "$V" init -q && git -C "$V" add -A && git -C "$V" -c user.email=t@t -c user.name=t commit -qm init
ENTRIES_BEFORE="$(grep -v '^Decisions for' "$V/projects/p/decisions.md" | sed -n '/^## \[/,$p')"

# Not context: repo -> nothing written.
out="$(bash "$JP" --vault "$V" --project p --root "$TMPROOT/root")"
check "vault context: unchanged" "OUTCOME=unchanged
CHANGED=no" "$out"
check "vault context: decisions untouched" "0" "$(grep -c 'live in' "$V/projects/p/decisions.md")"

# repo context, JOURNAL.md absent: path named, marked missing.
out="$(bash "$JP" --vault "$V" --project p --root "$TMPROOT/root" --context repo)"
has "missing journal: applied" "OUTCOME=applied" "$out"
has "missing journal: reported" "JOURNAL=missing" "$out"
has "missing journal: status line says missing" "- $TMPROOT/root/JOURNAL.md (context: repo decisions; file missing)" "$(cat "$V/projects/p/status.md")"
check "header after the H1, once" "1" "$(grep -cxF "$HDR" "$V/projects/p/decisions.md")"
check "entries not rewritten" "$ENTRIES_BEFORE" "$(grep -v '^Decisions for' "$V/projects/p/decisions.md" | sed -n '/^## \[/,$p')"
check "placeholder dropped" "0" "$(grep -cx "$(printf '\xe2\x80\x94')" "$V/projects/p/status.md")"
check "other sections kept" "1" "$(grep -c '^## Blocked' "$V/projects/p/status.md")"
check "vault commit made" "[lore] p journal pointer" "$(git -C "$V" log -1 --format=%s)"

# Journal appears: pointer line updates in place, header unchanged.
echo "# Journal" > "$TMPROOT/root/JOURNAL.md"
out="$(bash "$JP" --vault "$V" --project p --root "$TMPROOT/root" --context repo)"
has "journal present: applied" "JOURNAL=present" "$out"
check "present: one pointer line" "1" "$(grep -c 'JOURNAL.md (context: repo' "$V/projects/p/status.md")"
has "present: line without missing" "- $TMPROOT/root/JOURNAL.md (context: repo decisions)" "$(cat "$V/projects/p/status.md")"

# Idempotent: second run changes nothing, no new commit.
H1="$(git -C "$V" rev-parse HEAD)"; S1="$(cat "$V/projects/p/status.md" "$V/projects/p/decisions.md")"
out="$(bash "$JP" --vault "$V" --project p --root "$TMPROOT/root" --context repo)"
has "rerun: unchanged" "OUTCOME=unchanged" "$out"
check "rerun: files identical" "$S1" "$(cat "$V/projects/p/status.md" "$V/projects/p/decisions.md")"
check "rerun: no new commit" "$H1" "$(git -C "$V" rev-parse HEAD)"

# Stale header (root moved): replaced in place, never duplicated.
mkdir -p "$TMPROOT/root2"
bash "$JP" --vault "$V" --project p --root "$TMPROOT/root2" --context repo >/dev/null
check "moved root: one header line" "1" "$(grep -c '^Decisions for this project live in' "$V/projects/p/decisions.md")"
has "moved root: new path" "$TMPROOT/root2/JOURNAL.md" "$(cat "$V/projects/p/decisions.md")"
check "moved root: one status pointer" "1" "$(grep -c 'JOURNAL.md (context: repo' "$V/projects/p/status.md")"

# No Context refs section / no front matter, no H1: section appended, header on top.
V2="$TMPROOT/v2"; mkdir -p "$V2/projects/p"
printf '## [2026-10-20] Only\nbody\n' > "$V2/projects/p/decisions.md"
printf '# Status\n\n## Goal\nx\n' > "$V2/projects/p/status.md"
bash "$JP" --vault "$V2" --project p --root "$TMPROOT/root" --context repo >/dev/null
check "bare decisions: header first line" "$HDR" "$(sed -n 1p "$V2/projects/p/decisions.md")"
check "bare decisions: entry kept" "1" "$(grep -c '^## \[2026-10-20\] Only' "$V2/projects/p/decisions.md")"
check "no refs section: created" "1" "$(grep -c '^## Context refs' "$V2/projects/p/status.md")"

# vault-check: the finding goes quiet.
V3="$TMPROOT/v3"; mkvault "$V3"
has "before: JOURNAL_POINTER_MISSING" "JOURNAL_POINTER_MISSING=p" "$(bash "$VC" check --vault "$V3" --project p --context repo)"
bash "$JP" --vault "$V3" --project p --root "$TMPROOT/root" --context repo >/dev/null
case "$(bash "$VC" check --vault "$V3" --project p --context repo)" in
  *JOURNAL_POINTER_MISSING*) bad "after: finding still reported" ;; *) ok "after: JOURNAL_POINTER_MISSING quiet" ;;
esac

# Preconditions and usage.
bash "$JP" --vault "$TMPROOT/v3" --project nope --root "$TMPROOT/root" --context repo >/dev/null 2>&1; check "unknown project: exit 10" "10" "$?"
bash "$JP" --bogus >/dev/null 2>&1; check "bad option: exit 2" "2" "$?"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
