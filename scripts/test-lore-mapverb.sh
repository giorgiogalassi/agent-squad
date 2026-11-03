#!/usr/bin/env bash
# Tests `lore map` (#429): first-contact mapping verb of claude/hooks/lore.
# Plain bash 3.2; fixture vaults only, HOME and vault env point at temp dirs.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-mapverb TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
export SQUAD_INCIDENTS=off
export HOME="$TMP/home"; mkdir -p "$HOME"
export XDG_DATA_HOME="$TMP/xdg"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name t
git config --file "$GIT_CONFIG_GLOBAL" user.email t@t
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
LORE="$REPO_ROOT/claude/hooks/lore"

mkrepo() { mkdir -p "$1"; git -C "$1" init -q; }
mkvault() {
  mkdir -p "$1/projects"; git -C "$1" init -q
  printf '{"projects":{"/other":"other"},"state_dir":".lore"}\n' > "$1/lore-config.json"
  printf 'lore-config.local.json*\n' > "$1/.gitignore"
  git -C "$1" add -A; git -C "$1" commit -qm init
}
map() {  # map <vault> args...: run lore map against vault $1
  local v="$1"; shift
  SECOND_BRAIN_PATH="$v" bash "$LORE" map "$@" 2>"$TMP/err"
}

# unmapped repo, no conflict
V="$TMP/v1"; mkvault "$V"; R="$TMP/work/demo"; mkrepo "$R"
out="$(map "$V" --root "$R")"; rc=$?
check "map exits 0" 0 "$rc"
has "applied" "OUTCOME=applied" "$out"
has "NAME" "NAME=demo" "$out"
has "TARGET tracked" "TARGET=tracked" "$out"
has "ROOT" "ROOT=" "$out"
check "project dir exists" yes "$([ -d "$V/projects/demo" ] && echo yes)"
check "mapping committed" "" "$(git -C "$V" status --porcelain lore-config.json)"
check "mapping in config" demo "$(jq -r '.projects | to_entries[] | select(.value=="demo") | .value' "$V/lore-config.json")"
head0="$(git -C "$V" rev-parse HEAD)"
out="$(map "$V" --root "$R")"
has "second run unchanged" "OUTCOME=unchanged" "$out"
has "second run keeps NAME" "NAME=demo" "$out"
check "second run writes no commit" "$head0" "$(git -C "$V" rev-parse HEAD)"

# conflict
V="$TMP/v2"; mkvault "$V"; mkdir -p "$V/projects/demo"; R="$TMP/work2/demo"; mkrepo "$R"
cp "$V/lore-config.json" "$TMP/cfg.before"
out="$(map "$V" --root "$R")"; rc=$?
check "conflict exits 10" 10 "$rc"
has "NEED=name" "NEED=name" "$out"
has "SUGGESTED" "SUGGESTED=demo-2" "$out"
cmp -s "$V/lore-config.json" "$TMP/cfg.before" && ok "conflict writes nothing" || bad "conflict wrote config"
check "conflict creates no demo-2" no "$([ -d "$V/projects/demo-2" ] && echo yes || echo no)"
out="$(map "$V" --root "$R" --name demo-2)"; rc=$?
check "--name resolves conflict" 0 "$rc"
has "chosen name" "NAME=demo-2" "$out"

# no vault
V="$TMP/v3"; R="$TMP/work3/demo"; mkrepo "$R"
out="$(map "$V" --root "$R")"; rc=$?
check "no vault exits 10" 10 "$rc"
has "NEED=vault" "NEED=vault" "$out"
check "no vault: nothing created" no "$([ -e "$V" ] && echo yes || echo no)"
out="$(map "$V" --root "$R" --create-vault)"; rc=$?
check "--create-vault exits 0" 0 "$rc"
check "vault created" yes "$([ -d "$V/.git" ] && echo yes)"
check "state_dir .lore" ".lore" "$(jq -r '.state_dir' "$V/lore-config.json")"
check "vault clean after create" "" "$(git -C "$V" status --porcelain)"
check "project mapped" demo "$(jq -r '.projects[]' "$V/lore-config.json")"
# event then fold land under .lore
# (event + fold landing under .lore is asserted once #423 merges.)
out="$(cd "$R" && SECOND_BRAIN_PATH="$V" bash "$REPO_ROOT/claude/hooks/path-resolve.sh" 2>/dev/null | sed -n 's/^STATE_DIR=//p')"
check "STATE_DIR uses .lore" "$(cd "$V" && pwd -P)/projects/demo/.lore" "$out"

