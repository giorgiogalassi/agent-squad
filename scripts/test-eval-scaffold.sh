#!/usr/bin/env bash
# Tests claude/evals/lib/scaffold-common.sh sandbox guard (#392). Plain bash 3.2.
# Every run uses a throwaway HOME under a mktemp root; never the real one.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-eval-scaffold
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

export SQUAD_INCIDENTS=off GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
unset SECOND_BRAIN_PATH SQUAD_EVAL_SANDBOX

# run_case <home> <cwd> [env...]: runs the worktree-orient scaffold. Sets RC, ERR.
run_case() {
  local h="$1" w="$2"; shift 2
  mkdir -p "$w"
  ERR="$(cd "$w" && env HOME="$h" SECOND_BRAIN_PATH="$h/second-brain" TMPDIR="$w" "$@" \
    bash "$REPO_ROOT/claude/evals/worktree-orient/scaffold.sh" 2>&1 >/dev/null)"
  RC=$?
}
populate() {  # a fake "real" vault with a populated config
  mkdir -p "$1/second-brain/projects/realproj"
  printf '{"projects":{"/real/a":"realproj","/real/b":"other"},"vault_main":"direct"}\n' > "$1/second-brain/lore-config.json"
  echo keep > "$1/second-brain/projects/realproj/status.md"
}

# 1. Real-looking HOME, manual run (cwd not $HOME/cwd, no opt-in): refused.
H="$TMPROOT/h1"; populate "$H"; cp "$H/second-brain/lore-config.json" "$TMPROOT/cfg1"
run_case "$H" "$TMPROOT/w1"
check "manual run exits non-zero" 1 "$RC"
case "$ERR" in *"refusing to run outside the eval sandbox"*) ok "clear message" ;; *) bad "message: $ERR" ;; esac
cmp -s "$H/second-brain/lore-config.json" "$TMPROOT/cfg1" && ok "config byte-identical" || bad "config changed"
[ ! -e "$H/second-brain/projects/projects" ] && [ ! -e "$H/second-brain/projects/fixture" ] && ok "no projects/projects or fixture" || bad "projects polluted"

# 2. Even inside the sandbox signal, a non-fixture config is never overwritten.
H="$TMPROOT/h2"; populate "$H"; cp "$H/second-brain/lore-config.json" "$TMPROOT/cfg2"
run_case "$H" "$TMPROOT/w2" SQUAD_EVAL_SANDBOX=1
check "non-fixture config: exits non-zero" 1 "$RC"
cmp -s "$H/second-brain/lore-config.json" "$TMPROOT/cfg2" && ok "non-fixture config untouched" || bad "non-fixture config changed"
[ ! -e "$H/second-brain/projects/projects" ] && ok "no projects/projects (guard 2)" || bad "projects/projects created"

# 3. Sandboxed HOME laid out like the eval ($HOME/cwd): fixture built.
H="$TMPROOT/h3"; mkdir -p "$H"
run_case "$H" "$H/cwd"
check "eval layout builds fixture" 0 "$RC"
[ -f "$H/second-brain/projects/fixture/.squad/chisel-config.json" ] && ok "projects/fixture/.squad copied" || bad "fixture missing"
[ ! -e "$H/second-brain/projects/projects" ] && ok "no projects/projects" || bad "projects/projects exists"
grep -q '"fixture"' "$H/second-brain/lore-config.json" && ok "lore-config maps fixture" || bad "lore-config content"
[ -L "$H/cwd/project" ] && [ -L "$H/cwd/worktree" ] && ok "project/worktree symlinks" || bad "symlinks"

# 4. Re-run over its own fixture config (explicit opt-in, fixture-only config) works.
run_case "$H" "$H/cwd" SQUAD_EVAL_SANDBOX=1
check "rerun over fixture-only config" 0 "$RC"

# 5. Explicit opt-in on an empty throwaway HOME works.
H="$TMPROOT/h5"; mkdir -p "$H"
run_case "$H" "$TMPROOT/w5" SQUAD_EVAL_SANDBOX=1
check "opt-in builds fixture" 0 "$RC"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
