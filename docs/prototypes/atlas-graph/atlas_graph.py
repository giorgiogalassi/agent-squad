#!/usr/bin/env python3
"""Prototype of the Atlas page proposed in #410 (base for the real implementation, not wired to any skill).

Usage: atlas_graph.py <project_dir> <base_ref> <head_ref> <brief.md> <out.html> <commit_url_prefix> <src_url_prefix> [<title>]

Units come from the project's own declarations (project.json / package.json
folders under app_dir); edges are imports resolved through tsconfig path
aliases. The graph is scoped to the changed units plus one ring, edges are
diffed between base and head for the changed files, and nodes link to the
commits that touched them. No inline diffs, no commit list.
"""
import html
import json
import os
import re
import subprocess
import sys

IMPORT_RE = re.compile(r"""(?:from\s+|import\s*\(\s*|require\s*\(\s*|import\s+)['"]([^'"]+)['"]""")
SKIP = {"node_modules", "dist", ".angular", ".nx", "coverage", ".git", "tmp"}
EXPORT_DECL_RE = re.compile(r"export\s+(?:declare\s+)?(?:abstract\s+)?(?:const|let|function\*?|class|interface|type|enum)\s+([A-Za-z_$][\w$]*)")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)
TOP_LEVEL_RE = re.compile(r"^(?:export\s|(?:declare\s+)?(?:abstract\s+)?(?:const|let|function|class|interface|type|enum)\s|@\w)")
EXPORT_LIST_RE = re.compile(r"export\s*(?:type\s*)?\{([^}]*)\}")


def named_imports(text, alias):
    """Name sets imported from exactly `alias`, static `import {..} from` and dynamic `import(alias).then(m => m.X)`."""
    out = []
    esc = re.escape(alias)
    for group in re.findall(r"import\s*(?:type\s*)?\{([^}]*)\}\s*from\s*['\"]" + esc + r"['\"]", text or ""):
        out.append({part.strip().split(" as ")[0].replace("type ", "").strip() for part in group.split(",") if part.strip()})
    for m in re.finditer(r"import\(\s*['\"]" + esc + r"['\"]\s*\)\s*\.then\(\s*\(?\s*(\w+)\s*\)?\s*=>\s*\1\.(\w+)", text or ""):
        out.append({m.group(2)})
    return out


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=False).stdout


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.loads(f.read())
    except (OSError, ValueError):
        return None


def find_units(app):
    units = {}
    for dirpath, dirnames, filenames in os.walk(app):
        dirnames[:] = [d for d in dirnames if d not in SKIP and not d.startswith(".")]
        if "project.json" in filenames:
            rel = os.path.relpath(dirpath, app)
            if rel == ".":
                continue
            data = load_json(os.path.join(dirpath, "project.json")) or {}
            units[rel] = data.get("name") or rel
    return units


def find_aliases(app):
    cfg = load_json(os.path.join(app, "tsconfig.base.json")) or {}
    paths = cfg.get("compilerOptions", {}).get("paths", {})
    return {alias.rstrip("/*"): targets[0] for alias, targets in paths.items() if targets}


def unit_of(path, roots):
    best = None
    for root in roots:
        if path == root or path.startswith(root + "/"):
            if best is None or len(root) > len(best):
                best = root
    return best


def alias_unit(spec, aliases, roots):
    for alias in sorted(aliases, key=len, reverse=True):
        if spec == alias or spec.startswith(alias + "/"):
            return unit_of(aliases[alias].lstrip("./"), roots)
    return None


def imports_of(text, src_path, aliases, roots):
    out = set()
    for spec in IMPORT_RE.findall(text or ""):
        if spec.startswith("."):
            target = os.path.normpath(os.path.join(os.path.dirname(src_path), spec))
            u = unit_of(target, roots)
        else:
            u = alias_unit(spec, aliases, roots)
        if u:
            out.add(u)
    return out


