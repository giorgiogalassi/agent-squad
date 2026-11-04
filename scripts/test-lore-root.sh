#!/usr/bin/env bash
# Tests `lore root` and the session-worktree SQUAD_DIR (#443): in a PR-mode vault
# Seed, Forge, Archy and Chisel write into the project's session worktree and commit
# through `lore commit`; the vault checkout stays clean and readers still find the
# files. Fixture vaults only, temp HOME.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-root TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
export SQUAD_INCIDENTS=off HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
LORE="$REPO_ROOT/claude/hooks/lore"
PR="$REPO_ROOT/claude/hooks/path-resolve.sh"
D="$(date +%Y-%m-%d)"
kv() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n 1; }

mkvault() {  # mkvault <dir> <pr|direct>
  mkdir -p "$1"; git -C "$1" init -q -b main
  git -C "$1" config user.name t; git -C "$1" config user.email t@t
  printf '{"vault_main": "%s"}\n' "$2" > "$1/lore-config.json"
  echo seed > "$1/seed.md"; git -C "$1" add -A; git -C "$1" commit -qm init
}
mkproj() {  # mkproj <dir>: a git project root
  mkdir -p "$1"; git -C "$1" init -q -b main
}

# --- PR-mode vault, unmapped root: the Seed write path -----------------------------
V="$TMP/vpr"; mkvault "$V" pr; P="$TMP/roma"; mkproj "$P"
export SECOND_BRAIN_PATH="$V"
( cd "$P" && bash "$LORE" map --name roma ) >/dev/null 2>&1; check "map exits 0" 0 "$?"
out="$(cd "$P" && bash "$PR" 2>/dev/null)"
sq="$(kv SQUAD_DIR "$out")"

out="$(cd "$P" && bash "$LORE" root 2>&1)"; rc=$?
check "root exits 0" 0 "$rc"
root="$(kv ROOT "$out")"
check "root is the session worktree" "$V/.claude/worktrees/lore-roma-$D" "$root"
check "root SQUAD_DIR under root" "$root/projects/roma/.squad" "$(kv SQUAD_DIR "$out")"
check "root PROJECT_DIR" "$root/projects/roma" "$(kv PROJECT_DIR "$out")"
has "root STATE_DIR under root" "$root/projects/roma/" "$(kv STATE_DIR "$out")"

mkdir -p "$root/projects/roma/.squad/forge/archive"
echo arch > "$root/projects/roma/.squad/architecture.md"
echo scout > "$root/projects/roma/.squad/scout-cache.md"
echo '{}' > "$root/projects/roma/.squad/graph.json"
echo st > "$root/projects/roma/status.md"; echo dec > "$root/projects/roma/decisions.md"
echo gold > "$root/projects/roma/golden.md"
out="$(cd "$P" && bash "$LORE" commit --project roma --message "[seed] roma" --paths \
  projects/roma/.squad/architecture.md projects/roma/.squad/scout-cache.md projects/roma/.squad/graph.json \
  projects/roma/status.md projects/roma/decisions.md projects/roma/golden.md 2>&1)"; rc=$?
check "project commit exits 0" 0 "$rc"
has "project commit applied" "OUTCOME=applied" "$out"

vout="$(cd "$P" && bash "$LORE" root --vault-level 2>&1)"; check "vault-level root exits 0" 0 "$?"
vroot="$(kv ROOT "$vout")"
check "vault-level root is lore/_vault worktree" "$V/.claude/worktrees/lore-_vault-$D" "$vroot"
mkdir -p "$vroot/preferences" "$vroot/docs"
echo idx > "$vroot/INDEX.md"; echo pref > "$vroot/preferences/development.md"; echo be > "$vroot/docs/backends.md"
out="$(bash "$LORE" commit --vault-level --message "[seed] scaffold" --paths INDEX.md preferences/development.md docs/backends.md 2>&1)"; rc=$?
check "vault-level commit exits 0" 0 "$rc"

check "vault checkout is clean" "" "$(git -C "$V" status --porcelain)"
check "main untouched" "init" "$(git -C "$V" log -1 --format=%s main)"
tree="$(git -C "$V" ls-tree -r --name-only "lore/roma-$D")"
for f in projects/roma/.squad/architecture.md projects/roma/.squad/scout-cache.md projects/roma/.squad/graph.json \
         projects/roma/status.md projects/roma/decisions.md projects/roma/golden.md lore-config.json; do
  has "project branch holds $f" "$f" "$tree"
done
vtree="$(git -C "$V" ls-tree -r --name-only "lore/_vault-$D")"
for f in INDEX.md preferences/development.md docs/backends.md; do has "vault branch holds $f" "$f" "$vtree"; done
check "scaffolding not on the project branch" 0 "$(printf '%s\n' "$tree" | grep -c '^INDEX.md')"

