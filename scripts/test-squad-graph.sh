#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-graph.py: extract (relative import,
# barrel index.ts, import cycle, Python relative import) and render
# --overlay. Plain bash 3.2 + python3; no network.
# Usage: scripts/test-squad-graph.sh
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRAPH="$REPO_ROOT/claude/hooks/squad-graph.py"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-graph
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

P="$TMPROOT/proj"
mkdir -p "$P/src/ui/c" "$P/src/core" "$P/pkg"
cat > "$P/src/ui/a.ts" <<'EOT'
import { b } from './b';
import { c } from './c';
export const a = b + c;
EOT
cat > "$P/src/ui/b.ts" <<'EOT'
import { a } from './a';
export const b = a;
EOT
printf "export * from './impl';\n" > "$P/src/ui/c/index.ts"
printf 'export const c = 1;\n' > "$P/src/ui/c/impl.ts"
printf "import { a } from '../ui/a';\nimport x from 'lodash';\nexport const k = a;\n" > "$P/src/core/k.ts"
printf "import { k } from '../src/core/k';\n" > "$P/src/core/k.test.ts"
printf 'from .n import f\n' > "$P/pkg/m.py"
printf 'def f(): pass\n' > "$P/pkg/n.py"
printf '## Module map\n- `src/ui/` -- user interface\n- `src/core/` -- core logic\n' > "$TMPROOT/scout.md"

G="$TMPROOT/out/graph.json"
OUT="$(python3 "$GRAPH" extract --root "$P" --out "$G" --scout "$TMPROOT/scout.md" 2>"$TMPROOT/err")"; RC=$?
check "G-1 extract exits 0 and reports applied" "0/applied/yes" "$RC/$(key OUTCOME)/$(key CHANGED)"
edges() { python3 -c 'import json,sys; print(" ".join(sorted("%s>%s" % (e["from"], e["to"]) for e in json.load(open(sys.argv[1]))["edges"])))' "$G"; }
check "G-2 relative imports, barrel index.ts, python relative; packages dropped" \
  "pkg/m.py>pkg/n.py src/core/k.ts>src/ui/a.ts src/ui/a.ts>src/ui/b.ts src/ui/a.ts>src/ui/c/index.ts src/ui/b.ts>src/ui/a.ts src/ui/c/index.ts>src/ui/c/impl.ts" "$(edges)"
check "G-3 cycle a<->b flagged (2 nodes)" "2" "$(key CYCLES)"
check "G-4 module count from the scout map (+ pkg)" "3" "$(key MODULES)"
cyc() { python3 -c 'import json,sys; print(",".join(sorted(n["id"] for n in json.load(open(sys.argv[1]))["nodes"] if n["in_cycle"])))' "$G"; }
check "G-5 the cycle members" "src/ui/a.ts,src/ui/b.ts" "$(cyc)"
check "G-6 test file marked" "src/core/k.test.ts" "$(python3 -c 'import json,sys; print(",".join(n["id"] for n in json.load(open(sys.argv[1]))["nodes"] if n["test"]))' "$G")"
OUT="$(python3 "$GRAPH" extract --root "$P" --out "$G" --scout "$TMPROOT/scout.md" 2>/dev/null)"
check "G-7 extract re-run unchanged" "unchanged/no" "$(key OUTCOME)/$(key CHANGED)"
python3 "$GRAPH" extract --root "$P" --bogus >/dev/null 2>&1
check "G-8 unknown argument: rc 2" "2" "$?"

