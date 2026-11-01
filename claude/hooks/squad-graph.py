#!/usr/bin/env python3
"""squad-graph.py -- the project's import graph, extracted and rendered (DRAFT).

One script, two consumers. Seed runs `extract` then `render` at the end
of its scout phase; Atlas runs `render --overlay` to show where a diff
falls in the same graph. Changing how graphs look means changing this
file only.

Verbs (stdout follows SCRIPT_CONTRACT.md: KEY=value lines only):

  extract [--root <dir>] [--out <graph.json>] [--scout <scout-cache.md>]
      Walk the project, parse import statements, group files by the
      scout-cache Module map (longest prefix) and write graph.json.
      Defaults: root and scout-cache from path-resolve.sh, out
      <SQUAD_DIR>/graph.json. No model, no network.
  render --graph <graph.json> --out <file.html|file.svg>
         [--overlay <atlas.json>] [--title <text>]
      Draw the module-level graph (nodes = modules, edges = import
      counts between modules) as inline SVG, with a drill-down table of
      files per module. --overlay marks the modules and files an Atlas
      diff touched. An .svg out writes the picture alone (for embedding).

graph.json contract (stable; write another renderer against it, never
a second extractor):
  {
    "generated": "YYYY-MM-DD", "root": "<abs>", "extractor": "regex|madge|...",
    "groups": [{"id": "<prefix>", "label": "<Module map text>"}],
    "nodes":  [{"id": "<path>", "group": "<prefix>", "lang": "ts",
                "fan_in": n, "fan_out": n, "in_cycle": bool, "test": bool}],
    "edges":  [{"from": "<path>", "to": "<path>"}]
  }

Extraction is deliberately plain: TypeScript/JavaScript, Python and
shell `source`/`.` lines, resolved relative to the importing file and
to the project root; package imports (no path) are dropped. Where a
tool-specific extractor exists later (madge, dependency-cruiser,
`nx graph --file`), it writes the same JSON and sets "extractor".

Exit codes: 0 success, 2 usage error, 10 precondition (no root, no
graph), 20 I/O error. Python 3.8+ standard library only.
"""

import datetime as dt
import html
import json
import math
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP_DIRS = {".git", "node_modules", "dist", "build", "out", ".angular", ".nx", "coverage",
             "__pycache__", ".venv", "venv", ".squad", "tmp", ".cache", "target"}
EXTS = {".ts": "ts", ".tsx": "ts", ".js": "js", ".jsx": "js", ".mjs": "js", ".cjs": "js",
        ".py": "py", ".sh": "sh", ".bash": "sh"}
TEST_RE = re.compile(r"(^|/)(test|tests|spec|specs|__tests__|evals?)(/|$)|\.(test|spec)\.[a-z]+$|^scripts/test-.*\.sh$|_test\.(py|go)$")
MODULE_RE = re.compile(r"^\s*[-*]\s*`?([^`:\s(]+)`?\s*[:—–-]+\s*(.*)$")
IMPORT_RES = {
    "ts": [re.compile(r"""(?:import|export)\s+(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]"""),
           re.compile(r"""(?:import|require)\(\s*['"]([^'"]+)['"]\s*\)""")],
    "js": None,  # same as ts
    "py": [re.compile(r"^\s*from\s+(\.+[\w.]*|[\w.]+)\s+import\b", re.M),
           re.compile(r"^\s*import\s+([\w.]+)", re.M)],
    "sh": [re.compile(r"""^\s*(?:source|\.)\s+(.+?)\s*(?:;.*|#.*|\|\|.*|&&.*)?$""", re.M)],
}
IMPORT_RES["js"] = IMPORT_RES["ts"]
MAX_FILE_BYTES = 512 * 1024


def emit(key, value):
    sys.stdout.write("%s=%s\n" % (key, value))


def fail(code, reason):
    sys.stderr.write("squad-graph: %s\n" % reason)
    sys.exit(code)