# legacy in-repo .squad
V="$TMP/v4"; mkvault "$V"; R="$TMP/work4/demo"; mkrepo "$R"; mkdir -p "$R/.squad"
cp "$V/lore-config.json" "$TMP/cfg.before"
out="$(map "$V" --root "$R")"; rc=$?
check "legacy exits 10" 10 "$rc"
has "NEED=migrate" "NEED=migrate" "$out"
cmp -s "$V/lore-config.json" "$TMP/cfg.before" && ok "legacy writes nothing" || bad "legacy wrote config"
check "legacy creates no project" no "$([ -d "$V/projects/demo" ] && echo yes || echo no)"
# context: repo is not legacy
jq --arg r "$R" '.context[$r]="repo"' "$V/lore-config.json" > "$TMP/c.json" && mv "$TMP/c.json" "$V/lore-config.json"
git -C "$V" commit -qam ctx
out="$(map "$V" --root "$R")"; rc=$?
check "context repo maps" 0 "$rc"

# --create-vault + legacy .squad against a missing vault: nothing is created
V="$TMP/v8"; R="$TMP/work8/demo"; mkrepo "$R"; mkdir -p "$R/.squad"
out="$(map "$V" --root "$R" --create-vault)"; rc=$?
check "create-vault + legacy exits 10" 10 "$rc"
has "create-vault + legacy NEED=migrate" "NEED=migrate" "$out"
check "create-vault + legacy: vault not created" no "$([ -e "$V" ] && echo yes || echo no)"

# --adopt re-attaches an existing folder no other root maps
V="$TMP/v9"; mkvault "$V"; mkdir -p "$V/projects/demo"; R="$TMP/moved/demo2"; mkrepo "$R"
out="$(map "$V" --root "$R" --adopt --name demo)"; rc=$?
check "adopt exits 0" 0 "$rc"
has "adopt applied" "OUTCOME=applied" "$out"
has "adopt NAME" "NAME=demo" "$out"
check "adopt maps the root" demo "$(jq -r '.projects[]|select(.=="demo")' "$V/lore-config.json")"
# adopt refuses a folder another root maps
V="$TMP/v10"; mkvault "$V"; mkdir -p "$V/projects/other"; R="$TMP/moved/x"; mkrepo "$R"
cp "$V/lore-config.json" "$TMP/cfg.before"
out="$(map "$V" --root "$R" --adopt --name other)"; rc=$?
check "adopt of owned project exits 10" 10 "$rc"
has "adopt of owned project NEED=name" "NEED=name" "$out"
cmp -s "$V/lore-config.json" "$TMP/cfg.before" && ok "adopt refusal writes nothing" || bad "adopt refusal wrote config"
# adopt of a missing folder is a usage error
out="$(map "$V" --root "$R" --adopt --name nothere)"; rc=$?
check "adopt of missing folder exits 2" 2 "$rc"
map "$V" --root "$R" --adopt >/dev/null; check "adopt without name exits 2" 2 "$?"

# root is the vault
V="$TMP/v5"; mkvault "$V"
out="$(map "$V" --root "$V")"; rc=$?
check "root is vault exits 2" 2 "$rc"

# --local
V="$TMP/v6"; mkvault "$V"; R="$TMP/work6/demo"; mkrepo "$R"
cp "$V/lore-config.json" "$TMP/cfg.before"
out="$(map "$V" --root "$R" --local)"; rc=$?
check "--local exits 0" 0 "$rc"
has "TARGET local" "TARGET=local" "$out"
check "local file has mapping" demo "$(jq -r '.projects[]' "$V/lore-config.local.json")"
cmp -s "$V/lore-config.json" "$TMP/cfg.before" && ok "--local leaves tracked config" || bad "--local changed tracked config"
out="$(map "$V" --root "$R")"
has "local rerun unchanged" "OUTCOME=unchanged" "$out"
has "local rerun target" "TARGET=local" "$out"

# off-default branch: refusal surfaces, no success claim
V="$TMP/v7"; mkvault "$V"; R="$TMP/work7/demo"; mkrepo "$R"
git -C "$V" checkout -q -b side
out="$(map "$V" --root "$R")"; rc=$?
check "off-default exits 10" 10 "$rc"
case "$out" in *OUTCOME=applied*) bad "off-default must not claim applied" ;; *) ok "off-default no applied" ;; esac

# usage
bash "$LORE" map --bogus >/dev/null 2>&1; check "unknown option exits 2" 2 "$?"

echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
