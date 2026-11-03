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

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