def resolve_paths():
    env = {k: os.environ.get("SQUAD_" + k, "") for k in
           ("VAULT_PATH", "PROJECT_ROOT", "DISPLAY_NAME", "DIR")}
    if env["PROJECT_ROOT"] and env["DIR"]:
        return env
    try:
        out = subprocess.run(["bash", os.path.join(HERE, "path-resolve.sh")],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return env
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
    if not env.get("DIR") and env.get("VAULT_PATH"):
        name = env.get("DISPLAY_NAME") or os.path.basename(env.get("PROJECT_ROOT") or "")
        env["DIR"] = os.path.join(env["VAULT_PATH"], "projects", name, ".squad")
    return env


def read_text(path):
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return ""
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


# -------------------------------------------------------------- extract

def module_map(scout_path):
    groups = []
    inside = False
    for line in (read_text(scout_path) or "").splitlines():
        if line.startswith("## "):
            inside = line.lower().startswith("## module map")
            continue
        m = MODULE_RE.match(line) if inside else None
        if m:
            groups.append({"id": m.group(1).strip("/"), "label": m.group(2).strip() or m.group(1)})
    groups.sort(key=lambda g: -len(g["id"]))
    return groups


def group_of(path, groups):
    for g in groups:
        if path == g["id"] or path.startswith(g["id"] + "/"):
            return g["id"]
    return path.split("/")[0] if "/" in path else "(root)"


def walk(root):
    files = {}
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS and not d.startswith(".")]
        for fn in fns:
            ext = os.path.splitext(fn)[1]
            if ext in EXTS:
                rel = os.path.relpath(os.path.join(dp, fn), root).replace(os.sep, "/")
                files[rel] = EXTS[ext]
    return files


def resolve_target(spec, src, lang, files, root):
    """Map an import specifier to a project file, or None for packages."""
    cands = []
    if lang in ("ts", "js"):
        if spec.startswith("."):
            base = os.path.normpath(os.path.join(os.path.dirname(src), spec)).replace(os.sep, "/")
        elif spec.startswith("@") and "/" in spec and os.path.isdir(os.path.join(root, spec.split("/")[0])):
            base = spec
        elif spec.startswith(("src/", "app/", "libs/", "apps/", "packages/")):
            base = spec
        else:
            return None
        for suf in ("", ".ts", ".tsx", ".js", ".jsx", ".mjs", "/index.ts", "/index.tsx", "/index.js"):
            cands.append(base + suf)
    elif lang == "py":
        if spec.startswith("."):
            dots = len(spec) - len(spec.lstrip("."))
            parts = os.path.dirname(src).split("/") if "/" in src else []
            parts = parts[:len(parts) - (dots - 1)] if dots > 1 else parts
            tail = spec.lstrip(".").replace(".", "/")
            base = "/".join([p for p in parts if p] + ([tail] if tail else []))
        else:
            base = spec.replace(".", "/")
        cands += [base + ".py", base + "/__init__.py"]
    elif lang == "sh":
        spec = spec.replace('"', "").replace("'", "")
        rooted = False
        if re.search(r"\$\(dirname\s+[^)]*\)", spec):
            spec = re.sub(r"\$\(dirname\s+[^)]*\)\s*/?", (os.path.dirname(src) + "/") if os.path.dirname(src) else "", spec)
            rooted = True
        spec = spec.split()[0] if spec.strip() else ""
        if "$" in spec:
            spec = re.sub(r"\$\{?[A-Za-z_]+\}?/?", "", spec)
        if spec.startswith("/"):
            base = spec.lstrip("/")
        elif rooted:
            base = os.path.normpath(spec).replace(os.sep, "/")
        else:
            base = os.path.normpath(os.path.join(os.path.dirname(src), spec)).replace(os.sep, "/")
        cands = [base, os.path.join(os.path.dirname(src), os.path.basename(spec)).replace(os.sep, "/")]
    for c in cands:
        if c and c in files:
            return c
    return None


def tarjan_cycles(nodes, edges):
    """Nodes that sit on at least one cycle (SCC size > 1 or self edge)."""
    adj = {n: [] for n in nodes}
    for a, b in edges:
        adj[a].append(b)
    index, low, on, stack, idx, out = {}, {}, set(), [], [0], set()

    def strong(v):
        index[v] = low[v] = idx[0]
        idx[0] += 1
        stack.append(v)
        on.add(v)
        for w in adj[v]:
            if w not in index:
                strong(w)
                low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on.discard(w)
                comp.append(w)
                if w == v:
                    break
            if len(comp) > 1 or v in adj[v]:
                out.update(comp)

    sys.setrecursionlimit(max(10000, len(nodes) * 2 + 100))
    for n in nodes:
        if n not in index:
            strong(n)
    return out


