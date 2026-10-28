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
H1="$(printf '%s' "Confirm the backend also refuses state-only usage" | cksum | cut -d" " -f1)"
H2="$(printf '%s' "Block state-only usage" | cksum | cut -d" " -f1)"
has "list names the open question" "AUDIT_ITEM=batch-1.md|23|SQ-2/50|question|$H1|Confirm the backend also refuses state-only usage" "$out"
has "list names the acceptance criterion" "|SQ-2/50|criterion|$H2|Block state-only usage" "$out"
lacks "struck item not listed" "Already struck" "$out"
lacks "unresolved issue not listed" "cache warm" "$out"
lacks "unresolved batch not listed" "batch-2.md" "$out"
lacks "batch-level question waits for all issues" "Batch level" "$out"
check "count" "AUDIT_COUNT=2" "$(printf '%s\n' "$out" | grep AUDIT_COUNT)"
check "batches" "AUDIT_BATCHES=1" "$(printf '%s\n' "$out" | grep AUDIT_BATCHES)"
check "list writes nothing" "" "$(git -C "$V" status --porcelain)"

# answered without a decision entry
bash "$BA" close batch-1.md --line 23 --hash "$H1" --as answered --vault "$V" --project demo >/dev/null 2>&1; check "answered w/o decision: exit 2/10" "10" "$?"
bash "$BA" close batch-1.md --line 23 --hash "$H1" --as answered --decision "2026-10-07 Nope" --vault "$V" --project demo >/dev/null 2>&1; check "answered with unknown decision: exit 10" "10" "$?"
check "batch untouched on refusal" "" "$(git -C "$V" status --porcelain)"

r="$(bash "$BA" close batch-1.md --line 23 --hash "$H1" --as answered --decision "2026-10-07 Backend allows state-only usage" --vault "$V" --project demo)"
has "answered applied" "OUTCOME=applied" "$r"
check "answered: struck with pointer" "- ~~Confirm the backend also refuses state-only usage~~ (answered: decisions.md [2026-10-07] Backend allows state-only usage)" "$(sed -n 23p "$SQ/issues/batch-1.md")"
check "answered: committed" "" "$(git -C "$V" status --porcelain)"
out="$(bash "$BA" list --vault "$V" --project demo)"
lacks "answered item gone from list" "Confirm the backend" "$out"

# obsolete and open
bash "$BA" close batch-1.md --line 19 --hash "$H2" --as obsolete --vault "$V" --project demo >/dev/null
check "obsolete: struck" "- ~~Block state-only usage~~ (obsolete)" "$(sed -n 19p "$SQ/issues/batch-1.md")"
sed -i.bak 's/^- ~~Block.*/- Block it/' "$SQ/issues/batch-1.md"; rm -f "$SQ/issues/batch-1.md.bak"; git -C "$V" commit -qam reset
printf '## Next\n- existing\n' > "$P/status.md"; git -C "$V" add -A; git -C "$V" commit -qm st
H3="$(printf '%s' "Block it" | cksum | cut -d" " -f1)"
bash "$BA" close batch-1.md --line 19 --hash "$H3" --as open --vault "$V" --project demo >/dev/null
has "open: carried to status Next" "- Block it (from batch-1.md)" "$(cat "$P/status.md")"
has "open: struck in batch" "~~Block it~~" "$(sed -n 19p "$SQ/issues/batch-1.md")"
bash "$BA" close batch-1.md --line 2 --hash 1 --as obsolete --vault "$V" --project demo >/dev/null 2>&1; check "non-item line refused" "10" "$?"
bash "$BA" close batch-1.md --line 19 --hash "$H3" --as bogus --vault "$V" --project demo >/dev/null 2>&1; check "bad --as: exit 2" "2" "$?"

# batch Status done resolves everything, batch-level included
sed -i.bak 's/^Status: pending/Status: done/' "$SQ/issues/batch-2.md"; rm -f "$SQ/issues/batch-2.md.bak"
out="$(bash "$BA" list --vault "$V" --project demo)"
has "Status done lists batch-2" "batch-2.md|" "$out"

