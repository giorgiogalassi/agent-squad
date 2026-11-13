#!/usr/bin/env bash
# Tests claude/hooks/lore-status-seed.sh (#465): /seed's status.md is dated and
# agrees with the INDEX row; an existing status.md is untouched. Bash 3.2.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-status-seed
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in [$3])" ;; *) ok "$1" ;; esac; }

export SQUAD_INCIDENTS=off
mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{lore,lore-status-seed.sh,vault-check.sh,decisions-lint.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
SS="$TMPROOT/hooks/lore-status-seed.sh"
VC="$TMPROOT/hooks/vault-check.sh"
V="$TMPROOT/v"; mkdir -p "$V"
TODAY="$(date '+%Y-%m-%d')"
printf '# Second Brain\n\n## Projects\n\n| Project | Status | Last updated |\n|---------|--------|--------------|\n| [[projects/p/status\\|p]] | active | %s |\n' "$TODAY" > "$V/INDEX.md"
printf '# Decisions -- p\n' > "$TMPROOT/dec.md"
mkdir -p "$V/projects/p"; cp "$TMPROOT/dec.md" "$V/projects/p/decisions.md"

out="$(bash "$SS" --vault "$V" --project p --goal "Reservation app for restaurants")"
has "new status: applied" "OUTCOME=applied" "$out"
S="$V/projects/p/status.md"
has "dated Last updated" "Last updated: $TODAY " "$(cat "$S")"
check "stamp format" "1" "$(grep -cE '^Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} by seed$' "$S")"
check "goal filled" "Reservation app for restaurants" "$(awk '/^## Goal/{getline; print; exit}' "$S")"

vc="$(bash "$VC" check --vault "$V" --project p 2>&1)"
lacks "no INDEX row date finding" "INDEX_ROW" "$vc"
# Old template (undated) reproduces the finding.
printf "# Status\nLast updated: \xe2\x80\x94 by \xe2\x80\x94\n" > "$V/projects/p/status.md"
has "undated status trips INDEX_ROW_BEHIND" "INDEX_ROW_BEHIND" "$(bash "$VC" check --vault "$V" --project p 2>&1)"
rm "$V/projects/p/status.md"; bash "$SS" --vault "$V" --project p >/dev/null
S="$V/projects/p/status.md"

# Re-seed: untouched.
sum="$(cksum < "$S")"
out="$(bash "$SS" --vault "$V" --project p --goal "other")"
has "existing: unchanged" "OUTCOME=unchanged" "$out"
check "existing status.md untouched" "$sum" "$(cksum < "$S")"

# No goal / multi-line goal.
out="$(bash "$SS" --vault "$V" --project q --goal "$(printf 'a\nb')")"
check "multi-line goal joined" "a b" "$(awk '/^## Goal/{getline; print; exit}' "$V/projects/q/status.md")"
bash "$SS" --vault "$V" --project r >/dev/null
check "no goal placeholder" "—" "$(awk '/^## Goal/{getline; print; exit}' "$V/projects/r/status.md")"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