def cmd_extract(argv):
    root, out, scout = None, None, None
    i = 0
    while i < len(argv):
        if argv[i] == "--root" and i + 1 < len(argv):
            root = argv[i + 1]
            i += 2
        elif argv[i] == "--out" and i + 1 < len(argv):
            out = argv[i + 1]
            i += 2
        elif argv[i] == "--scout" and i + 1 < len(argv):
            scout = argv[i + 1]
            i += 2
        else:
            fail(2, "unknown argument '%s'" % argv[i])
    paths = resolve_paths()
    root = os.path.abspath(root or paths.get("PROJECT_ROOT") or "")
    if not root or not os.path.isdir(root):
        fail(10, "no root: pass --root or resolve the project")
    squad_dir = paths.get("DIR") or ""
    out = out or (os.path.join(squad_dir, "graph.json") if squad_dir else fail(10, "no --out and no squad dir"))

    files = walk(root)
    scout = scout or (os.path.join(squad_dir, "scout-cache.md") if squad_dir else None)
    groups = module_map(scout) if scout else []
    edges = set()
    for src, lang in files.items():
        text = read_text(os.path.join(root, src))
        if not text:
            continue
        for rx in IMPORT_RES[lang]:
            for m in rx.finditer(text):
                tgt = resolve_target(m.group(1), src, lang, files, root)
                if tgt and tgt != src:
                    edges.add((src, tgt))
    fan_in, fan_out = {}, {}
    for a, b in edges:
        fan_out[a] = fan_out.get(a, 0) + 1
        fan_in[b] = fan_in.get(b, 0) + 1
    cyc = tarjan_cycles(list(files), edges)
    seen_groups = {}
    nodes = []
    for p in sorted(files):
        g = group_of(p, groups)
        seen_groups.setdefault(g, next((x["label"] for x in groups if x["id"] == g), g))
        nodes.append({"id": p, "group": g, "lang": files[p], "fan_in": fan_in.get(p, 0),
                      "fan_out": fan_out.get(p, 0), "in_cycle": p in cyc, "test": bool(TEST_RE.search(p))})
    data = {"generated": dt.date.today().isoformat(), "root": root, "extractor": "regex",
            "groups": [{"id": k, "label": v} for k, v in sorted(seen_groups.items())],
            "nodes": nodes, "edges": [{"from": a, "to": b} for a, b in sorted(edges)]}
    try:
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1)
    except OSError as e:
        fail(20, "cannot write graph: %s" % e)
    emit("GRAPH", out)
    emit("FILES", len(nodes))
    emit("EDGES", len(edges))
    emit("MODULES", len(seen_groups))
    emit("CYCLES", sum(1 for n in nodes if n["in_cycle"]))
    emit("UNTESTED_MODULES", sum(1 for g in seen_groups if not any(n["test"] for n in nodes if n["group"] == g)))
    emit("EXTRACTOR", "regex")


# --------------------------------------------------------------- render

SVG_CSS = """
.gnode rect{fill:var(--code,#f1eee8);stroke:var(--line,#c9c4ba);stroke-width:1}
.gnode.touched rect{stroke:var(--acc,#9a4d2c);stroke-width:2.5}
.gnode.cycle rect{stroke-dasharray:4 3}
.gnode text{font:12px -apple-system,Segoe UI,Helvetica,Arial,sans-serif;fill:var(--fg,#1f1d1a)}
.gnode .sub{font-size:10px;fill:var(--mut,#6b665e)}
.gedge{stroke:var(--mut,#9f9a90);fill:none;opacity:.55}
.gedge.touched{stroke:var(--acc,#9a4d2c);opacity:.95}
.glab{font:10px -apple-system,Segoe UI,Helvetica,Arial,sans-serif;fill:var(--mut,#6b665e)}
"""


def layered(modules, medges):
    """Longest-path layering on the module DAG (cycle edges ignored for
    layout); returns {module: (layer, position)}."""
    preds = {m: set() for m in modules}
    for a, b, _ in medges:
        if a != b:
            preds[b].add(a)
    layer, done = {}, set()
    # Kahn with cycle breaking: repeatedly take nodes whose preds are placed; if stuck, place the lowest fan-in node
    remaining = set(modules)
    while remaining:
        ready = [m for m in remaining if preds[m] <= done]
        if not ready:
            ready = [min(remaining, key=lambda m: len(preds[m] - done))]
        for m in ready:
            layer[m] = max([layer[p] for p in preds[m] if p in layer] + [-1]) + 1
            done.add(m)
            remaining.discard(m)
    rows = {}
    for m in sorted(modules, key=lambda m: (layer[m], m)):
        rows.setdefault(layer[m], []).append(m)
    pos = {}
    for l, ms in rows.items():
        for i, m in enumerate(ms):
            pos[m] = (l, i, len(ms))
    return pos


