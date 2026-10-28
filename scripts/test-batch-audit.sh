#!/usr/bin/env bash
# Tests claude/hooks/batch-audit.sh (#363). Plain bash 3.2; vault is a fixture.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-batch-audit.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in [$3])" ;; *) ok "$1" ;; esac; }

mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{batch-audit.sh,squad-common.sh,path-resolve.sh,squad-incidents.sh} "$TMPROOT/hooks/"
BA="$TMPROOT/hooks/batch-audit.sh"
export SQUAD_INCIDENTS=off
V="$TMPROOT/vault"; P="$V/projects/demo"; SQ="$P/.squad"; mkdir -p "$SQ/issues"
git -C "$V" init -q 2>/dev/null
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@e.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@e.com
git -C "$V" config user.name T; git -C "$V" config user.email t@e.com

cat > "$SQ/issues/batch-1.md" <<'B'
# Batch 2026-10-01
Status: pending

## Key mapping
| Local | Tracker |
|-------|---------|
| SQ-1  | —       |
| SQ-2  | #50     |

## SQ-1: Parent (parent)

Context.

## SQ-2: First

Body.

### Acceptance criteria
- Block state-only usage
- ~~Already struck~~

### Open questions
- Confirm the backend also refuses state-only usage

## SQ-3: Second

### Open questions
- Is the cache warm?

## Open questions
- Batch level question
B
cat > "$SQ/issues/batch-2.md" <<'B'
# Batch 2026-10-02
Status: pending

## SQ-7: Live

### Open questions
- Still being worked on?
B
printf '[#50] 2026-10-05 resolved. PR: #51\n[MERGE] 2026-10-06 #51 merged (closes #50).\n' > "$SQ/progress.txt"
printf '# Decisions\n\n## [2026-10-07] Backend allows state-only usage\nBody.\n' > "$P/decisions.md"
git -C "$V" add -A; git -C "$V" commit -qm init

out="$(bash "$BA" list --vault "$V" --project demo)"
has "list names the open question" "AUDIT_ITEM=batch-1.md|23|SQ-2/50|question|Confirm the backend also refuses state-only usage" "$out"
has "list names the acceptance criterion" "|SQ-2/50|criterion|Block state-only usage" "$out"
lacks "struck item not listed" "Already struck" "$out"
lacks "unresolved issue not listed" "cache warm" "$out"
lacks "unresolved batch not listed" "batch-2.md" "$out"
lacks "batch-level question waits for all issues" "Batch level" "$out"
check "count" "AUDIT_COUNT=2" "$(printf '%s\n' "$out" | grep AUDIT_COUNT)"
check "batches" "AUDIT_BATCHES=1" "$(printf '%s\n' "$out" | grep AUDIT_BATCHES)"
check "list writes nothing" "" "$(git -C "$V" status --porcelain)"

# answered without a decision entry
bash "$BA" close batch-1.md --line 23 --as answered --vault "$V" --project demo >/dev/null 2>&1; check "answered w/o decision: exit 2/10" "10" "$?"
bash "$BA" close batch-1.md --line 23 --as answered --decision "2026-10-07 Nope" --vault "$V" --project demo >/dev/null 2>&1; check "answered with unknown decision: exit 10" "10" "$?"
check "batch untouched on refusal" "" "$(git -C "$V" status --porcelain)"

r="$(bash "$BA" close batch-1.md --line 23 --as answered --decision "2026-10-07 Backend allows state-only usage" --vault "$V" --project demo)"
has "answered applied" "OUTCOME=applied" "$r"
check "answered: struck with pointer" "- ~~Confirm the backend also refuses state-only usage~~ (answered: decisions.md [2026-10-07] Backend allows state-only usage)" "$(sed -n 23p "$SQ/issues/batch-1.md")"
check "answered: committed" "" "$(git -C "$V" status --porcelain)"
out="$(bash "$BA" list --vault "$V" --project demo)"
lacks "answered item gone from list" "Confirm the backend" "$out"

# obsolete and open
bash "$BA" close batch-1.md --line 19 --as obsolete --vault "$V" --project demo >/dev/null
check "obsolete: struck" "- ~~Block state-only usage~~ (obsolete)" "$(sed -n 19p "$SQ/issues/batch-1.md")"
sed -i.bak 's/^- ~~Block.*/- Block it/' "$SQ/issues/batch-1.md"; rm -f "$SQ/issues/batch-1.md.bak"; git -C "$V" commit -qam reset
printf '## Next\n- existing\n' > "$P/status.md"; git -C "$V" add -A; git -C "$V" commit -qm st
bash "$BA" close batch-1.md --line 19 --as open --vault "$V" --project demo >/dev/null
has "open: carried to status Next" "- Block it (from batch-1.md)" "$(cat "$P/status.md")"
has "open: struck in batch" "~~Block it~~" "$(sed -n 19p "$SQ/issues/batch-1.md")"
bash "$BA" close batch-1.md --line 2 --as obsolete --vault "$V" --project demo >/dev/null 2>&1; check "non-item line refused" "10" "$?"
bash "$BA" close batch-1.md --line 19 --as bogus --vault "$V" --project demo >/dev/null 2>&1; check "bad --as: exit 2" "2" "$?"

# batch Status done resolves everything, batch-level included
sed -i.bak 's/^Status: pending/Status: done/' "$SQ/issues/batch-2.md"; rm -f "$SQ/issues/batch-2.md.bak"
out="$(bash "$BA" list --vault "$V" --project demo)"
has "Status done lists batch-2" "batch-2.md|" "$out"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
