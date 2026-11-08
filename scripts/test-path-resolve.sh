#!/usr/bin/env bash
# Tests TRACKER_MODE resolution in claude/hooks/path-resolve.sh.
# Plain bash + git + coreutils; no bats. Fixtures live under one mktemp root.
set -u
# Never write the real vault incident store.
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PR="$REPO_ROOT/claude/hooks/path-resolve.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-path-resolve

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

PROJ="$TMPROOT/proj"
git init -q "$PROJ"
VAULT="$TMPROOT/vault"
CFG="$VAULT/projects/proj/.squad/chisel-config.json"
mkdir -p "$(dirname "$CFG")"

# Shim dir with every tool the script needs except jq.
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
for t in git dirname basename wc tr grep cat; do
  p="$(command -v "$t")" && ln -s "$p" "$SHIM/$t"
done

# run <path-for-PATH-or-empty>; sets OUT, ERR
run() {
  if [ -n "$1" ]; then
    OUT="$(cd "$PROJ" && SECOND_BRAIN_PATH="$VAULT" PATH="$1" "$BASH" "$PR" 2>"$TMPROOT/err")"
  else
    OUT="$(cd "$PROJ" && SECOND_BRAIN_PATH="$VAULT" "$BASH" "$PR" 2>"$TMPROOT/err")"
  fi
  ERR="$(cat "$TMPROOT/err")"
}

# check <name> <expected mode> <expected stderr line count> [PATH override]
check() {
  run "${4:-}"
  local mode lines errn
  mode="$(printf '%s\n' "$OUT" | sed -n 's/^TRACKER_MODE=//p')"
  lines="$(printf '%s\n' "$OUT" | grep -c '^[A-Z_]*=')"
  errn="$(printf '%s' "$ERR" | grep -c .)"
  if [ "$mode" = "$2" ] && [ "$lines" = "8" ] && [ "$errn" = "$3" ]; then
    ok "$1"
  else
    bad "$1 (mode=$mode lines=$lines stderr_lines=$errn)"
  fi
}

rm -f "$CFG"
check "missing file -> detached + 1 stderr line" detached 1

echo '{"chisel":{"repo":"x/y"}}' > "$CFG"
check "missing key -> detached + 1 stderr line" detached 1

echo '{"chisel":{"mode":"conected"}}' > "$CFG"
check "typo value -> detached + 1 stderr line" detached 1

echo '{"chisel":{"mode":"connected"}}' > "$CFG"
check "jq absent -> detached + 1 stderr line" detached 1 "$SHIM"

echo '{"chisel":{"mode":"detached"}}' > "$CFG"
check "explicit detached -> detached, silent" detached 0

if command -v jq >/dev/null 2>&1; then
  echo '{"chisel":{"mode":"connected"}}' > "$CFG"
  check "connected -> connected, silent" connected 0
else
  bad "connected case needs jq on PATH"
fi

# ---- lore-config.local.json (#355): untracked mappings merged over lore-config.json
if command -v jq >/dev/null 2>&1; then
  LOCAL="$VAULT/lore-config.local.json"; MAIN="$VAULT/lore-config.json"
  val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
  rm -f "$MAIN" "$LOCAL"
  printf '{"projects":{"%s":"secret-client"},"context":{"%s":"repo"}}\n' "$PROJ" "$PROJ" > "$LOCAL"
  run ""
  [ "$(val DISPLAY_NAME)" = "secret-client" ] && ok "local-only mapping -> DISPLAY_NAME" || bad "local-only mapping: $OUT"
  [ "$(val SQUAD_DIR)" = "$PROJ/.squad" ] && ok "local-only context repo -> SQUAD_DIR" || bad "local context: $OUT"
  [ "$(printf '%s\n' "$OUT" | grep -c '=')" = 8 ] && ok "eight output lines (incl. STATE_DIR, TRACKER_PROVIDER, VCS_PROVIDER)" || bad "output shape: $OUT"
  printf '{"projects":{"%s":"tracked-name"}}\n' "$PROJ" > "$MAIN"
  run ""
  [ "$(val DISPLAY_NAME)" = "secret-client" ] && ok "local mapping wins over tracked" || bad "merge precedence: $OUT"
  rm -f "$LOCAL"; run ""
  [ "$(val DISPLAY_NAME)" = "tracked-name" ] && ok "tracked mapping alone still works" || bad "tracked only: $OUT"
  printf 'not json' > "$LOCAL"; run ""
  [ "$(val DISPLAY_NAME)" = "tracked-name" ] && ok "invalid local file ignored" || bad "invalid local: $OUT"