# readers find the files before the vault PR merges
out="$(cd "$P" && bash "$PR" 2>/dev/null)"
sq="$(kv SQUAD_DIR "$out")"
check "reader sees architecture.md in the session worktree" "arch" "$(cat "$sq/architecture.md" 2>/dev/null)"
check "checkout has no architecture.md" "no" "$([ -e "$V/projects/roma/.squad/architecture.md" ] && echo yes || echo no)"

# second root call: idempotent
out="$(cd "$P" && bash "$LORE" root 2>&1)"
has "second root is unchanged" "OUTCOME=unchanged" "$out"

# forge output.yaml and chisel archive through the same root
root="$(kv ROOT "$out")"
mkdir -p "$root/projects/roma/.squad/forge/archive"
echo y > "$root/projects/roma/.squad/forge/output.yaml"; echo a > "$root/projects/roma/.squad/forge/archive/old.yaml"
( cd "$P" && bash "$LORE" commit --message "[forge] output" --paths projects/roma/.squad/forge/output.yaml projects/roma/.squad/forge/archive/old.yaml ) >/dev/null 2>&1
check "forge write: checkout clean" "" "$(git -C "$V" status --porcelain)"
has "forge write: on the session branch" "projects/roma/.squad/forge/output.yaml" "$(git -C "$V" ls-tree -r --name-only "lore/roma-$D")"

# --- direct-mode vault: unchanged ---------------------------------------------------
V="$TMP/vd"; mkvault "$V" direct; P="$TMP/dproj"; mkproj "$P"
export SECOND_BRAIN_PATH="$V"
( cd "$P" && bash "$LORE" map --name dproj ) >/dev/null 2>&1
out="$(cd "$P" && bash "$LORE" root 2>&1)"; rc=$?
check "direct: root exits 0" 0 "$rc"
check "direct: root is the vault" "$V" "$(kv ROOT "$out")"
check "direct: SQUAD_DIR in the vault" "$V/projects/dproj/.squad" "$(kv SQUAD_DIR "$out")"
check "direct: no worktree created" "no" "$([ -d "$V/.claude/worktrees" ] && echo yes || echo no)"
check "direct: path-resolve SQUAD_DIR in the vault" "$V/projects/dproj/.squad" "$(cd "$P" && bash "$PR" 2>/dev/null | sed -n 's/^SQUAD_DIR=//p')"

# --- no project: exit 10, nothing created --------------------------------------------
V="$TMP/vn"; mkvault "$V" pr; N="$TMP/nogit"; mkdir -p "$N"
export SECOND_BRAIN_PATH="$V"
( cd "$N" && bash "$LORE" root ) >/dev/null 2>&1; check "no project: root exits 10" 10 "$?"
check "no project: no worktree" "no" "$([ -d "$V/.claude/worktrees" ] && echo yes || echo no)"

# --- python writers (atlas, retro, graph timeline) use the same root ----------------
V="$TMP/vpy"; mkvault "$V" pr; P="$TMP/pyproj"; mkproj "$P"
export SECOND_BRAIN_PATH="$V"
( cd "$P" && bash "$LORE" map --name pyproj ) >/dev/null 2>&1
HK="$REPO_ROOT/claude/hooks"
out="$(cd "$P" && python3 -I - "$HK" "$V" "$P" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import squad_pylib as lib
paths = {"VAULT_PATH": sys.argv[2], "PROJECT_ROOT": sys.argv[3], "DISPLAY_NAME": "pyproj"}
rd = lib.read_state_dir(paths)
print("READ=%s" % rd)
sd = lib.write_state_dir(paths)
os.makedirs(os.path.join(sd, "atlas", "x"))
open(os.path.join(sd, "atlas", "x", "atlas.json"), "w").write("{}")
print("COMMIT_RC=%s" % lib.commit_state("atlas", "[atlas] gather"))
print("SD=%s" % sd)
print("EMPTY=%r" % lib.write_state_dir({"VAULT_PATH": sys.argv[2]}))
PYEOF
)"
has "python: read_state_dir finds the session worktree" ".claude/worktrees/lore-pyproj-$D/projects/pyproj/" "$(kv READ "$out")"
check "python: commit_state ok" 0 "$(kv COMMIT_RC "$out")"
check "python: no project, no write root" "''" "$(kv EMPTY "$out")"
check "python: vault checkout clean" "" "$(git -C "$V" status --porcelain)"
has "python: atlas output on the session branch" "atlas/x/atlas.json" "$(git -C "$V" ls-tree -r --name-only "lore/pyproj-$D")"

# graph: an empty state dir never yields a bare relative cache / timeline path (#441 gap)
out="$(python3 -I - "$HK" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("sg", sys.argv[1] + "/squad-graph.py")
sys.path.insert(0, sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("CACHE=%r" % m.default_cache({"VAULT_PATH": "/nonexistent-vault"}))
print("STATE=%r" % m.default_state_file({"VAULT_PATH": "/nonexistent-vault"}, "graph-timeline.jsonl"))
PYEOF
)"
check "graph: default_cache empty without a project" "''" "$(kv CACHE "$out")"
check "graph: default_state_file empty without a project" "''" "$(kv STATE "$out")"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