# ---- round 2: stale line, false positives, multi-closes, executed, list contract
check "list OUTCOME" "OUTCOME=unchanged" "$(bash "$BA" list --vault "$V" --project demo | grep '^OUTCOME=')"
check "list CHANGED" "CHANGED=no" "$(bash "$BA" list --vault "$V" --project demo | grep '^CHANGED=')"

mkdir -p "$TMPROOT/v2/projects/demo/.squad/issues"; V2="$TMPROOT/v2"; Q2="$V2/projects/demo/.squad"
git -C "$V2" init -q
cat > "$Q2/issues/batch-3.md" <<'B'
# Batch 3
Status: pending

## SQ-5: Five

### Open questions
- Q five a\b

## SQ-6: Six

### Open questions
- Q six

## SQ-8: Eight

### Open questions
- Q eight

## SQ-9: Nine

### Open questions
- Q nine
B
cat > "$Q2/issues/batch-4.md" <<'B'
# Batch 4
Status: executed

## SQ-20: Twenty

### Open questions
- Q twenty
B
cat > "$Q2/progress.txt" <<'B'
[SQ-5] 2026-01-01 not resolved yet
[ralph] 2026-01-01 resolved something
[SQ-6] 2026-01-01 unblocked until resolved
[MERGE] 2026-10-06 #9 merged (closes SQ-8, SQ-9).
[MERGE] 2026-10-06 #10 encloses SQ-5
B
git -C "$V2" add -A; git -C "$V2" commit -qm init
out="$(bash "$BA" list --vault "$V2" --project demo)"
lacks "not resolved is not resolved" "|SQ-5|" "$out"
lacks "non-issue tag ignored" "|SQ-6|" "$out"
has "multi-key closes: first" "|SQ-8|question|" "$out"
has "multi-key closes: second" "|SQ-9|question|" "$out"
has "Status executed resolves batch" "batch-4.md|" "$out"
printf '[SQ-5] 2026-01-01 resolved. PR: #1\n' >> "$Q2/progress.txt"
printf '[SQ-6] resolved, no-op. Notes: x\n' >> "$Q2/progress.txt"
out="$(bash "$BA" list --vault "$V2" --project demo)"
has "dated resolved line matches" "|SQ-5|question|" "$out"
has "undated resolved, line matches" "|SQ-6|question|" "$out"
has "backslash escaped in AUDIT_ITEM" "Q five a\\\\b" "$out"

# stale line: batch changes between list and close
HQ6="$(printf '%s' "Q six" | cksum | cut -d" " -f1)"
LN="$(grep -n '^- Q six' "$Q2/issues/batch-3.md" | cut -d: -f1)"
sed -i.bak '/^- Q five/d' "$Q2/issues/batch-3.md"; rm -f "$Q2/issues/batch-3.md.bak"
bash "$BA" close batch-3.md --line "$LN" --hash "$HQ6" --as obsolete --vault "$V2" --project demo >/dev/null 2>&1; rc=$?
check "stale line refused: exit 10" "10" "$rc"
has "stale line: item untouched" "- Q eight" "$(cat "$Q2/issues/batch-3.md")"
bash "$BA" close batch-3.md --line "$LN" --as obsolete --vault "$V2" --project demo >/dev/null 2>&1; check "close without --hash: exit 2" "2" "$?"

# backslash sequences survive being struck byte-exact
printf '%s\n' '- Q ten \n and \t end' >> "$Q2/issues/batch-3.md"
HQ9="$(printf '%s' 'Q ten \n and \t end' | cksum | cut -d" " -f1)"
LN9="$(grep -n '^- Q ten' "$Q2/issues/batch-3.md" | cut -d: -f1)"
bash "$BA" close batch-3.md --line "$LN9" --hash "$HQ9" --as obsolete --vault "$V2" --project demo >/dev/null 2>&1; check "backslash close: exit 0" "0" "$?"
check "backslash item struck byte-exact" '- ~~Q ten \n and \t end~~ (obsolete)' "$(sed -n "${LN9}p" "$Q2/issues/batch-3.md")"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