else
  bad "local-config cases need jq on PATH"
fi

# --- #440: PR-mode mapping lives only on the open session branch ---------------
if command -v jq >/dev/null 2>&1; then
  H="$TMPROOT/hooks440"; mkdir -p "$H"
  cp "$REPO_ROOT"/claude/hooks/{lore,lore-map.sh,path-resolve.sh,squad-env.sh,squad-incidents.sh,squad-common.sh} "$H/"
  V4="$TMPROOT/v440"; R4="$TMPROOT/r440"; git init -q "$R4"
  mkdir -p "$V4"
  printf '{"projects":{},"vault_main":"pr"}\n' > "$V4/lore-config.json"
  git -C "$V4" init -q -b main
  git -C "$V4" add -A && git -C "$V4" -c user.email=t@t -c user.name=t commit -qm init
  CK="$(cat "$V4/lore-config.json")"
  bash "$H/lore-map.sh" set --vault "$V4" --root "$R4" --name pr-named >/dev/null 2>&1
  r440() { (cd "$R4" && SECOND_BRAIN_PATH="$V4" bash "$H/path-resolve.sh" 2>"$TMPROOT/err440"); }
  O="$(r440)"
  case "$O" in *"PROJECT_ROOT=$R4"*) ok "#440: PROJECT_ROOT kept" ;; *) bad "#440 root: $O" ;; esac
  case "$O" in *"DISPLAY_NAME=pr-named"*) ok "#440: mapping resolved from session worktree" ;; *) bad "#440 name: $O" ;; esac
  case "$O" in *"SQUAD_DIR=$V4/projects/pr-named/.squad"*) ok "#440: SQUAD_DIR uses mapped name" ;; *) bad "#440 dir: $O" ;; esac
  [ "$(cat "$V4/lore-config.json")" = "$CK" ] && [ -z "$(git -C "$V4" status --porcelain -- lore-config.json)" ] \
    && ok "#440: checkout lore-config.json unchanged" || bad "#440: checkout config changed"
  ENVF="$TMPROOT/env440"; : > "$ENVF"
  (cd "$R4" && HOME="$TMPROOT/home440" SECOND_BRAIN_PATH="$V4" CLAUDE_ENV_FILE="$ENVF" bash "$H/squad-env.sh" </dev/null)
  grep -q "^export SQUAD_PROJECT_ROOT='$R4'" "$ENVF" && grep -q "^export SQUAD_DISPLAY_NAME='pr-named'" "$ENVF" \
    && ok "#440: fresh squad-env exports the mapping" || bad "#440 env: $(cat "$ENVF")"
  # Two session branches, different names: newest wins, stderr names the conflict.
  W2="$V4/.claude/worktrees/lore-other-2099-01-01"
  git -C "$V4" worktree add -q -b lore/other-2099-01-01 "$W2" main
  jq --arg r "$R4" '.projects[$r]="newer-name"' "$W2/lore-config.json" > "$W2/c.tmp" && mv "$W2/c.tmp" "$W2/lore-config.json"
  GIT_COMMITTER_DATE="2099-01-01T00:00:00" git -C "$W2" -c user.email=t@t -c user.name=t commit -qam map
  O="$(r440)"
  case "$O" in *"DISPLAY_NAME=newer-name"*) ok "#440: newest session branch wins" ;; *) bad "#440 newest: $O" ;; esac
  grep -q "different names" "$TMPROOT/err440" && ok "#440: conflict named on stderr" || bad "#440 stderr: $(cat "$TMPROOT/err440")"
  # Merged and cleaned up: the checkout carries it.
  git -C "$V4" worktree remove --force "$W2"
  for w in "$V4"/.claude/worktrees/lore-*; do git -C "$V4" worktree remove --force "$w"; done
  jq --arg r "$R4" '.projects[$r]="pr-named"' "$V4/lore-config.json" > "$V4/c.tmp" && mv "$V4/c.tmp" "$V4/lore-config.json"
  O="$(r440)"
  case "$O" in *"DISPLAY_NAME=pr-named"*) ok "#440: resolution unchanged after cleanup (checkout)" ;; *) bad "#440 cleanup: $O" ;; esac
fi