def module_svg(data, overlay, width=1000):
    nodes = data["nodes"]
    labels = {g["id"]: g["label"] for g in data.get("groups", [])}
    mod_of = {n["id"]: n["group"] for n in nodes}
    modules = sorted({n["group"] for n in nodes})
    counts = {}
    for e in data["edges"]:
        a, b = mod_of.get(e["from"]), mod_of.get(e["to"])
        if a and b and a != b:
            counts[(a, b)] = counts.get((a, b), 0) + 1
    medges = [(a, b, c) for (a, b), c in counts.items()]
    touched_files = set(overlay.get("files", [])) if overlay else set()
    touched = {mod_of[f] for f in touched_files if f in mod_of}
    cyc_mods = {n["group"] for n in nodes if n["in_cycle"]}
    pos = layered(modules, medges)
    nlayers = max((l for l, _, _ in pos.values()), default=0) + 1
    bw, bh, gapy = 190, 44, 70
    height = nlayers * (bh + gapy) + 30
    xy = {}
    for m, (l, i, n) in pos.items():
        span = min(width - 40, n * (bw + 20))
        x0 = (width - span) / 2 + i * (span / n) + (span / n - bw) / 2
        xy[m] = (x0, 15 + l * (bh + gapy))
    out = ["<svg viewBox=\"0 0 %d %d\" width=\"100%%\" role=\"img\" aria-label=\"module import graph\">" % (width, height),
           "<style>%s</style>" % SVG_CSS,
           "<defs><marker id=\"arr\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto\">"
           "<path d=\"M0,0 L10,5 L0,10 z\" fill=\"#9f9a90\"/></marker></defs>"]
    for a, b, c in sorted(medges, key=lambda t: t[2]):
        (x1, y1), (x2, y2) = xy[a], xy[b]
        sx, sy = x1 + bw / 2, y1 + bh
        tx, ty = x2 + bw / 2, y2
        if y2 <= y1:  # back edge: route around the right side
            d = "M%.0f,%.0f C%.0f,%.0f %.0f,%.0f %.0f,%.0f" % (x1 + bw, y1 + bh / 2, x1 + bw + 60, y1 + bh / 2, x2 + bw + 60, y2 + bh / 2, x2 + bw, y2 + bh / 2)
        else:
            d = "M%.0f,%.0f C%.0f,%.0f %.0f,%.0f %.0f,%.0f" % (sx, sy, sx, sy + gapy / 2, tx, ty - gapy / 2, tx, ty)
        cls = "gedge touched" if (a in touched and b in touched) else "gedge"
        out.append("<path class=\"%s\" d=\"%s\" stroke-width=\"%.1f\" marker-end=\"url(#arr)\"><title>%s imports %s: %d</title></path>"
                   % (cls, d, min(1 + math.log2(c), 5), html.escape(a), html.escape(b), c))
    for m in modules:
        x, y = xy[m]
        files_in = [n for n in nodes if n["group"] == m]
        fi = sum(n["fan_in"] for n in files_in)
        cls = "gnode" + (" touched" if m in touched else "") + (" cycle" if m in cyc_mods else "")
        tcount = sum(1 for f in touched_files if mod_of.get(f) == m)
        out.append("<g class=\"%s\" data-module=\"%s\"><rect x=\"%.0f\" y=\"%.0f\" width=\"%d\" height=\"%d\" rx=\"5\"/>"
                   "<text x=\"%.0f\" y=\"%.0f\">%s</text><text class=\"sub\" x=\"%.0f\" y=\"%.0f\">%d files, fan-in %d%s</text>"
                   "<title>%s</title></g>"
                   % (cls, html.escape(m), x, y, bw, bh, x + 8, y + 18, html.escape(m[:28]), x + 8, y + 34,
                      len(files_in), fi, (", %d touched" % tcount) if tcount else "", html.escape(labels.get(m, m))))
    out.append("</svg>")
    return "\n".join(out), medges, touched


PAGE_CSS = """
:root{--bg:#fbfaf7;--fg:#1f1d1a;--mut:#6b665e;--line:#e4e0d8;--acc:#9a4d2c;--code:#f1eee8}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#14130f;--fg:#ece8df;--mut:#9f9a90;--line:#2b2924;--acc:#e0876a;--code:#1f1d18}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,Segoe UI,Helvetica,Arial,sans-serif}
main{max-width:1100px;margin:0 auto;padding:16px}h1{font-size:20px;margin:0 0 4px}h2{font-size:17px;margin:24px 0 8px;border-bottom:1px solid var(--line);padding-bottom:4px}
.meta{color:var(--mut);font-size:13px}table{border-collapse:collapse;width:100%;font-size:13px}td,th{text-align:left;padding:4px 6px;border-bottom:1px solid var(--line)}
code{background:var(--code);padding:1px 4px;border-radius:3px;font-size:13px}.gnode{cursor:pointer}.hidden{display:none}.mut{color:var(--mut)}.touched-row{border-left:3px solid var(--acc)}
"""

