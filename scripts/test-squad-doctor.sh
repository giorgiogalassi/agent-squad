#!/usr/bin/env bash
# Tests claude/hooks/squad-doctor.sh (#119). Plain bash 3.2; never touches the real ~/.claude.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$REPO_ROOT/claude/hooks/squad-doctor.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-doctor.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

# Fake source repo with git history: one file is later deleted (orphan source).
SRC="$TMPROOT/src"
mkdir -p "$SRC/claude/agents" "$SRC/claude/skills/foo" "$SRC/claude/hooks"
echo agent > "$SRC/claude/agents/a.md"
echo skill > "$SRC/claude/skills/foo/SKILL.md"
echo hook > "$SRC/claude/hooks/h.sh"
echo gone > "$SRC/claude/agents/old.md"
git -C "$SRC" init -q
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q -m one
git -C "$SRC" -c user.email=t@t -c user.name=t rm -q claude/agents/old.md
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q -m two

fresh_home() {  # fresh_home <name> -> prints path of a fully fresh install
  local h="$TMPROOT/$1"
  mkdir -p "$h"
  cp -R "$SRC/claude/agents" "$SRC/claude/skills" "$SRC/claude/hooks" "$h/"
  echo "$SRC" > "$h/.agent-squad-source"
  echo "$h"
}
run() { SQUAD_DOCTOR_HOME="$1" bash "$DOC" 2>"$TMPROOT/err"; }
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
snapshot() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }

# fresh
H="$(fresh_home fresh)"
o="$(run "$H")"; rc=$?
[ "$rc" = 0 ] && [ "$(val "$o" STALE)" = 0 ] && [ "$(val "$o" CHECKED)" = yes ] && ok "fresh: STALE=0" || bad "fresh: $o"

# stale: modified file, missing agent, unrelated user file ignored
H="$(fresh_home stale)"
echo changed > "$H/agents/a.md"
echo user > "$H/agents/mine.md"
rm "$H/skills/foo/SKILL.md"
o="$(run "$H")"; rc=$?
[ "$rc" = 0 ] && [ "$(val "$o" STALE)" = 2 ] && ok "stale: STALE=2" || bad "stale count: $o"
printf '%s\n' "$o" | grep -qx 'STALE_FILE=agents/a.md' && ok "stale: names modified file" || bad "stale: modified not named"
printf '%s\n' "$o" | grep -qx 'STALE_FILE=skills/foo/SKILL.md' && ok "stale: names missing skill" || bad "stale: missing not named"
printf '%s\n' "$o" | grep -q 'mine.md' && bad "stale: flagged user file" || ok "stale: user file never shipped is ignored"

# hooks absent from install are optional, not stale
H="$(fresh_home hookopt)"; rm "$H/hooks/h.sh"
o="$(run "$H")"; [ "$(val "$o" STALE)" = 0 ] && ok "optional hook not installed is not stale" || bad "hook optional: $o"

# orphan: shipped once, removed from repo, still installed
H="$(fresh_home orphan)"
echo gone > "$H/agents/old.md"
o="$(run "$H")"
[ "$(val "$o" STALE)" = 1 ] && printf '%s\n' "$o" | grep -qx 'ORPHAN_FILE=agents/old.md' && ok "orphan: named and counted" || bad "orphan: $o"

# silent skips
H="$(fresh_home norec)"; rm "$H/.agent-squad-source"
o="$(run "$H")"; rc=$?
[ "$rc" = 0 ] && [ "$(val "$o" STALE)" = 0 ] && [ "$(val "$o" CHECKED)" = no ] && [ ! -s "$TMPROOT/err" ] && ok "missing record: silent" || bad "missing record: rc=$rc $o"
H="$(fresh_home norepo)"; echo "$TMPROOT/nowhere" > "$H/.agent-squad-source"
o="$(run "$H")"; rc=$?
[ "$rc" = 0 ] && [ "$(val "$o" CHECKED)" = no ] && [ ! -s "$TMPROOT/err" ] && ok "missing repo path: silent" || bad "missing repo: rc=$rc $o"
H="$(fresh_home nodir)"; rm -rf "$H/skills"
o="$(run "$H")"; rc=$?
[ "$rc" = 0 ] && [ "$(val "$o" CHECKED)" = no ] && [ ! -s "$TMPROOT/err" ] && ok "missing install subdir: silent" || bad "missing dir: rc=$rc $o"
o="$(run "$TMPROOT/does-not-exist")"; rc=$?
[ "$rc" = 0 ] && [ "$(val "$o" CHECKED)" = no ] && ok "missing install dir: silent" || bad "missing install dir: $o"

# usage
bash "$DOC" bogus >/dev/null 2>&1; [ "$?" = 2 ] && ok "usage: exit 2" || bad "usage exit"

# never modifies (install and source), even with stale + orphan
H="$(fresh_home nomod)"; echo changed > "$H/agents/a.md"; echo gone > "$H/agents/old.md"
b1="$(snapshot "$H")"; b2="$(snapshot "$SRC")"
run "$H" >/dev/null
[ "$b1" = "$(snapshot "$H")" ] && [ "$b2" = "$(snapshot "$SRC")" ] && ok "never modifies install or repo" || bad "modified files"

# stdout contract: only KEY=value lines
o="$(run "$H")"
printf '%s\n' "$o" | grep -qv '^[A-Z_]*=' && bad "stdout has non KEY=value line" || ok "stdout only KEY=value"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
