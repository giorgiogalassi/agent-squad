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

# --- one open branch per project, across days (#443) ---------------------------------
V="$TMP/vday"; mkvault "$V" pr; P="$TMP/dayproj"; mkproj "$P"
export SECOND_BRAIN_PATH="$V"
( cd "$P" && bash "$LORE" map --name dayproj ) >/dev/null 2>&1
out="$(cd "$P" && bash "$LORE" root 2>&1)"; root1="$(kv ROOT "$out")"
mkdir -p "$root1/projects/dayproj/.squad"; echo day1 > "$root1/projects/dayproj/.squad/architecture.md"
( cd "$P" && bash "$LORE" commit --message "[seed] day1" --paths projects/dayproj/.squad/architecture.md ) >/dev/null 2>&1
Y="$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)"
git -C "$V" worktree move "$root1" "$V/.claude/worktrees/lore-dayproj-$Y" && git -C "$V" branch -m "lore/dayproj-$D" "lore/dayproj-$Y"
out="$(cd "$P" && bash "$LORE" root 2>&1)"; rc=$?
check "day 2: root exits 0" 0 "$rc"
check "day 2: same worktree as day 1" "$V/.claude/worktrees/lore-dayproj-$Y" "$(kv ROOT "$out")"
check "day 2: --read agrees" "$V/.claude/worktrees/lore-dayproj-$Y" "$(cd "$P" && bash "$LORE" root --read | sed -n 's/^ROOT=//p')"
check "day 2: path-resolve sees day-1 architecture.md" "day1" "$(cat "$(cd "$P" && bash "$PR" 2>/dev/null | sed -n 's/^SQUAD_DIR=//p')/architecture.md")"
check "day 2: still one session branch" 1 "$(git -C "$V" branch --list 'lore/dayproj-*' | wc -l | tr -d ' ')"
echo day2 > "$V/.claude/worktrees/lore-dayproj-$Y/projects/dayproj/.squad/forge.md"
( cd "$P" && bash "$LORE" commit --message "[forge] day2" --paths projects/dayproj/.squad/forge.md ) >/dev/null 2>&1
check "day 2: forge file on the day-1 branch" "day2" "$(git -C "$V" show "lore/dayproj-$Y:projects/dayproj/.squad/forge.md")"
check "day 2: checkout clean" "" "$(git -C "$V" status --porcelain)"

# landed: the branch merged into main -> the next write starts a fresh dated branch
git -C "$V" merge -q --ff-only "lore/dayproj-$Y" && echo more > "$V/more.md" && git -C "$V" add more.md && git -C "$V" commit -qm more
out="$(cd "$P" && bash "$LORE" root 2>&1)"
check "landed: new dated worktree" "$V/.claude/worktrees/lore-dayproj-$D" "$(kv ROOT "$out")"
check "landed: new branch exists" 1 "$(git -C "$V" branch --list "lore/dayproj-$D" | wc -l | tr -d ' ')"

