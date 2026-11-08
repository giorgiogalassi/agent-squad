#!/usr/bin/env bash
# Tests claude/hooks/squad-env.sh: the SessionStart export of the resolved
# squad paths to $CLAUDE_ENV_FILE. Plain bash 3.2 + git; fixtures under one
# mktemp root, explicit git identity (CI has none).
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/squad-env.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-env

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
G() { git -c user.name=T -c user.email=t@example.com "$@"; }

# Plugin-like hooks dir copy: the hook finds path-resolve.sh next to itself.
mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT/claude/hooks/squad-env.sh" "$REPO_ROOT/claude/hooks/path-resolve.sh" "$REPO_ROOT/claude/hooks/squad-common.sh" "$REPO_ROOT/claude/hooks/lore" "$TMPROOT/hooks/"
mkdir -p "$TMPROOT/.claude-plugin"
cp "$REPO_ROOT/claude/.claude-plugin/plugin.json" "$TMPROOT/.claude-plugin/"
PLUGIN_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMPROOT/.claude-plugin/plugin.json" | head -n 1)"
# Never touch the real ~/.local/share/lore: every run gets its own data home.
export HOME="$TMPROOT/home"; mkdir -p "$HOME"
export XDG_DATA_HOME="$TMPROOT/xdg"
SHIM="$XDG_DATA_HOME/lore/bin/lore"
H="$TMPROOT/hooks/squad-env.sh"

VAULT="$TMPROOT/vault"
PROJ="$TMPROOT/my proj"          # space on purpose
mkdir -p "$VAULT/projects/proj/.squad" "$PROJ"
G init -q "$PROJ"
G -C "$PROJ" commit -q --allow-empty -m init
printf '{"chisel":{"mode":"connected"}}\n' > "$VAULT/projects/proj/.squad/chisel-config.json"
printf '{"projects":{"%s":"proj"}}\n' "$PROJ" > "$VAULT/lore-config.json"
G -C "$PROJ" worktree add -q "$TMPROOT/wt" -b wt-branch >/dev/null 2>&1

# run <cwd> <envfile>: feeds hook input with that cwd, like SessionStart does.
run() {
  (cd "$TMPROOT" && printf '{"cwd":"%s","source":"startup"}' "$1" \
    | SECOND_BRAIN_PATH="$VAULT" CLAUDE_ENV_FILE="$2" bash "$H"); echo $?
}
# val <envfile> <KEY>: evaluate the env file in a clean shell and print KEY.
val() { (env -i bash -c ". \"\$1\"; printf '%s' \"\${$2-UNSET}\"" _ "$1" 2>/dev/null); }

E="$TMPROOT/env1"; : > "$E"
rc="$(run "$PROJ" "$E")"
[ "$rc" = 0 ] && ok "startup: exit 0" || bad "startup: exit $rc"
[ "$(val "$E" SQUAD_PROJECT_ROOT)" = "$(cd "$PROJ" && pwd -P)" ] || [ "$(val "$E" SQUAD_PROJECT_ROOT)" = "$PROJ" ] \
  && ok "startup: SQUAD_PROJECT_ROOT survives a path with a space" || bad "startup: root '$(val "$E" SQUAD_PROJECT_ROOT)'"
[ "$(val "$E" SQUAD_DISPLAY_NAME)" = proj ] && ok "startup: SQUAD_DISPLAY_NAME" || bad "startup: display name"
[ "$(val "$E" SQUAD_VAULT_PATH)" = "$VAULT" ] && ok "startup: SQUAD_VAULT_PATH" || bad "startup: vault"
[ "$(val "$E" SQUAD_DIR)" = "$VAULT/projects/proj/.squad" ] && ok "startup: SQUAD_DIR" || bad "startup: dir '$(val "$E" SQUAD_DIR)'"
[ "$(val "$E" SQUAD_TRACKER_MODE)" = connected ] && ok "startup: SQUAD_TRACKER_MODE" || bad "startup: mode"

# Idempotence: clear and compact re-fire the hook on the same file.
printf 'export OTHER=keepme\n' >> "$E"
run "$PROJ" "$E" >/dev/null; run "$PROJ" "$E" >/dev/null
n="$(grep -c '^export SQUAD_' "$E")"
[ "$n" = 8 ] && ok "clear/compact: still exactly 8 SQUAD_ lines" || bad "clear/compact: $n SQUAD_ lines"
grep -q '^export OTHER=keepme$' "$E" && ok "clear/compact: foreign lines kept" || bad "clear/compact: foreign line lost"