# render --overlay: the diff's module is highlighted, the other is not.
printf '{"title":"PR 9","files":[{"path":"src/ui/b.ts"}]}\n' > "$TMPROOT/atlas.json"
H="$TMPROOT/out/g.html"
OUT="$(python3 "$GRAPH" render --graph "$G" --out "$H" --overlay "$TMPROOT/atlas.json" 2>"$TMPROOT/err")"; RC=$?
check "G-9 render --overlay exits 0 with outcome" "0/applied/yes/1" "$RC/$(key OUTCOME)/$(key CHANGED)/$(key TOUCHED_MODULES)"
check "G-10 touched module carries the class, untouched does not" "1/1" \
  "$(grep -c 'class="gnode touched[^"]*" data-module="src/ui"' "$H")/$(grep -c 'class="gnode" data-module="src/core"' "$H")"
check "G-11 touched file row marked in the drill-down" "1" "$(grep -c 'touched-row"><td><code>src/ui/b.ts' "$H")"
check "G-12 overlay title in the page meta" "1" "$(grep -c 'overlay: PR 9' "$H")"
OUT="$(python3 "$GRAPH" render --graph "$G" --out "$H" --overlay "$TMPROOT/atlas.json" 2>/dev/null)"
check "G-13 render re-run unchanged" "unchanged/no" "$(key OUTCOME)/$(key CHANGED)"
OUT="$(python3 "$GRAPH" render --graph "$G" --out "$TMPROOT/out/plain.html" 2>/dev/null)"
check "G-14 no overlay: nothing touched" "0" "$(key TOUCHED_MODULES)"
python3 "$GRAPH" render --graph "$TMPROOT/none.json" --out "$H" >/dev/null 2>&1
check "G-15 missing graph: rc 10" "10" "$?"


# ------------------------------------------------------------ git fixtures
# Every fixture below is synthetic. Units come from manifests, edges from the
# project's own path aliases; `diff` compares merge-base and head.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMPROOT/home"
mkdir -p "$HOME"
unset SQUAD_DIR SQUAD_VAULT_PATH SQUAD_PROJECT_ROOT SQUAD_DISPLAY_NAME
commit() { ( cd "$1" && git add -A && git commit -qm "$2" ); }
w() { mkdir -p "$(dirname "$1")"; cat > "$1"; }
pj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
gdiff() { OUT="$(python3 "$GRAPH" diff "$@" 2>"$TMPROOT/err")"; RC=$?; }

N="$TMPROOT/nx"; git init -q -b main "$N"
w "$N/.gitignore" <<'EOT'
dist/
EOT
w "$N/tsconfig.base.json" <<'EOT'
{
  // path aliases (JSONC on purpose)
  "compilerOptions": { "paths": {
    "@demo/core": ["libs/core/src/index.ts"],
    "@demo/ui": ["libs/ui/src/index.ts"],
    "@demo/shared": ["libs/legacy/src/index.ts", "libs/util/src/index.ts"],
    "@demo/other": ["libs/other/src/index.ts"],
  } }
}
EOT
for u in core ui util feat other; do printf '{"name":"%s"}\n' "$u" | w "$N/libs/$u/project.json"; done
printf '{"name":"shell"}\n' | w "$N/apps/shell/project.json"
printf "export * from './lib/calc';\n" | w "$N/libs/core/src/index.ts"
w "$N/libs/core/src/lib/calc.ts" <<'EOT'
export function add(a: number, b: number) {
  return a + b;
}
export function sub(a: number, b: number) {
  return a - b;
}
EOT
printf "import { add } from './calc';\n" | w "$N/libs/core/src/lib/calc.spec.ts"
printf "export * from './lib/button';\n" | w "$N/libs/ui/src/index.ts"
w "$N/libs/ui/src/lib/button.ts" <<'EOT'
import { add } from '@demo/core';
export function Button() { return add(1, 2); }
EOT
printf 'export const noop = 1;\n' | w "$N/libs/util/src/index.ts"
w "$N/libs/feat/src/index.ts" <<'EOT'
import { add, sub } from '@demo/core';
export const f = () => sub(add(1, 2), 1);
export const lazy = () => import('@demo/core').then(m => m.add);
EOT
printf "import { add } from '@demo/core';\nexport const o = add;\n" | w "$N/libs/other/src/index.ts"
w "$N/apps/shell/src/main.ts" <<'EOT'
import { Button } from '@demo/ui';
import { noop } from '@demo/shared';
export const m = [Button, noop];
EOT
printf '{}\n' | w "$N/nx.json"
printf 'ignored\n' | w "$N/dist/g.ts"
commit "$N" base
( cd "$N" && git checkout -q -b feat )
sed -i.bak 's/return a - b;/return b - a;/' "$N/libs/core/src/lib/calc.ts" && rm "$N/libs/core/src/lib/calc.ts.bak"
printf "import { noop } from '@demo/shared';\nimport { add } from '@demo/core';\nexport function Button() { return add(1, 2) + noop; }\n" | w "$N/libs/ui/src/lib/button.ts"
printf "import { Button } from '@demo/ui';\nexport const m = [Button];\n" | w "$N/apps/shell/src/main.ts"
printf '{"x":1}\n' | w "$N/nx.json"
commit "$N" "change sub, rewire deps"
( cd "$N" && git checkout -q main )
CACHE="$TMPROOT/cache.json"; DJ="$TMPROOT/out/diff.json"

gdiff --root "$N" --base main --head feat --out "$DJ" --cache "$CACHE"
check "D-1 diff exits 0 with outcome keys" "0/applied/yes/manifest" "$RC/$(key OUTCOME)/$(key CHANGED)/$(key UNIT_SOURCE)"
check "D-2 changed units (manifest units + workspace node for nx.json)" \
  "['(workspace)', 'apps/shell', 'libs/core', 'libs/ui']" \
  "$(pj "$DJ" 'sorted(g["id"] for g in d["groups"] if g["state"]=="changed")')"
check "D-3 affected: only the unit that uses the touched declaration (sub), not the add user" \
  "['libs/feat']" "$(pj "$DJ" 'sorted(g["id"] for g in d["groups"] if g["state"]=="affected")')"
check "D-4 names the affected unit uses (sub only; add/lazy add untouched)" "['sub']" \
  "$(pj "$DJ" '[e["uses"] for e in d["edges"] if e["from"]=="libs/feat" and e["to"]=="libs/core"][0]')"
check "D-5 added edge vs merge-base" "['libs/ui>libs/util']" \
  "$(pj "$DJ" '[e["from"]+">"+e["to"] for e in d["edges"] if e["kind"]=="added"]')"
check "D-6 removed edge, resolved through the SECOND alias target" "['apps/shell>libs/util']" \
  "$(pj "$DJ" '[e["from"]+">"+e["to"] for e in d["edges"] if e["kind"]=="removed"]')"
check "D-7 context node is the dependency the change added or removed" "['libs/util']" \
  "$(pj "$DJ" 'sorted(g["id"] for g in d["groups"] if g["state"]=="context")')"
check "D-8 unit label comes from the manifest name" "core" "$(pj "$DJ" '[g["label"] for g in d["groups"] if g["id"]=="libs/core"][0]')"
check "D-9 node lists its files and commits" "['calc.ts']/1" \
  "$(pj "$DJ" '[[f["path"].split("/")[-1] for f in g["files"]] for g in d["groups"] if g["id"]=="libs/core"][0]')/$(pj "$DJ" '[len(g["commits"]) for g in d["groups"] if g["id"]=="libs/core"][0]')"
check "D-10 no per-file diff text and no hunks in the graph" "0" "$(grep -c '^@@\|"diff"' "$DJ")"
check "D-11 graph.json format fields" "2/unit/diff/False" \
  "$(pj "$DJ" 'str(d["version"])+"/"+d["level"]+"/"+d["kind"]+"/"+str(d["prefix"]!="")')"
check "D-12 first run is all cache misses" "0" "$(key CACHE_HITS)"
gdiff --root "$N" --base main --head feat --out "$DJ" --cache "$CACHE"
check "D-13 re-run: unchanged, all cache hits" "unchanged/no/0" "$(key OUTCOME)/$(key CHANGED)/$(key CACHE_MISSES)"
( cd "$N" && git checkout -q -b feat2 feat && echo 'export const noop = 2;' > libs/util/src/index.ts && git add -A && git commit -qm util && git checkout -q main )
gdiff --root "$N" --base main --head feat2 --out "$TMPROOT/out/diff2.json" --cache "$CACHE"
check "D-14 incremental: untouched units hit the cache, the edited one misses" "yes/1" \
  "$([ "$(key CACHE_HITS)" -gt 0 ] && echo yes)/$(key CACHE_MISSES)"
check "D-15 util is changed now, so no longer context" "True" "$(pj "$TMPROOT/out/diff2.json" '"libs/util" in [g["id"] for g in d["groups"] if g["state"]=="changed"]')"

# Errors: contract exit codes, never an empty graph with exit 0.
gdiff --root "$N" --base main --head no-such-ref --out "$DJ" --cache "$CACHE"
check "E-1 unknown ref: rc 10" "10" "$RC"
( cd "$N" && git checkout -q --orphan unrelated && git rm -rfq . >/dev/null && echo z > z && git add z && git commit -qm unrelated && git checkout -q main )
gdiff --root "$N" --base main --head unrelated --out "$DJ" --cache "$CACHE"
check "E-2 empty merge-base: rc 10 and a reason" "10/1" "$RC/$(grep -c 'merge-base' "$TMPROOT/err")"
gdiff --root "$N" --base main --head main --out "$DJ" --cache "$CACHE"
check "E-3 empty diff: rc 10" "10" "$RC"
gdiff --root "$TMPROOT" --base main --head feat --out "$DJ"
check "E-4 root outside a git repository: rc 10" "10" "$RC"
gdiff --root "$N" --head feat --out "$DJ"
check "E-5 missing --base: rc 2" "2" "$RC"
mkdir -p "$TMPROOT/ro" && : > "$TMPROOT/ro/x"
gdiff --root "$N" --base main --head feat --out "$TMPROOT/ro/x/graph.json" --cache "$CACHE"
check "E-6 unwritable output: rc 20" "20" "$RC"

# extract at a ref: units + edges through the project's own aliases.
EJ="$TMPROOT/out/nx-graph.json"
OUT="$(python3 "$GRAPH" extract --root "$N" --ref feat --out "$EJ" 2>"$TMPROOT/err")"; RC=$?
check "X-1 extract --ref exits 0, manifest units" "0/manifest" "$RC/$(key UNIT_SOURCE)"
check "X-2 alias edge file to file (button.ts imports core through @demo/core)" "True" \
  "$(pj "$EJ" '{"from":"libs/ui/src/lib/button.ts","to":"libs/core/src/index.ts"} in d["edges"]')"
OUT="$(python3 "$GRAPH" extract --root "$N" --ref main --out "$EJ" 2>/dev/null)"
check "X-3 every alias target counts: shell main.ts reaches util through the 2nd target" "True" \
  "$(pj "$EJ" '{"from":"apps/shell/src/main.ts","to":"libs/util/src/index.ts"} in d["edges"]')"
check "X-4 units declared by manifests become groups" "['apps/shell', 'libs/core', 'libs/feat', 'libs/other', 'libs/ui', 'libs/util']" \
  "$(pj "$EJ" 'sorted(g["id"] for g in d["groups"] if g.get("source")=="manifest")')"
OUT="$(python3 "$GRAPH" extract --root "$N" --out "$TMPROOT/out/nx-work.json" 2>/dev/null)"
check "X-5 working tree: tracked files only, no hardcoded skip list, gitignored dist left out" "0/1" \
  "$(pj "$TMPROOT/out/nx-work.json" 'len([n for n in d["nodes"] if n["id"].startswith("dist/")])')/$(pj "$TMPROOT/out/nx-work.json" 'len([n for n in d["nodes"] if n["id"]=="libs/core/src/index.ts"])')"
OUT="$(python3 "$GRAPH" extract --root "$N" --ref main --level unit --out "$TMPROOT/out/nx-units.json" --cache "$CACHE" 2>/dev/null)"
check "X-6 --level unit: unit edges, no file nodes" "True/0" \
  "$(pj "$TMPROOT/out/nx-units.json" '{"from":"libs/ui","to":"libs/core"} in d["edges"]')/$(pj "$TMPROOT/out/nx-units.json" 'len(d["nodes"])')"

# Workspaces declared in package.json.
S="$TMPROOT/ws"; git init -q -b main "$S"
printf '{"name":"root","workspaces":["packages/*"]}\n' | w "$S/package.json"
for p in a b c; do printf '{"name":"@w/%s"}\n' "$p" | w "$S/packages/$p/package.json"; done
printf '{"name":"stray"}\n' | w "$S/tools/x/package.json"
printf 'export const a = 1;\n' | w "$S/packages/a/index.js"
printf "import { a } from '@w/a';\nexport const b = a;\n" | w "$S/packages/b/index.js"
commit "$S" base
OUT="$(python3 "$GRAPH" extract --root "$S" --ref HEAD --level unit --out "$TMPROOT/out/ws.json" 2>/dev/null)"
check "W-1 workspace globs pick the units, the stray manifest is not one" "['packages/a', 'packages/b', 'packages/c']" \
  "$(pj "$TMPROOT/out/ws.json" 'sorted(g["id"] for g in d["groups"])')"
check "W-2 workspace package name resolves as an alias" "[{'from': 'packages/b', 'to': 'packages/a'}]" "$(pj "$TMPROOT/out/ws.json" 'd["edges"]')"

# Project folder below the repository root; change also outside it.
B="$TMPROOT/sub"; git init -q -b main "$B"
for u in x y; do printf '{"name":"%s"}\n' "$u" | w "$B/app/libs/$u/project.json"; done
printf 'export function foo() { return 1; }\nexport function bar() { return 2; }\n' | w "$B/app/libs/x/src/a.ts"
printf "import { foo } from '../../x/src/a';\nexport const y = foo;\n" | w "$B/app/libs/y/src/b.ts"
printf 'readme\n' | w "$B/README.md"
commit "$B" base
( cd "$B" && git checkout -q -b change && sed -i.bak 's/return 1;/return 11;/' app/libs/x/src/a.ts && rm app/libs/x/src/a.ts.bak && echo more >> README.md && git add -A && git commit -qm sub && git checkout -q main )
gdiff --root "$B/app" --base main --head change --out "$TMPROOT/out/sub.json" --cache ""
check "B-1 below-root project: rc 0, prefix and outside count" "0/app//1" "$RC/$(key PREFIX)/$(key OUTSIDE)"
check "B-2 paths are project-relative, grouped by the declared unit" "['libs/x']/['libs/x/src/a.ts']" \
  "$(pj "$TMPROOT/out/sub.json" 'sorted(g["id"] for g in d["groups"] if g["state"]=="changed")')/$(pj "$TMPROOT/out/sub.json" '[f["path"] for g in d["groups"] for f in g["files"]]')"
check "B-3 affected through a relative import below the root, with the name" "['libs/y']/['foo']" \
  "$(pj "$TMPROOT/out/sub.json" '[g["id"] for g in d["groups"] if g["state"]=="affected"]')/$(pj "$TMPROOT/out/sub.json" '[e["uses"] for e in d["edges"] if e["from"]=="libs/y"][0]')"

# Folder fallback: no manifest, no module map; a one-file change still has a graph.
F="$TMPROOT/fold"; git init -q -b main "$F"
printf 'export function x1() { return 1; }\n' | w "$F/src/a/x.ts"
printf "import { x1 } from '../a/x';\nexport const y = x1;\n" | w "$F/src/b/y.ts"
printf 'export const z = 1;\n' | w "$F/build/z.ts"
printf '# docs\n' | w "$F/notes.md"
commit "$F" base
( cd "$F" && git checkout -q -b one && echo 'export const y2 = 2;' >> src/b/y.ts && git add -A && git commit -qm one && git checkout -q main && git checkout -q -b dep && sed -i.bak 's/return 1;/return 2;/' src/a/x.ts && rm src/a/x.ts.bak && git add -A && git commit -qm dep && git checkout -q main )
gdiff --root "$F" --base main --head one --out "$TMPROOT/out/one.json" --cache ""
check "F-1 single-file change, folder fallback: a graph with one changed unit" "0/folder/['src/b']" \
  "$RC/$(key UNIT_SOURCE)/$(pj "$TMPROOT/out/one.json" '[g["id"] for g in d["groups"]]')"
gdiff --root "$F" --base main --head dep --out "$TMPROOT/out/dep.json" --cache ""
check "F-2 folder units: importer is affected by the declaration it uses" "['src/b']/['x1']" \
  "$(pj "$TMPROOT/out/dep.json" '[g["id"] for g in d["groups"] if g["state"]=="affected"]')/$(pj "$TMPROOT/out/dep.json" '[e["uses"] for e in d["edges"] if e["from"]=="src/b"][0]')"
printf '## Module map\n- `src/a/` -- first\n- `src/b/` -- second\n' > "$TMPROOT/scout-ok.md"
printf '## Module map\n- `app/zzz/` -- nowhere\n' > "$TMPROOT/scout-bad.md"
gdiff --root "$F" --base main --head one --out "$TMPROOT/out/one-s.json" --cache "" --scout "$TMPROOT/scout-ok.md"
check "F-3 module map is used when no manifest declares units" "scout" "$(key UNIT_SOURCE)"
gdiff --root "$F" --base main --head one --out "$TMPROOT/out/one-b.json" --cache "" --scout "$TMPROOT/scout-bad.md"
check "F-4 module map whose prefixes match no file is ignored (folder fallback)" "folder" "$(key UNIT_SOURCE)"

# Python packages: per-declaration matching on top-level defs.
P2="$TMPROOT/py"; git init -q -b main "$P2"
for p in alpha beta; do printf '[project]\nname = "%s"\n' "$p" | w "$P2/pkgs/$p/pyproject.toml"; : | w "$P2/pkgs/$p/$p/__init__.py"; done
printf 'def hello():\n    return 1\n\n\ndef bye():\n    return 2\n' | w "$P2/pkgs/alpha/alpha/core.py"
printf 'from alpha.core import hello\n\nx = hello()\n' | w "$P2/pkgs/beta/beta/use.py"
commit "$P2" base
( cd "$P2" && git checkout -q -b bye && sed -i.bak 's/return 2/return 3/' pkgs/alpha/alpha/core.py && rm pkgs/alpha/alpha/core.py.bak && git add -A && git commit -qm bye && git checkout -q main \
  && git checkout -q -b hello && sed -i.bak 's/return 1/return 4/' pkgs/alpha/alpha/core.py && rm pkgs/alpha/alpha/core.py.bak && git add -A && git commit -qm hello && git checkout -q main )
gdiff --root "$P2" --base main --head bye --out "$TMPROOT/out/py1.json" --cache ""
check "P-1 python: unused declaration changed, importer not affected" "manifest/[]" "$(key UNIT_SOURCE)/$(pj "$TMPROOT/out/py1.json" '[g["id"] for g in d["groups"] if g["state"]=="affected"]')"
gdiff --root "$P2" --base main --head hello --out "$TMPROOT/out/py2.json" --cache ""
check "P-2 python: used declaration changed, importer affected with the name" "['pkgs/beta']/['hello']" \
  "$(pj "$TMPROOT/out/py2.json" '[g["id"] for g in d["groups"] if g["state"]=="affected"]')/$(pj "$TMPROOT/out/py2.json" '[e["uses"] for e in d["edges"] if e["from"]=="pkgs/beta"][0]')"

# Hostile names: file names and commit subjects come from the PR.
H="$TMPROOT/host"; git init -q -b main "$H"
printf '{"name":"u"}\n' | w "$H/lib/project.json"
printf 'export const a = 1;\n' | w "$H/lib/a.ts"
commit "$H" base
( cd "$H" && git checkout -q -b evil && printf 'export const a = 2;\n' > lib/a.ts && printf 'x\n' > 'lib/<img src=x onerror=alert(1)>.ts' \
  && git add -A && git commit -qm '</script><script>alert(1)</script> "quoted" & more' && git checkout -q main )
gdiff --root "$H" --base main --head evil --out "$TMPROOT/out/evil.json" --cache ""
OUT="$(python3 "$GRAPH" render --diff "$TMPROOT/out/evil.json" --out "$TMPROOT/out/evil.html" --remote 'https://user:sekret@github.com/acme/demo.git' 2>"$TMPROOT/err")"; RC=$?
EH="$TMPROOT/out/evil.html"
check "S-1 change-graph render exits 0" "0/applied" "$RC/$(key OUTCOME)"
check "S-2 no raw closing script tag from a commit subject" "0" "$(grep -c '</script><script>alert' "$EH")"
check "S-3 no raw element from a file name" "0" "$(grep -c '<img src=x' "$EH")"
check "S-4 embedded JSON escapes angle brackets" "1" "$([ "$(grep -c 'u003c' "$EH")" -ge 1 ] && echo 1)"
check "S-5 remote credentials never reach the page" "0" "$(grep -c 'sekret' "$EH")"
check "S-6 commit link built from the remote (GitHub shape)" "1" "$([ "$(grep -c 'https://github.com/acme/demo/commit/' "$EH")" -ge 1 ] && echo 1)"
check "S-7 the page script only follows https links and builds nodes with textContent" "0/1" \
  "$(grep -c 'innerHTML' "$EH")/$([ "$(grep -c 'https:' "$EH")" -ge 1 ] && echo 1)"
hostu() { python3 - "$GRAPH" "$1" <<'EOPY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sg", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
h = m.host_urls(sys.argv[2])
print(("%s %s %s" % (h["kind"], h["commit"], h["src"])) if h else "none")
EOPY
}
check "H-1 GitHub ssh scp form" "github https://github.com/o/r/commit/ https://github.com/o/r/blob/" "$(hostu 'git@github.com:o/r.git')"
check "H-2 GitHub https with credentials stripped" "github https://github.com/o/r/commit/ https://github.com/o/r/blob/" "$(hostu 'https://u:t@github.com/o/r.git')"
check "H-3 Bitbucket Cloud shape" "bitbucket https://bitbucket.org/ws/r/commits/ https://bitbucket.org/ws/r/src/" "$(hostu 'git@bitbucket.org:ws/r.git')"
check "H-4 Bitbucket https with user@" "bitbucket https://bitbucket.org/ws/r/commits/ https://bitbucket.org/ws/r/src/" "$(hostu 'https://me@bitbucket.org/ws/r.git')"
check "H-5 unknown host: no links" "none" "$(hostu 'git@git.internal.example:o/r.git')"
check "H-6 hostile remote: no links" "none" "$(hostu 'https://github.com/o/r"><script>')"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