# --- worktree SQUAD_DIR is not context: repo ------------------------------------------
. "$REPO_ROOT/claude/hooks/squad-common.sh"
squad_dir_is_repo /v n /v/projects/n/.squad && bad "vault dir is not repo" || ok "vault SQUAD_DIR is not repo"
squad_dir_is_repo /v n /v/.claude/worktrees/lore-n-2026-11-04/projects/n/.squad && bad "worktree dir is not repo" || ok "worktree SQUAD_DIR is not repo"
squad_dir_is_repo /v n /code/n/.squad && ok "repo SQUAD_DIR is repo" || bad "repo dir is repo"
V="$TMP/vctx"; mkvault "$V" pr; P="$TMP/ctxproj"; mkproj "$P"; echo "j" > "$P/JOURNAL.md"
export SECOND_BRAIN_PATH="$V"
( cd "$P" && bash "$LORE" map --name ctxproj ) >/dev/null 2>&1
out="$(cd "$P" && bash "$LORE" root 2>&1)"; mkdir -p "$(kv SQUAD_DIR "$out")"
mkdir -p "$V/projects/ctxproj"; printf '# Decisions\n' > "$V/projects/ctxproj/decisions.md"; printf '# Status\n\n## Context refs\n—\n' > "$V/projects/ctxproj/status.md"
( cd "$P" && bash "$HK/lore-journal-pointer.sh" ) >/dev/null 2>&1
check "journal pointer: no wrong context: repo header" 0 "$(grep -c 'context: repo' "$V/projects/ctxproj/decisions.md")"
check "vault-check --context repo not inferred" "" "$(cd "$P" && bash "$HK/vault-check.sh" check --project ctxproj 2>&1 | grep -i 'context: repo\|JOURNAL' | head -1)"
orient="$(cd "$P" && SQUAD_VAULT_PATH="" bash "$HK/lore-orient.sh" 2>&1 </dev/null)"
case "$orient" in *"JOURNAL"*) bad "orient: worktree SQUAD_DIR read as repo (JOURNAL tail shown)" ;; *) ok "orient: no JOURNAL tail for a vault project" ;; esac

# --- graph.json follows the session worktree (#454) ---------------------------------
V="$TMP/vgraph"; mkvault "$V" pr; P="$TMP/graphproj"; mkproj "$P"
mkdir -p "$P/src"; echo 'export const a = 1' > "$P/src/a.ts"; echo "import './a'" > "$P/src/b.ts"
git -C "$P" add -A; git -C "$P" -c user.name=t -c user.email=t@t commit -qm init
export SECOND_BRAIN_PATH="$V"
( cd "$P" && bash "$LORE" map --name graphproj ) >/dev/null 2>&1
STALE="$V/projects/graphproj/.squad"   # what a session env that predates the worktree holds
out="$(cd "$P" && SQUAD_VAULT_PATH="$V" SQUAD_PROJECT_ROOT="$P" SQUAD_DISPLAY_NAME=graphproj SQUAD_DIR="$STALE" python3 "$HK/squad-graph.py" extract 2>&1)"; rc=$?
check "graph extract exits 0" 0 "$rc"
wt="$V/.claude/worktrees/lore-graphproj-$D/projects/graphproj/.squad"
check "graph.json under the session worktree" 1 "$([ -s "$wt/graph.json" ] && echo 1 || echo 0)"
check "graph: vault checkout clean" "" "$(git -C "$V" status --porcelain)"
out="$(cd "$P" && SQUAD_VAULT_PATH="$V" SQUAD_PROJECT_ROOT="$P" SQUAD_DISPLAY_NAME=graphproj SQUAD_DIR="$STALE" python3 "$HK/squad-graph.py" render 2>&1)"; rc=$?
check "graph render with no --graph exits 0" 0 "$rc"
check "graph.html beside graph.json in the worktree" 1 "$([ -s "$wt/graph.html" ] && echo 1 || echo 0)"
( cd "$P" && bash "$LORE" commit --message "[seed] graph" --paths projects/graphproj/.squad/graph.json projects/graphproj/.squad/graph.html ) >/dev/null 2>&1
has "graph.json on the session branch" "projects/graphproj/.squad/graph.json" "$(git -C "$V" ls-tree -r --name-only "lore/graphproj-$D")"
check "graph: checkout still clean after commit" "" "$(git -C "$V" status --porcelain)"
# explicit env with no vault in it: the vault is found, still the worktree
rm -f "$wt/graph.json"
( cd "$P" && SQUAD_PROJECT_ROOT="$P" SQUAD_DIR="$STALE" python3 "$HK/squad-graph.py" extract ) >/dev/null 2>&1
check "graph: env without a vault still writes the worktree" 1 "$([ -s "$wt/graph.json" ] && echo 1 || echo 0)"
check "graph: no graph.json in the checkout" 0 "$(find "$V/projects" -path '*/.claude' -prune -o -name graph.json -print 2>/dev/null | grep -vc '/.claude/')"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