def main():
    app, base, head, brief_path, out_path, commit_url, src_url = sys.argv[1:8]
    title = sys.argv[8] if len(sys.argv) > 8 else head
    units = find_units(app)
    roots = list(units)
    aliases = find_aliases(app)
    unit_aliases = {}
    for alias, target in aliases.items():
        u = unit_of(target.lstrip("./"), roots)
        if u:
            unit_aliases.setdefault(u, []).append(alias)

    merge_base = git("merge-base", base, head, cwd=app).strip()
    prefix = git("rev-parse", "--show-prefix", cwd=app).strip()
    changed = []
    pairs = []  # (status, base path or None, head path or None), app-relative
    strip = lambda p: p[len(prefix):] if prefix and p.startswith(prefix) else p
    for line in git("diff", "--name-status", "-M", f"{merge_base}..{head}", "--", ".", cwd=app).splitlines():
        parts = line.split("\t")
        status, paths = parts[0][0], [strip(x) for x in parts[1:]]
        for p in paths:
            changed.append((status, p))
        if status == "R":
            pairs.append((status, paths[0], paths[1]))
        elif status == "A":
            pairs.append((status, None, paths[0]))
        elif status == "D":
            pairs.append((status, paths[0], None))
        else:
            pairs.append((status, paths[0], paths[0]))

    files_by_unit, other_files = {}, []
    for status, rel in changed:
        u = unit_of(rel, roots)
        (files_by_unit.setdefault(u, []) if u else other_files).append((status, rel))
    changed_units = set(files_by_unit)

    # unit-level edges of the changed units, at base and at head
    def unit_edges(ref):
        edges = set()
        for u in changed_units:
            out = git("grep", "-h", "-o", "-E", r"(from|import\(|require\()[[:space:]]*['\"][^'\"]+['\"]", ref,
                      "--", f"{u}/*.ts", f":!{u}/*.spec.ts", cwd=app)
            for line in out.splitlines():
                for t in imports_of(line, u + "/x.ts", aliases, roots):
                    if t != u:
                        edges.add((u, t))
        return edges

    base_edges, head_edges = unit_edges(merge_base), unit_edges(head)

    # names this change touched: exports of the changed non-barrel source files, at base and head
    def exported_names(text):
        names = set(EXPORT_DECL_RE.findall(text or ""))
        for group in EXPORT_LIST_RE.findall(text or ""):
            for part in group.split(","):
                part = part.strip().split(" as ")[-1].strip()
                if part:
                    names.add(part)
        return names

    def hunk_lines(base_path, head_path):
        """Changed line numbers on each side of one file's diff (-U0 hunks)."""
        old_l, new_l = set(), set()
        spec = [base_path or head_path] if base_path == head_path else [x for x in (base_path, head_path) if x]
        out = git("diff", "-U0", "-M", f"{merge_base}..{head}", "--", *spec, cwd=app)
        for m in HUNK_RE.finditer(out):
            a, b, c, d = int(m.group(1)), int(m.group(2) or 1), int(m.group(3)), int(m.group(4) or 1)
            old_l.update(range(a, a + b))
            new_l.update(range(c, c + d))
        return old_l, new_l

    def touched_exports(text, lines):
        """Exported names whose top-level declaration contains a changed line."""
        rows = (text or "").splitlines()
        starts = []
        for i, r in enumerate(rows):
            if not TOP_LEVEL_RE.match(r):
                continue
            # a class keeps the decorator block above it
            if starts and rows[starts[-1] - 1].startswith("@") and not r.startswith("@"):
                continue
            starts.append(i + 1)
        starts.append(len(rows) + 1)
        names = set()
        for k, start in enumerate(starts[:-1]):
            block = "\n".join(rows[start - 1:starts[k + 1] - 1])
            span = range(start, starts[k + 1])
            if any(n in lines for n in span):
                names |= exported_names(block)
        return names

    changed_names = {}
    for status, bp, hp in pairs:
        ref_path = hp or bp
        u = unit_of(ref_path, roots)
        if not u or not ref_path.endswith(".ts") or ref_path.endswith((".spec.ts", "/index.ts")):
            continue
        base_text = git("show", f"{merge_base}:{prefix}{bp}", cwd=app) if bp else ""
        head_text = git("show", f"{head}:{prefix}{hp}", cwd=app) if hp else ""
        moved_unit = status == "R" and unit_of(bp, roots) != unit_of(hp, roots)
        if status in ("A", "D") or moved_unit:
            # a new, deleted or cross-unit moved file changes every name it exports
            names = exported_names(base_text) | exported_names(head_text)
        else:
            old_l, new_l = hunk_lines(bp, hp)
            names = touched_exports(base_text, old_l) | touched_exports(head_text, new_l)
        if names:
            changed_names.setdefault(u, set()).update(names)
            if bp and unit_of(bp, roots) and unit_of(bp, roots) != u:
                changed_names.setdefault(unit_of(bp, roots), set()).update(names)

    # affected: units outside the change whose sources import one of those names through the unit's alias
    uses = {}
    for u in changed_units:
        names = changed_names.get(u, set())
        if not names:
            continue
        for alias in unit_aliases.get(u, []):
            hits = git("grep", "-l", "-F", f"'{alias}'", head, "--", "*.ts", ":!*.spec.ts", cwd=app).splitlines()
            for h in hits:
                path = h.split(":", 1)[1] if ":" in h else h
                rel = path[len(prefix):] if prefix and path.startswith(prefix) else path
                d = unit_of(rel, roots)
                if not d or d == u:
                    continue
                text = git("show", f"{head}:{prefix}{rel}", cwd=app)
                used = set()
                for group in named_imports(text, alias):
                    used |= group & names
                if used:
                    uses.setdefault((d, u), set()).update(used)

    edges = {}
    for e in head_edges - base_edges:
        edges[e] = "added"
    for e in base_edges - head_edges:
        edges[e] = "removed"
    for (a, b) in head_edges & base_edges:
        if a in changed_units and b in changed_units:
            edges[(a, b)] = "unchanged"
    for e in uses:
        edges.setdefault(e, "unchanged")
    affected = {d for (d, u) in uses if d not in changed_units}
    context = {b for (a, b), k in edges.items() if k != "unchanged" and b not in changed_units and b not in affected}

    commits = {}
    for u in changed_units:
        log = git("log", "--format=%h%x09%H%x09%s", f"{merge_base}..{head}", "--", u, cwd=app)
        commits[u] = [line.split("\t") for line in log.splitlines()]

    nodes = []
    for u in sorted(changed_units | affected | context):
        state = "changed" if u in changed_units else "affected" if u in affected else "context"
        nodes.append({
            "id": u, "name": units.get(u, u), "state": state,
            "files": [{"s": s, "p": p} for s, p in files_by_unit.get(u, [])],
            "commits": [{"h": c[0], "H": c[1], "m": c[2]} for c in commits.get(u, []) if len(c) == 3],
        })
    graph = {"nodes": nodes, "edges": [{"a": a, "b": b, "k": k, "uses": sorted(uses.get((a, b), []))}
                                       for (a, b), k in sorted(edges.items())],
             "other": [{"s": s, "p": p} for s, p in other_files],
             "commitUrl": commit_url, "srcUrl": src_url, "head": git("rev-parse", head, cwd=app).strip(), "prefix": prefix}

    with open(brief_path, encoding="utf-8") as f:
        brief_html = md_to_html(f.read())
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(PAGE.replace("__TITLE__", html.escape(title)).replace("__BRIEF__", brief_html)
                .replace("__GRAPH__", json.dumps(graph)))
    print(f"NODES={len(nodes)} EDGES={len(edges)} ADDED={sum(1 for k in edges.values() if k == 'added')} "
          f"REMOVED={sum(1 for k in edges.values() if k == 'removed')} OUT={out_path}")