PAGE_JS = """
(function(){
  document.querySelectorAll('.gnode').forEach(function(g){
    g.addEventListener('click',function(){
      var m=g.dataset.module;
      document.querySelectorAll('[data-files]').forEach(function(t){t.classList.toggle('hidden',t.dataset.files!==m);});
      var el=document.getElementById('drill'); if(el) el.textContent='Files in '+m;
    });
  });
})();
"""


def graph_section(data, overlay, title):
    """HTML fragment: the SVG plus one drill-down table per module.
    Used by this script's render and by squad-atlas.py."""
    svg, medges, touched = module_svg(data, overlay)
    nodes = data["nodes"]
    touched_files = set(overlay.get("files", [])) if overlay else set()
    H = ["<div class=\"graph\">", svg,
         "<p class=\"mut\">Nodes are modules from the scout-cache Module map; arrows point from importer to imported, "
         "width grows with the number of imports. Dashed border: module on an import cycle. Highlighted: touched by the diff. Click a module for its files.</p>",
         "<h3 id=\"drill\">Files (click a module)</h3>"]
    for g in sorted({n["group"] for n in nodes}):
        rows = sorted((n for n in nodes if n["group"] == g), key=lambda n: -n["fan_in"])
        H.append("<table data-files=\"%s\" class=\"hidden\"><tr><th>file</th><th>fan-in</th><th>fan-out</th><th>cycle</th><th>test</th></tr>%s</table>"
                 % (html.escape(g), "".join(
                     "<tr class=\"%s\"><td><code>%s</code></td><td>%d</td><td>%d</td><td>%s</td><td>%s</td></tr>"
                     % ("touched-row" if n["id"] in touched_files else "", html.escape(n["id"]), n["fan_in"], n["fan_out"],
                        "yes" if n["in_cycle"] else "", "yes" if n["test"] else "") for n in rows)))
    H.append("</div>")
    return "\n".join(H), {"modules": len({n["group"] for n in nodes}), "edges": len(medges),
                          "touched_modules": len(touched)}


def cmd_render(argv):
    graph, out, overlay, title = None, None, None, None
    i = 0
    while i < len(argv):
        k = argv[i]
        v = argv[i + 1] if i + 1 < len(argv) else None
        if k == "--graph":
            graph = v
        elif k == "--out":
            out = v
        elif k == "--overlay":
            overlay = v
        elif k == "--title":
            title = v
        else:
            fail(2, "unknown argument '%s'" % k)
        i += 2
    if not graph or not out:
        fail(2, "usage: render --graph <graph.json> --out <file> [--overlay <atlas.json>] [--title <text>]")
    try:
        with open(graph, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        fail(10, "no graph at %s" % graph)
    ov = None
    if overlay:
        try:
            with open(overlay, encoding="utf-8") as f:
                a = json.load(f)
            ov = {"files": [x["path"] for x in a.get("files", [])], "title": a.get("title")}
        except (OSError, ValueError, KeyError):
            fail(10, "no atlas.json at %s" % overlay)
    title = title or ("Import graph: %s" % os.path.basename(data.get("root") or "project"))
    if out.endswith(".svg"):
        body, stats = module_svg(data, ov)[0], None
        doc = body
    else:
        body, stats = graph_section(data, ov, title)
        doc = ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
               "<title>%s</title><style>%s</style></head><body><main><h1>%s</h1><div class=\"meta\">%d files, %d edges, generated %s, extractor %s%s</div>"
               "<h2>Modules</h2>%s</main><script>%s</script></body></html>"
               % (html.escape(title), PAGE_CSS, html.escape(title), len(data["nodes"]), len(data["edges"]),
                  data.get("generated", "?"), data.get("extractor", "?"),
                  (", overlay: %s" % html.escape(ov["title"] or overlay)) if ov else "", body, PAGE_JS))
    try:
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            f.write(doc)
    except OSError as e:
        fail(20, "cannot write: %s" % e)
    emit("OUT", out)
    if stats:
        emit("MODULES", stats["modules"])
        emit("MODULE_EDGES", stats["edges"])
        emit("TOUCHED_MODULES", stats["touched_modules"])


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        sys.exit(2)
    verb, rest = sys.argv[1], sys.argv[2:]
    if verb == "extract":
        cmd_extract(rest)
    elif verb == "render":
        cmd_render(rest)
    else:
        fail(2, "unknown verb '%s'" % verb)


if __name__ == "__main__":
    main()
