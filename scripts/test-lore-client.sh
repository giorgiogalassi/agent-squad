#!/usr/bin/env bash
# Tests examples/lore-client (#430): a plugin that is not agent-squad writes only
# through the lore shim. Hook invocations are simulated (SubagentStop JSON on stdin,
# the skill's Bash step run directly); the real `claude` binary is never invoked.
# Plain bash 3.2; HOME, XDG and the vault are temp fixtures.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-client TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\|SECOND_BRAIN\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
export SQUAD_INCIDENTS=off
export HOME="$TMP/home"; mkdir -p "$HOME"
# No XDG_DATA_HOME: the client default path is $HOME/.local/share/lore/bin/lore.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name t
git config --file "$GIT_CONFIG_GLOBAL" user.email t@t
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
CLIENT="$REPO_ROOT/examples/lore-client"
HOOK="$CLIENT/hooks/checkpoint.sh"
SHIM="$HOME/.local/share/lore/bin/lore"

# --- source: no SQUAD_, no .squad, no git call ---
check "client source has no SQUAD_" 0 "$(grep -rl 'SQUAD_' "$CLIENT" | wc -l | tr -d ' ')"
check "client source has no .squad" 0 "$(grep -rl '\.squad' "$CLIENT" | wc -l | tr -d ' ')"
check "client source has no git" 0 "$(grep -rli 'git' "$CLIENT" | wc -l | tr -d ' ')"
check "client source has no vault path" 0 "$(grep -rlE 'second-brain|SECOND_BRAIN|projects/' "$CLIENT" | wc -l | tr -d ' ')"
check "client is outside claude/" 0 "$(find "$REPO_ROOT/claude" -path '*lore-client*' | wc -l | tr -d ' ')"
check "marketplace does not list the client" 0 "$(grep -c 'lore-client' "$REPO_ROOT/.claude-plugin/marketplace.json")"