# --- #440 fix round: non-git roots and canonical keys ---------------------------
if command -v jq >/dev/null 2>&1; then
  V5="$TMPROOT/v 440b"; N5="$TMPROOT/nongit440"; U5="$TMPROOT/unmapped440"; mkdir -p "$V5" "$N5" "$U5"
  printf '{"projects":{},"vault_main":"pr"}\n' > "$V5/lore-config.json"
  git -C "$V5" init -q -b main
  git -C "$V5" add -A && git -C "$V5" -c user.email=t@t -c user.name=t commit -qm init
  r5() { (cd "$1" && SECOND_BRAIN_PATH="$V5" bash "$H/path-resolve.sh" 2>/dev/null); }
  P5="$(cd "$N5" && pwd -P)"
  bash "$H/lore-map.sh" set --vault "$V5" --root "$N5" --name nongit-name >/dev/null 2>&1
  O="$(r5 "$N5")"
  case "$O" in *"PROJECT_ROOT=$P5"*"DISPLAY_NAME=nongit-name"*) ok "#440: non-git root resolves from session worktree (vault path with space)" ;; *) bad "#440 non-git session: $O" ;; esac
  case "$O" in *"SQUAD_DIR=$V5/projects/nongit-name/.squad"*) ok "#440: non-git SQUAD_DIR uses mapped name" ;; *) bad "#440 non-git dir: $O" ;; esac
  O="$(r5 "$U5")"
  case "$O" in *"PROJECT_ROOT="$'\n'*"DISPLAY_NAME="$'\n'*) ok "#440: unmapped non-git dir keeps PROJECT_ROOT empty" ;; *) bad "#440 unmapped: $O" ;; esac
  # Same mapping through the checkout config (merged PR, worktree cleaned up).
  for w in "$V5"/.claude/worktrees/lore-*; do git -C "$V5" worktree remove --force "$w"; done
  jq --arg r "$P5" '.projects[$r]="nongit-name"' "$V5/lore-config.json" > "$V5/c.tmp" && mv "$V5/c.tmp" "$V5/lore-config.json"
  O="$(r5 "$N5")"
  case "$O" in *"PROJECT_ROOT=$P5"*"DISPLAY_NAME=nongit-name"*) ok "#440: non-git root resolves from checkout config" ;; *) bad "#440 non-git checkout: $O" ;; esac
  # Non-physical spelling (symlink, /var vs /private/var) matches the canonical key.
  ln -s "$N5" "$TMPROOT/link440"
  O="$(r5 "$TMPROOT/link440")"
  case "$O" in *"PROJECT_ROOT=$P5"*"DISPLAY_NAME=nongit-name"*) ok "#440: symlinked root matches canonical key" ;; *) bad "#440 symlink: $O" ;; esac
  # lore map given a symlinked root stores the physical path.
  N6="$TMPROOT/nongit440b"; mkdir -p "$N6"; ln -s "$N6" "$TMPROOT/link440b"
  bash "$H/lore-map.sh" set --vault "$V5" --root "$TMPROOT/link440b" --name viaLink >/dev/null 2>&1
  W6="$(ls -d "$V5"/.claude/worktrees/lore-* | head -1)"
  [ "$(jq -r --arg r "$(cd "$N6" && pwd -P)" '.projects[$r]' "$W6/lore-config.json")" = viaLink ] \
    && ok "#440: lore map stores the physical root" || bad "#440 map canonical"
fi

# --- #441: no project -> no `projects//` path, no missing-config noise -----------
if command -v jq >/dev/null 2>&1; then
  V7="$TMPROOT/v441"; U7="$TMPROOT/unmapped441"; mkdir -p "$V7" "$U7"
  printf '{"projects":{}}\n' > "$V7/lore-config.json"
  O="$(cd "$U7" && SECOND_BRAIN_PATH="$V7" bash "$H/path-resolve.sh" 2>"$TMPROOT/err441")"
  case "$O" in *"projects//"*) bad "#441: output has projects//: $O" ;; *) ok "#441: no output line contains projects//" ;; esac
  case "$O" in *"SQUAD_DIR="$'\n'*"STATE_DIR="$'\n'*) ok "#441: SQUAD_DIR and STATE_DIR empty with no project" ;; *) bad "#441 empty dirs: $O" ;; esac
  case "$O" in *"TRACKER_MODE=detached"*) ok "#441: TRACKER_MODE detached" ;; *) bad "#441 mode: $O" ;; esac
  [ ! -s "$TMPROOT/err441" ] && ok "#441: no chisel-config.json not found on stderr" || bad "#441 stderr: $(cat "$TMPROOT/err441")"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
