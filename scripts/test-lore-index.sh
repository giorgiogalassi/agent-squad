#!/usr/bin/env bash
# Tests the SessionEnd INDEX sync of claude/hooks/lore-checkpoint.sh (#328):
# row date/status, row added, active project, path-only commit, and that the
# #333 health findings go quiet afterwards. Plain bash 3.2; fixture vaults only.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-index
FIXROOTS=""
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in [$3])" ;; *) ok "$1" ;; esac; }

mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{lore-checkpoint.sh,vault-check.sh,decisions-lint.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
SUT="$TMPROOT/hooks/lore-checkpoint.sh"
VC="$TMPROOT/hooks/vault-check.sh"
export SQUAD_INCIDENTS=off
# The rebuild path must never reach a real model: a fake claude that fails.
mkdir -p "$TMPROOT/fakebin"
printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "$TMPROOT/fakebin/claude"
chmod +x "$TMPROOT/fakebin/claude"
export PATH="$TMPROOT/fakebin:$PATH"

out="$("$MK" connected)"
F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
FIXROOTS="$F_ROOT"
export SECOND_BRAIN_PATH="$F_VAULT"
STATUS="$F_VAULT/projects/fixture/status.md"
IDX="$F_VAULT/INDEX.md"
GIT="git -c user.name=T -c user.email=t@example.com"

# Fresh status (nothing to rebuild), dated now.
TODAY="$(date +%Y-%m-%d)"
printf -- '---\ntitle: s\ntags: [status, active]\n---\n# Status\nLast updated: %s 09:00 by x\n\n## Goal\ng\n\n## Last checkpoint\n\n## Context refs\n' "$TODAY" > "$STATUS"
cat > "$IDX" <<IDXEOF
# Index

## Reading rules

| Path | Read it | For |
|------|---------|-----|
| \`published/\` | always | voice |

## Active project

Name: other
Status: [[projects/other/status]]
Last worked: 2026-01-01
Companion: claude

## Projects

| Project | Status | Last updated |
|---------|--------|--------------|
| [[projects/other/status\|other]] | active | 2026-01-01 |
| [[projects/fixture/status\|fixture]] | paused | 2026-01-02 |

## Content

- x
IDXEOF
git -C "$F_VAULT" init -q
printf 'unrelated\n' > "$F_VAULT/notes.md"
$GIT -C "$F_VAULT" add INDEX.md projects lore-config.json notes.md && $GIT -C "$F_VAULT" commit -q -m seed
echo changed >> "$F_VAULT/notes.md"   # unrelated uncommitted change
OTHER_ROW="$(grep 'projects/other/status\\|' "$IDX")"
READING="$(sed -n '/^## Reading rules/,/^## Active project/p' "$IDX")"

h_before="$(bash "$VC" check --vault "$F_VAULT" --project fixture)"
has "before: row behind reported" "INDEX_ROW_BEHIND=2026-01-02 < $TODAY" "$h_before"

printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1

check "row date and status updated" "| [[projects/fixture/status\\|fixture]] | active | $TODAY |" "$(grep 'projects/fixture/status' "$IDX" | grep '^|')"
check "other row untouched" "$OTHER_ROW" "$(grep 'projects/other/status\\|' "$IDX")"
check "reading rules untouched" "$READING" "$(sed -n '/^## Reading rules/,/^## Active project/p' "$IDX")"
has "active project set" "Name: fixture" "$(cat "$IDX")"
has "active status link set" "Status: [[projects/fixture/status]]" "$(cat "$IDX")"
has "Last worked set" "Last worked: $TODAY" "$(cat "$IDX")"
has "Companion kept" "Companion: claude" "$(cat "$IDX")"
check "health quiet after SessionEnd" "" "$(bash "$VC" check --vault "$F_VAULT" --project fixture | grep -E 'INDEX_ROW_BEHIND|INDEX_NO_ROW')"
check "commit touches INDEX.md only" "INDEX.md" "$(git -C "$F_VAULT" show --name-only --format= HEAD)"
check "unrelated change stays uncommitted" " M notes.md" "$(git -C "$F_VAULT" status --porcelain | grep notes.md)"
n="$(git -C "$F_VAULT" rev-list --count HEAD)"
printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1
check "second SessionEnd is a no-op (no new commit)" "$n" "$(git -C "$F_VAULT" rev-list --count HEAD)"

# Missing row gets added.
grep -v 'projects/fixture/status' "$IDX" > "$IDX.n" && mv "$IDX.n" "$IDX"
$GIT -C "$F_VAULT" commit -q -m drop -- INDEX.md
has "before: no row reported" "INDEX_NO_ROW=fixture" "$(bash "$VC" check --vault "$F_VAULT" --project fixture)"
printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1
check "missing row added" "| [[projects/fixture/status\\|fixture]] | active | $TODAY |" "$(grep 'projects/fixture/status' "$IDX" | grep '^|')"
check "no findings after add" "" "$(bash "$VC" check --vault "$F_VAULT" --project fixture | grep INDEX_)"

# A hand-set blocked or done status survives; the date still moves (#328 owner answer).
for hs in blocked done; do
  sed -i.bak "s/^| \[\[projects\/fixture\/status\\\\|fixture\]\] | [a-z]* | [0-9-]* |$/| [[projects\/fixture\/status\\\\|fixture]] | $hs | 2026-01-02 |/" "$IDX"; rm -f "$IDX.bak"
  $GIT -C "$F_VAULT" commit -q -m "$hs" -- INDEX.md
  printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1
  check "hand-set $hs kept, date updated" "| [[projects/fixture/status\\|fixture]] | $hs | $TODAY |" "$(grep 'projects/fixture/status' "$IDX" | grep '^|')"
done

# Vault that is not a git repo: INDEX still updated, no failure.
rm -rf "$F_VAULT/.git"
sed -i.bak 's/^Name: .*/Name: other/' "$IDX"; rm -f "$IDX.bak"
printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$SUT" >/dev/null 2>&1
has "non-git vault: active set" "Name: fixture" "$(cat "$IDX")"

# Local-only project (#351): excluded through .git/info/exclude, its name never
# reaches INDEX.md, the commit log or the active project; a control still syncs.
out2="$("$MK" connected)"
L_ROOT="$(printf '%s\n' "$out2" | sed -n 's/^FIXTURE_ROOT=//p')"
L_PROJECT="$(printf '%s\n' "$out2" | sed -n 's/^PROJECT=//p')"
L_VAULT="$(printf '%s\n' "$out2" | sed -n 's/^VAULT=//p')"
FIXROOTS="$FIXROOTS $L_ROOT"
export SECOND_BRAIN_PATH="$L_VAULT"
LIDX="$L_VAULT/INDEX.md"
printf -- '---\ntitle: s\ntags: [status, active]\n---\n# Status\nLast updated: %s 09:00 by x\n\n## Goal\ng\n\n## Last checkpoint\n\n## Context refs\n' "$TODAY" > "$L_VAULT/projects/fixture/status.md"
grep -v 'fixture' "$IDX" > "$LIDX"
git -C "$L_VAULT" init -q
printf 'projects/fixture/\n' >> "$L_VAULT/.git/info/exclude"
$GIT -C "$L_VAULT" add INDEX.md lore-config.json && $GIT -C "$L_VAULT" commit -q -m base
BASE_SHA="$(git -C "$L_VAULT" rev-parse HEAD)"
before_idx="$(cat "$LIDX")"
before_log="$(git -C "$L_VAULT" log --format=%s | wc -l | tr -d ' ')"
printf '{"cwd":"%s"}' "$L_PROJECT" | bash "$SUT" >/dev/null 2>&1
check "local-only: INDEX untouched" "$before_idx" "$(cat "$LIDX")"
lacks "local-only: no name in INDEX" "fixture" "$(cat "$LIDX")"
lacks "local-only: no name in git log" "fixture" "$(git -C "$L_VAULT" log --format=%B "$BASE_SHA"..HEAD)"
check "local-only: no vault commit" "$before_log" "$(git -C "$L_VAULT" log --format=%s | wc -l | tr -d ' ')"
has "local-only: INDEX has other rows" "projects/other/status" "$(cat "$LIDX")"
(. "$VC"; index_set_row "$LIDX" fixture active 2026-01-01 1 >/dev/null; index_set_active "$LIDX" fixture 2026-01-01 >/dev/null)
check "local-only: index functions skip it" "$before_idx" "$(cat "$LIDX")"
(. "$VC"; index_set_row "$LIDX" control active 2026-01-01 1 >/dev/null)
has "control: non-excluded project still gets a row" "projects/control/status" "$(cat "$LIDX")"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