# --- fixture vault and project ---
V="$TMP/vault"; mkdir -p "$V/projects"; git -C "$V" init -q
printf '{"projects":{},"state_dir":".lore"}\n' > "$V/lore-config.json"
printf 'lore-config.local.json*\n' > "$V/.gitignore"
git -C "$V" add -A; git -C "$V" commit -qm init
P="$TMP/work/clientproj"; mkdir -p "$P"; git -C "$P" init -q
payload() { printf '{"cwd":"%s","agent_type":"%s","hook_event_name":"SubagentStop"}' "$P" "$1"; }
inbox_count() { ls "$V"/projects/clientproj/.lore/inbox/*.ev 2>/dev/null | wc -l | tr -d ' '; }

# --- no shim, no LORE_BIN: exit 0, nothing written ---
export SECOND_BRAIN_PATH="$V"
payload lore-client-worker | bash "$HOOK" >/dev/null 2>&1; check "no shim: hook exits 0" 0 "$?"
check "no shim: nothing written" "" "$(find "$V/projects" -type f 2>/dev/null)"
LORE_CLIENT_CWD="$P" bash "$CLIENT/scripts/lore-event.sh" note k "x" >/dev/null 2>&1; check "no shim: skill step exits 0" 0 "$?"

# --- install the shim the way a session would (SessionStart of the plugin) ---
ENVF="$TMP/envfile"; : > "$ENVF"
printf '{"cwd":"%s","source":"startup"}' "$P" | CLAUDE_ENV_FILE="$ENVF" bash "$REPO_ROOT/claude/hooks/squad-env.sh" >/dev/null 2>&1
[ -x "$SHIM" ] && ok "shim installed by SessionStart" || bad "shim installed by SessionStart"

# --- unmapped project: hook and skill step leave the vault untouched (no first contact) ---
snap() { printf '%s|%s|%s|%s' "$(git -C "$V" rev-parse HEAD)" "$(cat "$V/lore-config.json")" "$(ls "$V/projects")" "$(git -C "$V" worktree list | wc -l | tr -d ' ')"; }
S0="$(snap)"
payload lore-client-worker | bash "$HOOK" >/dev/null 2>&1; check "unmapped: hook exits 0" 0 "$?"
( cd "$P" && bash "$CLIENT/scripts/lore-event.sh" note k "x" ) >/dev/null 2>&1; check "unmapped: skill step exits 0" 0 "$?"
check "unmapped: no commit, config, project dir or worktree" "$S0" "$(snap)"
check "unmapped: lore project exits 10" 10 "$(cd "$P" && bash "$SHIM" project >/dev/null 2>&1; echo $?)"
check "unmapped: still nothing written" "$S0" "$(snap)"

# first contact: lore map (what /lore start runs); the client itself never maps
( cd "$P" && bash "$SHIM" map >/dev/null 2>&1 ); check "project mapped" clientproj "$(jq -r '.projects | to_entries[0].value // empty' "$V/lore-config.json")"

# --- SubagentStop: own agent lands, others write nothing ---
payload other-plugin:worker | bash "$HOOK" >/dev/null 2>&1; check "other agent: exit 0" 0 "$?"
check "other agent: no event" 0 "$(inbox_count)"
payload "" | bash "$HOOK" >/dev/null 2>&1; check "no agent type: no event" 0 "$(inbox_count)"
payload lore-client-worker | bash "$HOOK" >/dev/null 2>&1; check "own agent: exit 0" 0 "$?"
check "own agent: one event" 1 "$(inbox_count)"
f="$(ls "$V"/projects/clientproj/.lore/inbox/*.ev)"
has "event kind checkpoint" "KIND=checkpoint" "$(cat "$f")"
has "event source lore-client" "SOURCE=lore-client" "$(cat "$f")"
payload lore-client:lore-client-worker | bash "$HOOK" >/dev/null 2>&1
check "prefixed agent name also lands" 2 "$(inbox_count)"

# --- skill Bash step (headless and interactive run the same step) ---
( cd "$P" && bash "$CLIENT/scripts/lore-event.sh" note lore-client-note "hello from the client" ) >/dev/null 2>&1
check "note event landed" 1 "$(grep -l 'KIND=note' "$V"/projects/clientproj/.lore/inbox/*.ev | wc -l | tr -d ' ')"
( cd "$P" && LORE_BIN="$SHIM" bash "$CLIENT/scripts/lore-event.sh" note k2 "via LORE_BIN" ) >/dev/null 2>&1
check "LORE_BIN honoured" 1 "$(grep -l 'via LORE_BIN' "$V"/projects/clientproj/.lore/inbox/*.ev | wc -l | tr -d ' ')"

# --- fold: lines are in the Other sources block and fenced on render ---
bash "$SHIM" fold --project clientproj >/dev/null 2>&1; check "fold exits 0" 0 "$?"
ST="$V/projects/clientproj/status.md"
has "note in status.md Other sources" "hello from the client" "$(awk '/^## Other sources/{s=1;next} /^## /{s=0} s' "$ST")"
has "checkpoint line in status.md" "[lore-client] lore-client-worker finished" "$(cat "$ST")"
. "$REPO_ROOT/claude/hooks/squad-common.sh"
R="$(squad_fence_render status "$ST")"
has "render: fenced block header" "### Other sources (third-party text" "$R"
has "render: note inside fence" "hello from the client" "$(printf '%s\n' "$R" | awk '/^```text/{s=1;next} /^```/{s=0} s')"
has "render: checkpoint inside fence" "lore-client-worker finished" "$(printf '%s\n' "$R" | awk '/^```text/{s=1;next} /^```/{s=0} s')"
O="$(cd "$P" && bash "$REPO_ROOT/claude/hooks/lore-orient.sh" </dev/null 2>/dev/null)"
has "orientation shows the fenced block" "hello from the client" "$O"

# --- SessionEnd rebuild keeps the block (stub claude, never the real one) ---
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/claude" <<'EOS'
#!/bin/sh
cat > /dev/null
printf -- '---\ntitle: s\n---\n# Status\nLast updated: x\n\n## Goal\nrebuilt\n\n## Done\n\n## Next\n\n## Blocked\n\n## Last checkpoint\n\n## Context refs\n'
EOS
chmod +x "$TMP/fakebin/claude"
sed -i.bak 's/^Last updated: .*/Last updated: 2020-01-01 00:00 by x/' "$ST" 2>/dev/null; rm -f "$ST.bak"
printf '{"cwd":"%s"}' "$P" | PATH="$TMP/fakebin:$PATH" bash "$REPO_ROOT/claude/hooks/lore-checkpoint.sh" >/dev/null 2>&1
has "rebuild: model output used" "rebuilt" "$(cat "$ST")"
has "rebuild: client note survives in Other sources" "hello from the client" "$(awk '/^## Other sources/{s=1;next} /^## /{s=0} s' "$ST")"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
