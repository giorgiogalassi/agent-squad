#!/usr/bin/env bash
# Tests STATE_DIR resolution (claude/hooks/path-resolve.sh), its SessionStart
# export (squad-env.sh) and lint check 12 (no literal state dir in hooks).
# Plain bash + git + coreutils; fixtures under one mktemp root, synthetic names.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PR="$REPO_ROOT/claude/hooks/path-resolve.sh"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-state-dir TMP
# squad-env.sh installs the lore shim under HOME/XDG_DATA_HOME: keep it in the temp dir.
mkdir -p "$TMP/home"; export HOME="$TMP/home" XDG_DATA_HOME="$TMP/xdg"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

mkproj() { mkdir -p "$1"; git init -q "$1/demo"; }
# resolve <vault> [env...]: run path-resolve.sh for demo with a clean env
resolve() {
  local v="$1"; shift
  (cd "$TMP/p/demo" && env "$@" SECOND_BRAIN_PATH="$v" bash "$PR" 2>/dev/null)
}
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
mkproj "$TMP/p"

# 1. existing vault, no key -> .squad
V1="$TMP/v1"; mkdir -p "$V1/projects/demo/.squad"
O="$(resolve "$V1")"
case "$(val "$O" STATE_DIR)" in */projects/demo/.squad) ok "no key + existing .squad dir -> .squad" ;; *) bad "fallback .squad: $O" ;; esac
[ -d "$V1/projects/demo/.squad" ] && [ ! -e "$V1/projects/demo/.lore" ] && ok "no file moved or created" || bad "moved"

# 2. explicit key wins; SQUAD_DIR unchanged
V2="$TMP/v2"; mkdir -p "$V2/projects/demo/.squad"
printf '{"state_dir": ".lore"}\n' > "$V2/lore-config.json"
O="$(resolve "$V2")"
case "$(val "$O" STATE_DIR)" in */projects/demo/.lore) ok "state_dir key -> .lore" ;; *) bad "key: $O" ;; esac
[ "$(val "$O" SQUAD_DIR)" = "$V2/projects/demo/.squad" ] && ok "SQUAD_DIR unchanged with key" || bad "SQUAD_DIR: $O"

# 3. empty vault, no key -> .lore
V3="$TMP/v3"; mkdir -p "$V3"
O="$(resolve "$V3")"
case "$(val "$O" STATE_DIR)" in */projects/demo/.lore) ok "no projects, no key -> .lore" ;; *) bad "empty vault: $O" ;; esac

# 4. context: repo
V4="$TMP/v4"; mkdir -p "$V4"
ROOTP="$(cd "$TMP/p/demo" && pwd -P)"
printf '{"context": {"%s": "repo"}}\n' "$ROOTP" > "$V4/lore-config.json"
O="$(resolve "$V4")"
[ "$(val "$O" SQUAD_DIR)" = "$ROOTP/.squad" ] && ok "context repo: SQUAD_DIR in repo" || bad "repo SQUAD_DIR: $O"
case "$(val "$O" STATE_DIR)" in "$V4"/projects/*) ok "context repo: STATE_DIR in vault" ;; *) bad "repo STATE_DIR: $O" ;; esac

# 5. env and flags cannot change the name; invalid key ignored
O1="$(resolve "$V2" LORE_STATE_DIR=.other SQUAD_STATE_DIR=.other STATE_DIR=.other)"
O2="$(resolve "$V2")"
[ "$(val "$O1" STATE_DIR)" = "$(val "$O2" STATE_DIR)" ] && ok "client env does not change STATE_DIR" || bad "env leak"
V5="$TMP/v5"; mkdir -p "$V5"; printf '{"state_dir": "a/b"}\n' > "$V5/lore-config.json"
case "$(val "$(resolve "$V5")" STATE_DIR)" in */projects/demo/.lore) ok "multi-segment key ignored" ;; *) bad "multi-segment" ;; esac

# 6. --state-name
[ "$(SECOND_BRAIN_PATH="$V1" bash "$PR" --state-name)" = ".squad" ] && ok "--state-name prints the name" || bad "--state-name"

# 7. squad-env exports both names
EF="$TMP/envfile"; : > "$EF"
(cd "$TMP/p/demo" && SECOND_BRAIN_PATH="$V2" CLAUDE_ENV_FILE="$EF" bash "$REPO_ROOT/claude/hooks/squad-env.sh" </dev/null)
grep -q "^export SQUAD_STATE_DIR='$V2/projects/demo/.lore'" "$EF" && grep -q "^export LORE_STATE_DIR='$V2/projects/demo/.lore'" "$EF" \
  && ok "squad-env exports SQUAD_STATE_DIR and LORE_STATE_DIR" || bad "env export: $(cat "$EF")"

# 8. lint check 12
fixture() { mkdir -p "$1/scripts"; cp -R "$REPO_ROOT/claude" "$1/claude"; cp "$REPO_ROOT/scripts/lint-allowlist-1b.txt" "$REPO_ROOT/scripts/test-squad-labels.sh" "$1/scripts/"; cp -R "$REPO_ROOT/scripts/lib" "$1/scripts/lib"; cp "$REPO_ROOT"/*.md "$1/" 2>/dev/null; return 0; }
c12() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$1" 2>&1 | sed -n '/== 12/,/== summary/p'; }
fixture "$TMP/a"
c12 "$TMP/a" | grep -q '\[FAIL\]' && bad "pristine tree passes check 12" || ok "pristine tree passes check 12"
fixture "$TMP/b"
printf 'X="$VAULT/projects/$NAME/.squad/progress.txt"\n' >> "$TMP/b/claude/hooks/squad-route.sh"
c12 "$TMP/b" | grep -q 'squad-route.sh:[0-9]*: literal' && ok "literal state dir line is reported" || bad "literal not reported"
fixture "$TMP/c"
printf '# see .squad/ docs\n' >> "$TMP/c/claude/hooks/squad-route.sh"
c12 "$TMP/c" | grep -q '\[FAIL\]' && bad "comment line is not a violation" || ok "comment line is not a violation"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