# Resume: the hook input says source=resume; the values are written the same.
R="$TMPROOT/envr"; : > "$R"
(cd "$TMPROOT" && printf '{"cwd":"%s","source":"resume"}' "$PROJ" | SECOND_BRAIN_PATH="$VAULT" CLAUDE_ENV_FILE="$R" bash "$H")
[ "$(val "$R" SQUAD_DISPLAY_NAME)" = proj ] && ok "resume: values written" || bad "resume: display name '$(val "$R" SQUAD_DISPLAY_NAME)'"

# Shim and LORE_BIN (#428).
[ "$(val "$E" LORE_BIN)" = "$SHIM" ] && ok "env: LORE_BIN is the shim path" || bad "env: LORE_BIN '$(val "$E" LORE_BIN)'"
[ -n "$(val "$E" LORE_STATE_DIR)" ] && [ "$(val "$E" LORE_STATE_DIR)" != UNSET ] && ok "env: LORE_STATE_DIR exported" || bad "env: LORE_STATE_DIR"
n="$(grep -c '^export LORE_BIN=' "$E")"
[ "$n" = 1 ] && ok "clear/compact: exactly one LORE_BIN line" || bad "clear/compact: $n LORE_BIN lines"
[ -x "$SHIM" ] && ok "shim: installed and executable" || bad "shim: missing or not executable"
[ "$("$SHIM" version 2>/dev/null | sed -n 's/^VERSION=//p')" = "$PLUGIN_VERSION" ] \
  && ok "shim: 'version' prints the plugin version" || bad "shim: version '$("$SHIM" version 2>&1)'"
grep -q "^LORE_VERSION='$PLUGIN_VERSION'$" "$SHIM" && grep -q '^LORE_PLUGIN_DIR=' "$SHIM" \
  && ok "shim: carries LORE_PLUGIN_DIR and LORE_VERSION" || bad "shim: header lines"

# A newer installed shim is never downgraded.
printf '#!/bin/sh\nLORE_PLUGIN_DIR=/nonexistent\nLORE_VERSION=9.0.0\nexit 0\n' > "$SHIM"
before="$(cat "$SHIM")"
run "$PROJ" "$E" >/dev/null
[ "$(cat "$SHIM")" = "$before" ] && ok "shim: newer shim (9.0.0) left unchanged" || bad "shim: newer shim was replaced"

# An older shim is replaced; a same-version shim is refreshed too.
printf '#!/bin/sh\nLORE_PLUGIN_DIR=/nonexistent\nLORE_VERSION=0.9.0\nexit 0\n' > "$SHIM"
run "$PROJ" "$E" >/dev/null
grep -q "^LORE_VERSION='$PLUGIN_VERSION'$" "$SHIM" && ok "shim: older shim replaced" || bad "shim: older shim kept"
printf '#!/bin/sh\nLORE_PLUGIN_DIR=/nonexistent\nLORE_VERSION=%s\nexit 0\n' "$PLUGIN_VERSION" > "$SHIM"
run "$PROJ" "$E" >/dev/null
grep -q '^LORE_PLUGIN_DIR=./nonexistent' "$SHIM" && bad "shim: same-version shim not refreshed" || ok "shim: same-version shim refreshed"
# Numeric, not lexical: 1.9.0 is older than 1.20.0.
printf '#!/bin/sh\nLORE_PLUGIN_DIR=/nonexistent\nLORE_VERSION=1.9.0\nexit 0\n' > "$SHIM"
run "$PROJ" "$E" >/dev/null
grep -q "^LORE_VERSION='$PLUGIN_VERSION'$" "$SHIM" && ok "shim: 1.9.0 compares older than $PLUGIN_VERSION" || bad "shim: lexical compare"

# Replacement while another process executes the shim in a loop: no failure.
printf '#!/bin/sh\nLORE_PLUGIN_DIR=/nonexistent\nLORE_VERSION=0.1.0\nexit 0\n' > "$SHIM"
( i=0; fails=0
  while [ $i -lt 150 ]; do "$SHIM" version >/dev/null 2>&1 || fails=$((fails+1)); i=$((i+1)); done
  echo "$fails" > "$TMPROOT/loop-fails" ) &
LP=$!
run "$PROJ" "$E" >/dev/null
wait "$LP"
[ "$(cat "$TMPROOT/loop-fails")" = 0 ] && ok "shim: replacement during concurrent execution, no failed run" || bad "shim: $(cat "$TMPROOT/loop-fails") failed runs during replace"
grep -q "^LORE_VERSION='$PLUGIN_VERSION'$" "$SHIM" && ok "shim: replacement completed" || bad "shim: replacement incomplete"
ls "$XDG_DATA_HOME/lore/bin" | grep -qv '^lore$' && bad "shim: temp file left behind" || ok "shim: no temp file left behind"