def inline(text):
    t = html.escape(text)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    return t


def md_to_html(md):
    out, in_list, in_code, ordered = [], False, False, False
    for line in md.splitlines():
        if line.strip().startswith("```"):
            if in_code:
                out.append("</code></pre>")
            else:
                out.append("<pre><code>")
            in_code = not in_code
            continue
        if in_code:
            out.append(html.escape(line))
            continue
        m_ul, m_ol = re.match(r"^\s*-\s+(.*)", line), re.match(r"^\s*\d+\.\s+(.*)", line)
        if m_ul or m_ol:
            want = bool(m_ol)
            if in_list and want != ordered:
                out.append("</ol>" if ordered else "</ul>")
                in_list = False
            if not in_list:
                out.append("<ol>" if want else "<ul>")
                in_list, ordered = True, want
            out.append(f"<li>{inline((m_ol or m_ul).group(1))}</li>")
            continue
        if in_list and line.strip() == "":
            out.append("</ol>" if ordered else "</ul>")
            in_list = False
        h = re.match(r"^(#{1,3})\s+(.*)", line)
        if h:
            n = len(h.group(1)) + 1
            out.append(f"<h{n}>{inline(h.group(2))}</h{n}>")
        elif line.strip():
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ol>" if ordered else "</ul>")
    return "\n".join(out)


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Atlas __TITLE__</title>
<style>
:root{--bg:#fbfaf7;--fg:#1f1d1a;--mut:#6b665e;--line:#e4e0d8;--card:#fff;--chg:#9a4d2c;--aff:#2f6f8f;--ctx:#9b968c;--add:#2e7d32;--del:#b3261e}
@media (prefers-color-scheme:dark){:root{--bg:#171614;--fg:#ece8e1;--mut:#a39d93;--line:#34312c;--card:#201e1b;--chg:#e08a5f;--aff:#6fb3d4;--ctx:#7d786f;--add:#7fc583;--del:#f08b84}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,sans-serif}
header{padding:20px 24px;border-bottom:1px solid var(--line)}h1{margin:0;font-size:20px}.mut{color:var(--mut)}
main{display:grid;grid-template-columns:minmax(0,3fr) minmax(280px,1fr);gap:0}
#g{border-right:1px solid var(--line);overflow:auto}svg{display:block}
#panel{padding:16px 20px}#panel h3{margin:.2em 0 .4em;font-size:16px;word-break:break-all}
#panel ul{padding-left:18px;margin:.3em 0}#panel li{margin:.15em 0;font-size:13px;word-break:break-all}
.legend{display:flex;gap:14px;flex-wrap:wrap;padding:10px 16px;font-size:12px;border-bottom:1px solid var(--line)}
.sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:middle}
.node rect{rx:6;stroke-width:1.5;cursor:pointer}.node text{font-size:12px;pointer-events:none;fill:var(--fg)}
.node.sel rect{stroke-width:3}.edge{fill:none;stroke-width:1.4}
article{padding:8px 24px 40px;max-width:900px}article h2{font-size:17px;margin-top:1.6em}article h3{font-size:15px}
code{background:color-mix(in srgb,var(--line) 60%,transparent);padding:0 3px;border-radius:3px;font-size:12.5px}
pre{background:var(--card);border:1px solid var(--line);padding:10px;overflow:auto}a{color:var(--aff)}
@media (max-width:900px){main{grid-template-columns:1fr}#g{border-right:0;border-bottom:1px solid var(--line)}}
</style></head><body>
<header><h1>Atlas: __TITLE__</h1><div class="mut">Units this change touched (centre), units that use something it changed (left), dependencies it added or removed (right). Click a node.</div></header>
<div class="legend"><span><i class="sw" style="background:var(--chg)"></i>changed</span><span><i class="sw" style="background:var(--aff)"></i>affected (uses a changed name)</span><span><i class="sw" style="background:var(--ctx)"></i>dependency added or removed</span><span style="color:var(--add)">━ edge added</span><span style="color:var(--del)">┅ edge removed</span><span class="mut">─ unchanged</span></div>
<main><div id="g"></div><aside id="panel"><p class="mut">Select a node to see its files and the commits that touched it.</p></aside></main>
<article>__BRIEF__</article>
<script>
const G=__GRAPH__;
const css=v=>getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const col={changed:[],affected:[],context:[]};G.nodes.forEach(n=>col[n.state].push(n));
const W=300,H=34,GX=90,GY=14,cols=[col.affected,col.changed,col.context];
const height=Math.max(1,...cols.map(c=>c.length))*(H+GY)+40, width=3*W+2*GX+40;
const pos={};cols.forEach((c,i)=>c.forEach((n,j)=>{const off=(height-c.length*(H+GY))/2;pos[n.id]={x:20+i*(W+GX),y:off+j*(H+GY)}}));
const NS="http://www.w3.org/2000/svg",svg=document.createElementNS(NS,"svg");
svg.setAttribute("width",width);svg.setAttribute("height",height);svg.setAttribute("viewBox",`0 0 ${width} ${height}`);
const defs=document.createElementNS(NS,"defs");
[["add","--add"],["del","--del"],["un","--ctx"]].forEach(([id,v])=>{defs.insertAdjacentHTML("beforeend",`<marker id="m-${id}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0L10,5L0,10z" fill="${css(v)}"/></marker>`)});
svg.appendChild(defs);
G.edges.forEach(e=>{const a=pos[e.a],b=pos[e.b];if(!a||!b)return;
 const ax=a.x+(b.x>=a.x?W:0),bx=b.x+(b.x>=a.x?0:W);const ay=a.y+H/2,by=b.y+H/2;
 const p=document.createElementNS(NS,"path");const dx=(bx-ax)/2||40;
 p.setAttribute("d",a.x===b.x?`M${a.x+W},${ay} C${a.x+W+60},${ay} ${b.x+W+60},${by} ${b.x+W},${by}`:`M${ax},${ay} C${ax+dx},${ay} ${bx-dx},${by} ${bx},${by}`);
 const k=e.k==="added"?"add":e.k==="removed"?"del":"un";p.setAttribute("class","edge");
 p.setAttribute("stroke",css(k==="add"?"--add":k==="del"?"--del":"--line"));p.setAttribute("marker-end",`url(#m-${k})`);
 if(k==="del")p.setAttribute("stroke-dasharray","5 4");if(k!=="un")p.setAttribute("stroke-width","2.6");svg.appendChild(p)});
const color={changed:"--chg",affected:"--aff",context:"--ctx"};let sel=null;
G.nodes.forEach(n=>{const p=pos[n.id],g=document.createElementNS(NS,"g");g.setAttribute("class","node");g.setAttribute("tabindex","0");
 g.setAttribute("role","button");g.setAttribute("aria-label",`${n.name}, ${n.state}`);
 g.innerHTML=`<rect x="${p.x}" y="${p.y}" width="${W}" height="${H}" fill="${css('--card')}" stroke="${css(color[n.state])}"/><text x="${p.x+10}" y="${p.y+21}">${n.name}${n.more?` (+${n.more} more dependents)`:""}${n.files.length?` · ${n.files.length} files`:""}</text>`;
 const pick=()=>{if(sel)sel.classList.remove("sel");sel=g;g.classList.add("sel");show(n)};
 g.addEventListener("click",pick);g.addEventListener("keydown",ev=>{if(ev.key==="Enter"||ev.key===" "){ev.preventDefault();pick()}});svg.appendChild(g)});
document.getElementById("g").appendChild(svg);
const esc=s=>s.replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const label={A:"added",M:"modified",D:"deleted",R:"renamed"};
function show(n){const P=document.getElementById("panel");
 const ins=G.edges.filter(e=>e.b===n.id),outs=G.edges.filter(e=>e.a===n.id);
 let h=`<h3>${esc(n.name)}</h3><div class="mut">${esc(n.id)} · ${n.state}</div>`;
 if(n.files.length)h+=`<h4>Files in this change (${n.files.length})</h4><ul>${n.files.map(f=>`<li>${label[f.s]||f.s} <a href="${G.srcUrl}${G.head}/${G.prefix}${encodeURI(f.p)}" target="_blank" rel="noopener">${esc(f.p.replace(n.id+"/",""))}</a></li>`).join("")}</ul>`;
 if(n.commits.length)h+=`<h4>Commits that touched it (${n.commits.length})</h4><ul>${n.commits.map(c=>`<li><a href="${G.commitUrl}${c.H}" target="_blank" rel="noopener"><code>${c.h}</code></a> ${esc(c.m)}</li>`).join("")}</ul>`;
 const fmt=(list,key)=>list.map(e=>`<li>${e.k==="unchanged"?"":`<strong>${e.k}</strong> `}${esc(G.nodes.find(x=>x.id===e[key])?.name||e[key])}${e.uses&&e.uses.length?`<br><span class="mut">uses ${e.uses.map(u=>`<code>${esc(u)}</code>`).join(", ")}</span>`:""}</li>`).join("");
 if(outs.length)h+=`<h4>Depends on</h4><ul>${fmt(outs,"b")}</ul>`;if(ins.length)h+=`<h4>Used by</h4><ul>${fmt(ins,"a")}</ul>`;
 P.innerHTML=h}
</script></body></html>"""

if __name__ == "__main__":
    main()
