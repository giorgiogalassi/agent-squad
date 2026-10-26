#!/usr/bin/env bash
# Tests claude/hooks/decisions-lint.sh, lore-decide.sh and the decisions-lint
# wiring in lore-checkpoint.sh / lore-orient.sh (#327). Plain bash 3.2; every
# vault is a fixture, nothing touches ~/second-brain.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-decisions-lint.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in [$3])" ;; *) ok "$1" ;; esac; }

mkdir -p "$TMPROOT/hooks" "$TMPROOT/fakebin"
cp "$REPO_ROOT"/claude/hooks/{lore-checkpoint.sh,lore-orient.sh,decisions-lint.sh,lore-decide.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
LINT="$TMPROOT/hooks/decisions-lint.sh"
DECIDE="$TMPROOT/hooks/lore-decide.sh"
# A claude that fails keeps the checkpoint's status rebuild out of the picture.
printf '#!/bin/sh\nexit 1\n' > "$TMPROOT/fakebin/claude"; chmod +x "$TMPROOT/fakebin/claude"
export PATH="$TMPROOT/fakebin:$PATH"
export SQUAD_INCIDENTS=off

out="$("$MK" connected)"
F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
FIXROOTS="$F_ROOT"
export SECOND_BRAIN_PATH="$F_VAULT"
PDIR="$F_VAULT/projects/fixture"; mkdir -p "$PDIR"
DEC="$PDIR/decisions.md"
GIT="git -C $F_VAULT -c user.name=T -c user.email=t@example.com"
[ -d "$F_VAULT/.git" ] || $GIT init -q

# ---- Case 1: Supersedes without inverse -> inverse added, text untouched
cat > "$TMPROOT/d1.md" <<'EOF'
# Decisions

## [2026-10-19] Scope A
Body A line.

## [2026-10-22] Scope B
Supersedes: [2026-10-19] Scope A
Body B line.

## [2026-10-23] Tweak C
Supersedes in part: [2026-10-22] Scope B
Body C.
EOF
r="$(bash "$LINT" check "$TMPROOT/d1.md")"
has "check reports missing inverse (full)" "DECISIONS_MISSING_INVERSE=[2026-10-22] Scope B -> [2026-10-19] Scope A" "$r"
has "check reports missing inverse (partial)" "DECISIONS_MISSING_INVERSE=[2026-10-23] Tweak C -> [2026-10-22] Scope B" "$r"
cp "$TMPROOT/d1.md" "$TMPROOT/d1.orig"
r="$(bash "$LINT" fix "$TMPROOT/d1.md")"
has "fix applies the full inverse" "DECISIONS_APPLIED_INVERSE=[2026-10-22] Scope B -> [2026-10-19] Scope A" "$r"
check "full inverse sits under the target heading" "Superseded by: [2026-10-22] Scope B" "$(sed -n '/^## \[2026-10-19\]/{n;p;}' "$TMPROOT/d1.md")"
check "partial inverse is Superseded in part by" "Superseded in part by: [2026-10-23] Tweak C" "$(sed -n '/^## \[2026-10-22\]/{n;p;}' "$TMPROOT/d1.md")"
check "fix only adds lines" "" "$(diff "$TMPROOT/d1.orig" "$TMPROOT/d1.md" | grep '^<' )"
check "fix is idempotent" "" "$(bash "$LINT" fix "$TMPROOT/d1.md")"
check "no findings after fix" "" "$(bash "$LINT" check "$TMPROOT/d1.md")"

# ---- Case 2: partial supersession keeps the entry active; full one does not
cat > "$TMPROOT/d2.md" <<'EOF'
## [2026-01-01] [rule] Keep
Superseded in part by: [2026-01-02] Narrow
## [2026-01-02] Narrow
Supersedes in part: [2026-01-01] Keep
## [2026-01-03] Gone
Superseded by: [2026-01-04] Next
## [2026-01-04] Next
Supersedes: [2026-01-03] Gone
EOF
check "partial and full markers satisfied" "" "$(bash "$LINT" check "$TMPROOT/d2.md")"

# ---- Case 3: citation without marker -> reported; with marker -> silent
cat > "$TMPROOT/d3.md" <<'EOF'
## [2026-10-22] Stack
OTEL_LOG_TOOL_DETAILS=1 on every machine.

## [2026-10-25] Correction
Corrects [2026-10-22]: one machine only.
Also mentions [2026-12-31] which does not exist.

## [2026-10-26] Marked
Supersedes: [2026-10-25] Correction
Replaces [2026-10-25].
EOF
r="$(bash "$LINT" check "$TMPROOT/d3.md")"
has "cite without marker reported" "DECISIONS_CITES_WITHOUT_MARKER=[2026-10-25] Correction cites [2026-10-22]" "$r"
lacks "unknown date not reported" "2026-12-31" "$r"
lacks "marked entry not reported as cite" "[2026-10-26] Marked cites" "$r"
has "render gives the one-line message" "entry [2026-10-25] Correction cites [2026-10-22] without a Supersedes marker; run lore decide --supersedes or edit" "$(printf '%s\n' "$r" | bash "$LINT" render)"

# ---- Case 4: bullet format counted; missing/empty file
printf '# D\n- [2026-10-01] one\n- [2026-10-02] two\n- [2026-10-03] three\n' > "$TMPROOT/d4.md"
check "bullet entries counted" "DECISIONS_BULLETS=3" "$(bash "$LINT" check "$TMPROOT/d4.md")"
check "missing file" "DECISIONS_FILE=missing" "$(bash "$LINT" check "$TMPROOT/nope.md")"
: > "$TMPROOT/d5.md"
check "empty file" "DECISIONS_FILE=empty" "$(bash "$LINT" check "$TMPROOT/d5.md")"

# ---- Case 5: caps (16 active [rule], 61 active entries; superseded ones do not count)
{ i=1; while [ $i -le 16 ]; do printf '## [2026-02-%02d] [rule] Rule %d\nbody\n' "$i" "$i"; i=$((i+1)); done
  printf '## [2026-03-01] [rule] Retired\nSuperseded by: [2026-03-02] Other\n'; } > "$TMPROOT/d6.md"
check "rule cap reported with active count only" "DECISIONS_OVER_RULE_CAP=16" "$(bash "$LINT" check "$TMPROOT/d6.md")"
{ i=1; while [ $i -le 61 ]; do printf '## [2026-04-01] Entry %d\nbody\n' "$i"; i=$((i+1)); done; } > "$TMPROOT/d7.md"
check "entry cap reported" "DECISIONS_OVER_CAP=61" "$(bash "$LINT" check "$TMPROOT/d7.md")"

# ---- lore decide: writer
cd "$F_PROJECT" || exit 1
unset DISPLAY_NAME
r="$(bash "$DECIDE" "First: initial body" 2>&1)"
has "decide applies" "OUTCOME=applied" "$r"
has "decide creates a protocol heading" "## [$(date +%Y-%m-%d)] First" "$(cat "$DEC")"
check "decide commits the vault" "1" "$($GIT log --oneline -- projects/fixture/decisions.md | grep -c 'decide')"
check "decide is idempotent for the same entry" "OUTCOME=unchanged" "$(bash "$DECIDE" "First: initial body" | head -n 1)"
r="$(bash "$DECIDE" "Second: replaces first" --supersedes "$(date +%Y-%m-%d) First" --rule 2>&1)"
has "decide with supersedes applies" "OUTCOME=applied" "$r"
has "new entry has rule tag and marker" "[rule] Second" "$(cat "$DEC")"
check "both markers present" "2" "$(grep -c '^Supersede[sd]\( by\)\?: ' "$DEC")"
check "supersedes target missing exits 10" "10" "$(bash "$DECIDE" "Third: x" --supersedes "1999-01-01 Nope" >/dev/null 2>&1; echo $?)"
# rule cap: warn, still append
i=1; while [ $i -le 15 ]; do bash "$DECIDE" "R$i: rule" --rule >/dev/null 2>&1; i=$((i+1)); done
r="$(bash "$DECIDE" "R16: rule" --rule 2>&1)"
has "16th active rule warns" "DECISIONS_OVER_RULE_CAP=" "$r"
has "16th active rule is still written" "[rule] R16" "$(cat "$DEC")"

# ---- cap: over 60 active, fully superseded entries move to the archive
{ i=1; while [ $i -le 60 ]; do printf '## [2026-05-01] Active %d\nbody\n' "$i"; i=$((i+1)); done
  printf '## [2026-04-01] Old one\nSuperseded by: [2026-05-01] Active 1\nold body\n'; } > "$DEC"
bash "$DECIDE" "Trigger: pushes over the cap" 2>&1 | grep -q 'ARCHIVED=1' && ok "archive moves the superseded entry" || bad "archive moves the superseded entry"
check "archived entry left decisions.md" "0" "$(grep -c 'Old one' "$DEC")"
check "archived entry is in decisions-archive.md" "1" "$(grep -c 'Old one' "$PDIR/decisions-archive.md")"

# ---- SessionEnd: inverse added to a hand-appended entry; cite reported at start
cat > "$DEC" <<'EOF'
# Decisions

## [2026-10-19] Old scope
Old body.
EOF
$GIT add projects/fixture/decisions.md >/dev/null; $GIT commit -q -m base
printf '\n## [2026-10-22] New scope\nSupersedes: [2026-10-19] Old scope\nNew body.\n\n## [2026-10-25] Drift\nContradicts [2026-10-19] silently.\n' >> "$DEC"
printf -- '---\ntitle: s\n---\n# Status\nLast updated: 2999-01-01 00:00 by x\n\n## Goal\n\n## Last checkpoint\n\n## Context refs\n' > "$PDIR/status.md"
printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$TMPROOT/hooks/lore-checkpoint.sh" >/dev/null 2>&1; sleep 1
check "SessionEnd adds the inverse marker" "Superseded by: [2026-10-22] New scope" "$(sed -n '/^## \[2026-10-19\]/{n;p;}' "$DEC")"
check "SessionEnd commits decisions.md" "" "$($GIT status --porcelain -- projects/fixture/decisions.md)"
has "finding file records the unmarked cite" "[2026-10-25] Drift cites [2026-10-19]" "$(cat "$PDIR/.decisions-lint" 2>/dev/null)"
lacks "finding file holds no applied lines" "APPLIED" "$(cat "$PDIR/.decisions-lint" 2>/dev/null)"
o="$(printf '{"source":"startup"}' | bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null)"
has "SessionStart orientation prints the cite line" "cites [2026-10-19] without a Supersedes marker" "$o"
printf '{"cwd":"%s"}' "$F_PROJECT" | bash "$TMPROOT/hooks/lore-checkpoint.sh" >/dev/null 2>&1; sleep 1
check "next SessionEnd clears the finding once committed" "no" "$([ -f "$PDIR/.decisions-lint" ] && echo yes || echo no)"

echo "---"; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