# Shim whose plugin dir is gone: `event` exits 0 silently, other verbs exit 20.
mv "$TMPROOT/hooks/lore" "$TMPROOT/hooks/lore.off"
out="$("$SHIM" event x 2>&1; echo "rc=$?")"
[ "$out" = "rc=0" ] && ok "shim: plugin gone, event exits 0 silently" || bad "shim: event '$out'"
out="$("$SHIM" commit 2>&1; echo "rc=$?")"
case "$out" in "lore: plugin not found at "*"rc=20") ok "shim: plugin gone, other verb exits 20 with a stderr line" ;; *) bad "shim: commit '$out'" ;; esac
mv "$TMPROOT/hooks/lore.off" "$TMPROOT/hooks/lore"

# No HOME and no XDG_DATA_HOME: no shim, no LORE_BIN.
NE="$TMPROOT/envnone"; : > "$NE"
(cd "$TMPROOT" && printf '{"cwd":"%s"}' "$PROJ" | env -u HOME -u XDG_DATA_HOME SECOND_BRAIN_PATH="$VAULT" CLAUDE_ENV_FILE="$NE" bash "$H")
grep -q '^export LORE_BIN=' "$NE" && bad "env: LORE_BIN exported without HOME/XDG" || ok "env: no LORE_BIN without HOME/XDG"
grep -q '^export SQUAD_DIR=' "$NE" && ok "env: other values still exported" || bad "env: nothing exported without HOME"

# Documented client snippet: no shim and no LORE_BIN is a silent no-op.
snip='"${LORE_BIN:-$HOME/.local/share/lore/bin/lore}" "$@"'
out="$(env -i HOME="$TMPROOT/nohome" PATH="$PATH" bash -c '
  L="${LORE_BIN:-$HOME/.local/share/lore/bin/lore}"; [ -x "$L" ] || exit 0; "$L" event x' 2>&1; echo "rc=$?")"
[ "$out" = "rc=0" ] && [ ! -e "$TMPROOT/nohome/.local" ] && ok "client snippet: no shim exits 0, writes nothing" || bad "client snippet: '$out'"

# Linked worktree resolves to the main project.
W="$TMPROOT/env2"; : > "$W"
run "$TMPROOT/wt" "$W" >/dev/null
[ "$(val "$W" SQUAD_DISPLAY_NAME)" = proj ] && [ "$(val "$W" SQUAD_DIR)" = "$VAULT/projects/proj/.squad" ] \
  && ok "linked worktree: resolves to the main project" || bad "linked worktree: name '$(val "$W" SQUAD_DISPLAY_NAME)' dir '$(val "$W" SQUAD_DIR)'"
[ "$(val "$W" SQUAD_PROJECT_ROOT)" != "$TMPROOT/wt" ] && ok "linked worktree: root is not the worktree path" || bad "linked worktree: root is the worktree"

# Quoting: single quote in a path, and no command execution.
QP="$TMPROOT/it's \$(touch $TMPROOT/pwned) proj"
mkdir -p "$QP"; G init -q "$QP"
Q="$TMPROOT/env3"; : > "$Q"
run "$QP" "$Q" >/dev/null
[ "$(val "$Q" SQUAD_PROJECT_ROOT)" = "$(cd "$QP" && pwd -P)" ] || [ "$(val "$Q" SQUAD_PROJECT_ROOT)" = "$QP" ] \
  && ok "quoting: quote and \$() in a path round-trip" || bad "quoting: '$(val "$Q" SQUAD_PROJECT_ROOT)'"
[ ! -e "$TMPROOT/pwned" ] && ok "quoting: nothing executed" || bad "quoting: command substitution ran"
grep -Evq '^export (SQUAD_(VAULT_PATH|PROJECT_ROOT|DISPLAY_NAME|DIR|TRACKER_MODE|STATE_DIR|TRACKER_PROVIDER|VCS_PROVIDER)|LORE_(STATE_DIR|BIN))=' "$Q" \
  && bad "quoting: unexpected key in env file" || ok "quoting: only well-formed SQUAD_ keys written"

# Missing CLAUDE_ENV_FILE: no-op, exit 0, nothing written.
out="$(cd "$TMPROOT" && printf '{"cwd":"%s"}' "$PROJ" | env -u CLAUDE_ENV_FILE SECOND_BRAIN_PATH="$VAULT" bash "$H" 2>&1; echo "rc=$?")"
[ "$out" = "rc=0" ] && ok "no CLAUDE_ENV_FILE: silent no-op, exit 0" || bad "no CLAUDE_ENV_FILE: '$out'"

# Not in a git repo: nothing resolved, exit 0, file untouched.
N="$TMPROOT/env4"; : > "$N"; mkdir -p "$TMPROOT/plain"
rc="$(run "$TMPROOT/plain" "$N")"
[ "$rc" = 0 ] && ok "non-repo: exit 0" || bad "non-repo: exit $rc"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
