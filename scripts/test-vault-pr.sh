#!/usr/bin/env bash
# Tests vault writes on a branch + PR when the vault's main takes PRs only (#350):
# claude/hooks/squad-common.sh (squad_vault_*), vault-pr.sh, lore-decide.sh.
# Plain bash 3.2; fixture vaults with a bare origin and a fake gh; never touches
# ~/second-brain.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-vault-pr.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

export SQUAD_INCIDENTS=off GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
mkdir -p "$TMPROOT/hooks" "$TMPROOT/bin"
cp "$REPO_ROOT"/claude/hooks/{lore-decide.sh,vault-pr.sh,decisions-lint.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
cat > "$TMPROOT/hooks/path-resolve.sh" <<'EOP'
#!/usr/bin/env bash
echo "VAULT_PATH=$SECOND_BRAIN_PATH"; echo "PROJECT_ROOT=$PWD"
echo "DISPLAY_NAME=proj"; echo "SQUAD_DIR=$SECOND_BRAIN_PATH/projects/proj/.squad"
echo "TRACKER_MODE=${FAKE_TRACKER_MODE:-connected}"
EOP
cat > "$TMPROOT/bin/gh" <<'EOP'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr list") printf '%s' "${GH_OPEN:-}" ;;
  "pr create") echo "https://example.invalid/pull/7" ;;
  *) exit 1 ;;
esac
EOP
chmod +x "$TMPROOT/bin/gh"
export PATH="$TMPROOT/bin:$PATH" GH_LOG="$TMPROOT/gh.log"

mkvault() {  # mkvault <name> [config-json]: vault clone with a bare origin
  git init -q --bare -b main "$TMPROOT/$1-origin.git"
  git init -q -b main "$TMPROOT/$1"
  mkdir -p "$TMPROOT/$1/projects/proj"
  printf '# Decisions -- proj\n' > "$TMPROOT/$1/projects/proj/decisions.md"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$TMPROOT/$1/lore-config.json"
  git -C "$TMPROOT/$1" add -A && git -C "$TMPROOT/$1" commit -qm init
  git -C "$TMPROOT/$1" remote add origin "$TMPROOT/$1-origin.git"
  git -C "$TMPROOT/$1" push -q -u origin main 2>/dev/null
}
decide() {  # decide <vault> <text>
  (cd "$TMPROOT" && SECOND_BRAIN_PATH="$1" bash "$TMPROOT/hooks/lore-decide.sh" "$2" >/dev/null 2>&1)
}
level() {  # clean tree and local main == origin/main
  [ -z "$(git -C "$1" status --porcelain)" ] && [ "$(git -C "$1" rev-parse main)" = "$(git -C "$1" rev-parse origin/main)" ] && echo level || echo off
}
branches() { git -C "$1" for-each-ref --format='%(refname:short)' 'refs/heads/lore/*' | tr '\n' ' '; }

# 1. Setting on: three decisions, one branch, main untouched.
mkvault on '{"vault_main": "pr"}'; V="$TMPROOT/on"
decide "$V" "One: first"; decide "$V" "Two: second"; decide "$V" "Three: third"
check "pr: main clean and level with origin" level "$(level "$V")"
B="lore/proj-$(date +%Y-%m-%d)"
check "pr: one lore branch for three writes" "$B " "$(branches "$V")"
check "pr: three commits on the branch" 3 "$(git -C "$V" rev-list --count origin/main.."$B")"
n="$(git -C "$V" show "$B:projects/proj/decisions.md" | grep -c '^## \[')"
check "pr: all three entries on the branch" 3 "$n"
check "pr: entries not on main" 0 "$(grep -c '^## \[' "$V/projects/proj/decisions.md")"

# 2. Session end: pushed once, one PR; a second end updates, never re-creates.
: > "$GH_LOG"
(cd "$TMPROOT" && SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" finish >/dev/null 2>&1); rc=$?
check "finish: exit 0" 0 "$rc"
git -C "$V" ls-remote --exit-code origin "refs/heads/$B" >/dev/null 2>&1; check "finish: branch pushed" 0 $?
check "finish: one pr create" 1 "$(grep -c '^gh pr create' "$GH_LOG")"
check "finish: base is main" 1 "$(grep -c -- '--base main' "$GH_LOG")"
: > "$GH_LOG"; decide "$V" "Four: fourth"
(cd "$TMPROOT" && GH_OPEN=7 SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" finish >/dev/null 2>&1)
check "finish again: open PR is updated, not re-created" 0 "$(grep -c '^gh pr create' "$GH_LOG")"
check "finish again: still level" level "$(level "$V")"
: > "$GH_LOG"
(cd "$TMPROOT" && FAKE_TRACKER_MODE=detached SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" finish >/dev/null 2>&1)
check "finish detached: no gh call" 0 "$(wc -l < "$GH_LOG" | tr -d ' ')"

# 3. Setting off: today's behaviour, commit on main, no branch.
mkvault off; V="$TMPROOT/off"
decide "$V" "One: first"
check "off: commit on main" 2 "$(git -C "$V" rev-list --count main)"
check "off: no lore branch" "" "$(branches "$V")"
mkvault direct '{"vault_main": "direct"}'; V="$TMPROOT/direct"
printf '#!/bin/sh\nexit 1\n' > "$V/.git/hooks/pre-push"; chmod +x "$V/.git/hooks/pre-push"
decide "$V" "One: first"
check "direct: overrides a rejecting hook" "" "$(branches "$V")"

# 4. Detection from a pre-push hook that rejects refs/heads/main.
mkvault hook; V="$TMPROOT/hook"
cat > "$V/.git/hooks/pre-push" <<'EOP'
#!/bin/sh
while read -r l s r rs; do [ "$r" = refs/heads/main ] && { echo "main takes PRs only" >&2; exit 1; }; done
exit 0
EOP
chmod +x "$V/.git/hooks/pre-push"
decide "$V" "One: first"
check "hook: detected, main level" level "$(level "$V")"
check "hook: branch used" "$B " "$(branches "$V")"
mkvault okhook; V="$TMPROOT/okhook"
printf '#!/bin/sh\nexit 0\n' > "$V/.git/hooks/pre-push"; chmod +x "$V/.git/hooks/pre-push"
decide "$V" "One: first"
check "hook accepting main: direct" "" "$(branches "$V")"

# 5. vault-pr.sh commit (global preference path), PR mode.
mkvault glob '{"vault_main": "pr"}'; V="$TMPROOT/glob"
mkdir -p "$V/preferences"; printf -- '- [2026-10-28] [global] x\n' > "$V/preferences/development.md"
(cd "$TMPROOT" && SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" commit "[lore] pref" preferences/development.md >/dev/null 2>&1)
check "commit: main level" level "$(level "$V")"
check "commit: file on the branch" 1 "$(git -C "$V" show "$B:preferences/development.md" 2>/dev/null | grep -c global)"

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]
