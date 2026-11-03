#!/usr/bin/env python3
"""squad-atlas.py -- evidence pack and render for an Atlas brief (DRAFT).

Verbs (stdout follows SCRIPT_CONTRACT.md: KEY=value lines only):

  gather <pr#|branch|--batch> [--base <ref>]
                                Resolve the range, collect the diff per
                                file grouped by the scout-cache module
                                map, commits, tests touched, acceptance
                                criteria and Reven's observations into
                                .squad/atlas/<id>/atlas.json, and write
                                brief.md from the section template when
                                it does not exist yet.
  render <id>                   Read atlas.json + brief.md and write
                                index.html: one file, no network, no
                                external script. When <SQUAD_DIR>/graph.json
                                exists (squad-graph.py extract, run by
                                Seed), the page carries the module import
                                graph with the diff's modules highlighted,
                                drawn by squad-graph.py (one renderer for
                                Seed and Atlas).

Range resolution:
  pr number   connected mode: `gh pr view` for head/base/title/body
              (reads only; moves onto squad-vcs.sh after #397). Else
              SOURCE=git-only and the number must match a
              "[#ID] resolved. PR: #N" line in progress.txt to find the
              branch in ralph-run.md.
  branch      base from the ralph-run.md row when present, else the
              repository default branch (origin/HEAD, else main/master).
  --batch     one gather per row of ralph-run.md; emits one block of
              keys per row separated by ID=.
  base ref    origin/<base> when that remote-tracking ref exists (it is
              the PR's real base: a stale local branch would pull in
              commits already merged upstream), else the local <base>.
              --base <ref> overrides it as given, for every target.
              BASE= prints the ref actually compared against.

Where files live: scout-cache.md, forge/output.yaml and graph.json are
read from $SQUAD_DIR (the repo's .squad for `context: repo` projects);
progress.txt, ralph-run.md and the atlas/ output stay in the vault's
projects/<name>/.squad. A head that exists only as origin/<head> is
resolved like the base. In --batch a row that cannot be gathered is
reported (ROW_ERROR) and the other rows still run.

Criteria: PR/issue body "Acceptance" section when fetched, else
forge/output.yaml acceptance_criteria, else none.
Verdicts: "[#ID] [date] review: <VERDICT> r<N> <anything>" lines of
progress.txt for the issue that resolved into this PR or branch. The
observations are the text after "Obs:"/"obs:" when present, else the
whole trailing text (one pair of surrounding parentheses dropped).

Exit codes: 0 success, 2 usage error, 10 precondition, 20 I/O error.
Python 3.8+ standard library only.
"""

import datetime as dt
import html
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import squad_pylib as lib  # noqa: E402  (shared progress.txt parser)

DIFF_CAP_LINES = 400
RESOLVED_RE = re.compile(r"^\[#?([A-Za-z]+-\d+|\d+)\]\s+(?:(\d{4}-\d{2}-\d{2})\s+)?resolved\.\s+PR:\s+#(\d+)")

BRIEF_TEMPLATE = """# Atlas brief: {title}

Range: `{base}...{head}` ({commits} commits, {files} files, +{added} -{deleted}). Written {date}.

## What it does
<!-- three to six sentences in product terms; no file names -->

## Why
<!-- issue/ticket, acceptance criteria verbatim, which module serves which criterion -->

## Where
<!-- one line per module: module, files, what changed there -->

## How it works
<!-- execution order: trigger, data in, transformations, data out, side effects; functions and types with file:line -->

## How to verify
<!-- per criterion: manual steps, expected result, covering test or `not covered` -->

## Edge cases and limits
<!-- what the diff handles explicitly and what it does not -->

## What Reven questioned
<!-- each observation, how the final diff answers it, or `open` -->

## Questions a tester will ask
<!-- five to eight Q/A pairs in the tester's voice, each with the proving file -->

## Names introduced
<!-- name, file, one-line meaning -->
"""


def emit(key, value):
    sys.stdout.write("%s=%s\n" % (key, value))


class Fatal(Exception):
    """A failure with its exit code; `gather --batch` catches it per row."""

    def __init__(self, code, reason):
        Exception.__init__(self, reason)
        self.code, self.reason = code, reason


def fail(code, reason):
    raise Fatal(code, reason)


def resolve_paths():
    env = {k: os.environ.get("SQUAD_" + k, "") for k in
           ("VAULT_PATH", "PROJECT_ROOT", "DISPLAY_NAME", "TRACKER_MODE", "DIR")}
    if env["VAULT_PATH"] and env["PROJECT_ROOT"]:
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
    return env


def squad_dir(paths):
    name = paths.get("DISPLAY_NAME") or os.path.basename(paths.get("PROJECT_ROOT") or "")
    return os.path.join(paths.get("VAULT_PATH") or "", "projects", name, ".squad")


def knowledge_dir(paths):
    """$SQUAD_DIR: where scout-cache.md, forge/output.yaml and graph.json
    live (the repo's .squad for `context: repo`, else the vault's). Run
    state (progress.txt, ralph-run.md) and atlas/ output stay in squad_dir."""
    return paths.get("DIR") or squad_dir(paths)


def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f]
    except OSError:
        return None


def git(*args, cwd=None, check=True):
    out = subprocess.run(["git"] + list(args), capture_output=True, text=True, cwd=cwd)
    if check and out.returncode != 0:
        raise RuntimeError((out.stderr or "").strip() or "git %s failed" % args[0])
    return out.stdout


def gh_json(args):
    out = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(((out.stderr or "").strip().splitlines() or ["gh failed"])[-1])
    return json.loads(out.stdout or "null")


# --------------------------------------------------------------- gather

def default_branch(root):
    try:
        ref = git("symbolic-ref", "refs/remotes/origin/HEAD", cwd=root).strip()
        return ref.rsplit("/", 1)[-1]
    except RuntimeError:
        for b in ("main", "master"):
            if subprocess.run(["git", "rev-parse", "--verify", "-q", b], cwd=root,
                              capture_output=True).returncode == 0:
                return b
    return "main"


def ralph_rows(sd):
    rows = {}
    for line in read_lines(os.path.join(sd, "ralph-run.md")) or []:
        if line.startswith("|") and not line.startswith("|---"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if cells and re.match(r"^#?([A-Za-z]+-\d+|\d+)$", cells[0]):
                rows[cells[0].lstrip("#")] = cells
    return rows


_GRAPH = []


def _graph_module():
    if not _GRAPH:
        spec = importlib.util.spec_from_file_location("squad_graph", os.path.join(HERE, "squad-graph.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _GRAPH.append(mod)
    return _GRAPH[0]


def module_map(kd):
    """The scout-cache Module map, parsed once by squad-graph.py so Seed,
    Atlas and the graph agree on what a module is."""
    return _graph_module().module_map(os.path.join(kd, "scout-cache.md"))


def module_of(path, mods):
    return _graph_module().group_of(path, mods)


def criteria_from_text(body):
    if not body:
        return []
    out, inside = [], False
    for line in body.splitlines():
        s = line.strip()
        if s.lower().startswith("#") and "acceptance" in s.lower():
            inside = True
            continue
        if inside and s.startswith("#"):
            break
        if inside and re.match(r"^(-|\*|\d+\.|- \[[ x]\])\s+", s):
            out.append(re.sub(r"^(-|\*|\d+\.)\s+(\[[ x]\]\s+)?", "", s))
    return out


def criteria_from_forge(kd):
    lines = read_lines(os.path.join(kd, "forge", "output.yaml")) or []
    out, inside = [], False
    for line in lines:
        if line.startswith("acceptance_criteria:"):
            inside = True
            continue
        if inside:
            if line.startswith(" ") and line.strip().startswith("- "):
                out.append(line.strip()[2:].strip().strip('"'))
            elif line.strip() and not line.startswith(" "):
                break
    return out


def verdicts_for(sd, issue):
    out = []
    if issue is None:
        return out
    for line in read_lines(os.path.join(sd, "progress.txt")) or []:
        rv = lib.parse_review(line)
        if rv and rv["issue"] == issue:
            out.append({"round": rv["round"], "verdict": rv["verdict"], "obs": rv["obs"]})
    return out


def issue_for_pr(sd, pr):
    for line in read_lines(os.path.join(sd, "progress.txt")) or []:
        m = RESOLVED_RE.match(line)
        if m and int(m.group(3)) == pr:
            return m.group(1)
    return None


def resolve_target(target, paths, sd):
    """-> dict(id, title, body, base, head, issue, source)"""
    root = paths["PROJECT_ROOT"]
    rows = ralph_rows(sd)
    connected = paths.get("TRACKER_MODE") == "connected"
    t = target.lstrip("#")
    if t.isdigit():
        pr = int(t)
        issue = issue_for_pr(sd, pr)
        if connected:
            try:
                d = gh_json(["pr", "view", str(pr), "--json", "title,body,headRefName,baseRefName"])
                return {"id": "pr-%d" % pr, "title": d.get("title") or "PR #%d" % pr,
                        "body": d.get("body") or "", "base": d["baseRefName"],
                        "head": d["headRefName"], "issue": issue, "source": "vcs"}
            except (RuntimeError, KeyError, ValueError) as e:
                sys.stderr.write("squad-atlas: gh: %s\n" % e)
        if issue is not None and issue in rows:
            return {"id": "pr-%d" % pr, "title": "PR #%d (issue %s)" % (pr, issue if "-" in issue else "#" + issue), "body": "",
                    "base": rows[issue][2], "head": rows[issue][1], "issue": issue, "source": "git-only"}
        fail(10, "PR not found: #%d is not fetchable and has no ralph-run.md row" % pr)
    # branch
    if head_ref(root, t) is None:
        fail(10, "no such branch: %s" % t)
    issue = next((i for i, c in rows.items() if c[1] == t), None)
    base = rows[issue][2] if issue is not None else default_branch(root)
    return {"id": re.sub(r"[^A-Za-z0-9._-]+", "-", t), "title": t, "body": "", "base": base,
            "head": t, "issue": issue, "source": "git-only"}


def ref_exists(root, ref):
    return subprocess.run(["git", "rev-parse", "--verify", "-q", ref + "^{commit}"], cwd=root,
                          capture_output=True).returncode == 0


def head_ref(root, head):
    """The PR head as a ref: the local branch, else origin/<head> (a head
    that was never checked out locally), else None."""
    for cand in (head, "refs/remotes/origin/" + head):
        if ref_exists(root, cand):
            return cand if cand == head else "origin/" + head
    return None


def base_ref(root, base, override=None):
    """The ref the range is compared against: --base as given, else
    origin/<base> when it exists, else the local <base>."""
    if override:
        if not ref_exists(root, override):
            fail(10, "no diff against base: --base %s is not a commit" % override)
        return override
    if not base.startswith("origin/") and ref_exists(root, "refs/remotes/origin/" + base):
        return "origin/" + base
    if ref_exists(root, base):
        return base
    fail(10, "no diff against base: neither origin/%s nor %s exists" % (base, base))


def gather_one(spec, paths, sd, base_override=None):
    root = paths["PROJECT_ROOT"]
    kd = knowledge_dir(paths)
    head = head_ref(root, spec["head"])
    if head is None:
        fail(10, "no diff against base: head %s exists neither locally nor as origin/%s" % (spec["head"], spec["head"]))
    base = base_ref(root, spec["base"], base_override)
    try:
        merge_base = git("merge-base", base, head, cwd=root).strip()
    except RuntimeError as e:
        fail(10, "no diff against base: %s" % e)
    # --no-renames: a rename is a delete plus an add, so every path below is
    # a plain path (no `old => new` in numstat, no two-path name-status).
    numstat = git("diff", "--no-renames", "--numstat", "%s..%s" % (merge_base, head), cwd=root)
    status = dict()
    for line in git("diff", "--no-renames", "--name-status", "%s..%s" % (merge_base, head), cwd=root).splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            status[parts[-1]] = parts[0][0]
    if not numstat.strip():
        fail(10, "no diff against base: %s..%s is empty" % (base, head))
    mods = module_map(kd)
    test_re = _graph_module().TEST_RE
    files = []
    for line in numstat.splitlines():
        a, d, path = line.split("\t", 2)
        diff = git("diff", "--no-renames", "%s..%s" % (merge_base, head), "--", path, cwd=root, check=False)
        lines = diff.splitlines()
        capped = len(lines) > DIFF_CAP_LINES
        files.append({"path": path, "added": int(a) if a.isdigit() else 0,
                      "deleted": int(d) if d.isdigit() else 0, "status": status.get(path, "M"),
                      "module": module_of(path, mods), "test": bool(test_re.search(path)),
                      "diff": "\n".join(lines[:DIFF_CAP_LINES]), "capped": capped})
    commits = []
    for line in git("log", "--format=%h%x09%cs%x09%an%x09%s", "%s..%s" % (merge_base, head), cwd=root).splitlines():
        h, date, an, s = (line.split("\t", 3) + ["", "", ""])[:4]
        commits.append({"sha": h, "date": date, "author": an, "subject": s})
    criteria = criteria_from_text(spec.get("body")) or criteria_from_forge(kd)
    data = {"id": spec["id"], "title": spec["title"], "base": base, "head": head,
            "merge_base": merge_base[:12], "issue": spec["issue"], "source": spec["source"],
            "project": paths.get("DISPLAY_NAME"), "generated": dt.date.today().isoformat(),
            "modules": {g["id"]: g["label"] for g in mods},
            "files": files, "commits": commits, "criteria": criteria,
            "verdicts": verdicts_for(sd, spec["issue"]),
            "body": spec.get("body", "")}
    out = os.path.join(sd, "atlas", spec["id"])
    try:
        os.makedirs(out, exist_ok=True)
        changed = lib.write_if_changed(os.path.join(out, "atlas.json"), json.dumps(data, indent=1))
        brief = os.path.join(out, "brief.md")
        if not os.path.exists(brief):
            with open(brief, "w", encoding="utf-8") as f:
                f.write(BRIEF_TEMPLATE.format(
                    title=data["title"], base=base, head=head, commits=len(commits),
                    files=len(files), added=sum(x["added"] for x in files),
                    deleted=sum(x["deleted"] for x in files), date=data["generated"]))
    except OSError as e:
        fail(20, "cannot write atlas: %s" % e)
    emit("ID", data["id"])
    emit("OUTCOME", "applied" if changed else "unchanged")
    emit("CHANGED", "yes" if changed else "no")
    emit("ATLAS_DIR", out)
    emit("TITLE", data["title"])
    emit("BASE", base)
    emit("HEAD", head)
    emit("COMMITS", len(commits))
    emit("FILES", len(files))
    emit("ADDED", sum(x["added"] for x in files))
    emit("DELETED", sum(x["deleted"] for x in files))
    emit("MODULES", ",".join(sorted({x["module"] for x in files})))
    emit("TESTS", sum(1 for x in files if x["test"]))
    emit("CRITERIA", len(criteria))
    emit("VERDICTS", sum(1 for v in data["verdicts"] if v["obs"]))
    emit("SOURCE", spec["source"])


def cmd_gather(argv):
    usage = "usage: gather <pr#|branch|--batch> [--base <ref>]"
    base_override, rest = None, []
    i = 0
    while i < len(argv):
        if argv[i] == "--base":
            if i + 1 >= len(argv) or not argv[i + 1]:
                fail(2, usage)
            base_override = argv[i + 1]
            i += 2
        elif argv[i].startswith("--base="):
            base_override = argv[i].split("=", 1)[1] or fail(2, usage)
            i += 1
        else:
            rest.append(argv[i])
            i += 1
    if len(rest) != 1:
        fail(2, usage)
    argv = rest
    paths = resolve_paths()
    if not paths.get("VAULT_PATH") or not os.path.isdir(paths["VAULT_PATH"]):
        fail(10, "vault not found")
    if not paths.get("PROJECT_ROOT"):
        fail(10, "project root not resolved")
    sd = squad_dir(paths)
    if argv[0] == "--batch":
        rows = ralph_rows(sd)
        if not rows:
            fail(10, "no ralph-run.md rows")
        failed = 0
        for issue in sorted(rows, key=lambda i: (re.sub(r"\d+$", "", i), int(re.search(r"\d+$", i).group()))):
            try:
                gather_one(resolve_target(rows[issue][1], paths, sd), paths, sd, base_override)
            except Fatal as e:
                # One bad row (missing branch, empty diff) must not hide the rest.
                failed += 1
                sys.stderr.write("squad-atlas: %s: %s\n" % (issue, e.reason))
                emit("ID", "issue-%s" % issue)
                emit("OUTCOME", "unchanged")
                emit("CHANGED", "no")
                emit("ROW_ERROR", "%s (exit %d)" % (e.reason.replace("\n", " "), e.code))
        emit("ROWS", len(rows))
        emit("ROWS_FAILED", failed)
        if failed == len(rows):
            raise Fatal(10, "every row failed")
        return
    gather_one(resolve_target(argv[0], paths, sd), paths, sd, base_override)


# --------------------------------------------------------------- render

def md_to_html(text):
    """Small markdown subset: headings, paragraphs, lists, fenced code,
    inline code, bold. Enough for the brief; never a general converter."""
    out, para, in_list, in_code = [], [], False, False

    def flush():
        nonlocal para
        if para:
            out.append("<p>%s</p>" % inline(" ".join(para)))
            para = []

    def inline(s):
        s = html.escape(s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        return s

    for line in text.splitlines():
        if line.startswith("```"):
            flush()
            if in_code:
                out.append("</code></pre>")
            else:
                out.append("<pre><code>")
            in_code = not in_code
            continue
        if in_code:
            out.append(html.escape(line))
            continue
        if line.startswith("<!--"):
            continue
        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m and len(m.group(1)) == 1 and not out:
            continue  # the brief's own title; the page header already carries it
        if m:
            flush()
            if in_list:
                out.append("</ul>")
                in_list = False
            lvl = len(m.group(1)) + 1
            out.append("<h%d id=\"%s\">%s</h%d>" % (lvl, re.sub(r"[^a-z0-9]+", "-", m.group(2).lower()),
                                                    inline(m.group(2)), lvl))
            continue
        m = re.match(r"^\s*[-*]\s+(.*)$", line)
        if m:
            flush()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>%s</li>" % inline(m.group(1)))
            continue
        if not line.strip():
            flush()
            if in_list:
                out.append("</ul>")
                in_list = False
            continue
        para.append(line.strip())
    flush()
    if in_list:
        out.append("</ul>")
    if in_code:
        out.append("</code></pre>")
    return "\n".join(out)


CSS = """
:root{--bg:#fbfaf7;--fg:#1f1d1a;--mut:#6b665e;--line:#e4e0d8;--acc:#9a4d2c;--add:#2e7d32;--del:#b3261e;--code:#f1eee8}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#14130f;--fg:#ece8df;--mut:#9f9a90;--line:#2b2924;--acc:#e0876a;--add:#7fc78a;--del:#f08a80;--code:#1f1d18}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,Segoe UI,Helvetica,Arial,sans-serif}
header{padding:20px 16px;border-bottom:1px solid var(--line)}header h1{margin:0 0 4px;font-size:20px}header .meta{color:var(--mut);font-size:13px}
nav{display:flex;gap:12px;flex-wrap:wrap;padding:8px 16px;border-bottom:1px solid var(--line);font-size:13px;position:sticky;top:0;background:var(--bg)}
nav a{color:var(--acc);text-decoration:none}main{max-width:1100px;margin:0 auto;padding:16px}
section{margin:0 0 32px}h2{font-size:17px;margin:24px 0 8px;border-bottom:1px solid var(--line);padding-bottom:4px}h3{font-size:15px;margin:16px 0 6px}
code{background:var(--code);padding:1px 4px;border-radius:3px;font-size:13px}pre{background:var(--code);padding:10px;overflow:auto;border-radius:4px;font-size:12.5px;line-height:1.4}
table{border-collapse:collapse;width:100%;font-size:13px}td,th{text-align:left;padding:4px 6px;border-bottom:1px solid var(--line);vertical-align:top}
.add{color:var(--add)}.del{color:var(--del)}.mut{color:var(--mut)}details{border:1px solid var(--line);border-radius:4px;margin:6px 0}
summary{cursor:pointer;padding:6px 8px;font-family:ui-monospace,Menlo,monospace;font-size:13px}details pre{margin:0;border-radius:0 0 4px 4px}
.diff .a{color:var(--add)}.diff .d{color:var(--del)}.diff .h{color:var(--acc)}input[type=search]{width:100%;padding:6px 8px;border:1px solid var(--line);border-radius:4px;background:var(--bg);color:var(--fg);margin:6px 0 10px}
.bars text{font-size:12px;fill:var(--fg)}.bars rect{fill:var(--acc)}.bars .lab{fill:var(--mut)}.pill{display:inline-block;border:1px solid var(--line);border-radius:10px;padding:0 8px;font-size:12px;margin-right:4px}
.brief p{max-width:75ch}.hidden{display:none}.gnode{cursor:pointer}.touched-row{border-left:3px solid var(--acc)}
"""

JS = """
(function(){
  var q=document.getElementById('q'); if(!q) return;
  q.addEventListener('input',function(){
    var v=q.value.toLowerCase();
    document.querySelectorAll('#files details').forEach(function(d){
      d.classList.toggle('hidden', v && d.dataset.path.toLowerCase().indexOf(v)<0);
    });
    document.querySelectorAll('#files h3').forEach(function(h){
      var any=false, el=h.nextElementSibling;
      while(el && el.tagName==='DETAILS'){ if(!el.classList.contains('hidden')) any=true; el=el.nextElementSibling; }
      h.classList.toggle('hidden', !any);
    });
  });
})();
"""


GRAPH_JS = """
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


def diff_html(text):
    out = []
    for line in text.splitlines():
        cls = ""
        if line.startswith("+++") or line.startswith("---"):
            cls = "h"
        elif line.startswith("@@"):
            cls = "h"
        elif line.startswith("+"):
            cls = "a"
        elif line.startswith("-"):
            cls = "d"
        out.append("<span class=\"%s\">%s</span>" % (cls, html.escape(line)) if cls else html.escape(line))
    return "\n".join(out)


def bars_svg(by_module):
    items = sorted(by_module.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:15]
    if not items:
        return ""
    mx = max(a + d for _, (a, d, _) in items) or 1
    w, rowh, labw = 900, 22, 260
    h = rowh * len(items) + 10
    parts = ["<svg class=\"bars\" viewBox=\"0 0 %d %d\" width=\"100%%\" role=\"img\" aria-label=\"lines changed per module\">" % (w, h)]
    for i, (name, (a, d, n)) in enumerate(items):
        y = i * rowh + 4
        bw = int((w - labw - 120) * (a + d) / mx)
        parts.append("<text x=\"0\" y=\"%d\">%s</text>" % (y + 15, html.escape(name[:34])))
        parts.append("<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"14\" rx=\"2\"/>" % (labw, y + 3, max(bw, 2)))
        parts.append("<text class=\"lab\" x=\"%d\" y=\"%d\">+%d -%d, %d files</text>" % (labw + bw + 6, y + 15, a, d, n))
    parts.append("</svg>")
    return "\n".join(parts)


def graph_fragment(kd, atlas_json):
    """Module graph section from squad-graph.py, or None when no graph.json."""
    gpath = os.path.join(kd, "graph.json")
    if not os.path.exists(gpath):
        return None
    try:
        mod = _graph_module()
        with open(gpath, encoding="utf-8") as f:
            data = json.load(f)
        ov = {"files": [x["path"] for x in atlas_json.get("files", [])], "title": atlas_json.get("title")}
        frag, _ = mod.graph_section(data, ov, "")
        return frag
    except (OSError, ValueError, AttributeError, ImportError) as e:
        sys.stderr.write("squad-atlas: graph section skipped: %s\n" % e)
        return None


def cmd_render(argv):
    if len(argv) != 1:
        fail(2, "usage: render <id>")
    paths = resolve_paths()
    sd = squad_dir(paths)
    adir = os.path.join(sd, "atlas", argv[0])
    try:
        with open(os.path.join(adir, "atlas.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        fail(10, "no atlas.json for %s; run gather first" % argv[0])
    brief_path = os.path.join(adir, "brief.md")
    brief = "\n".join(read_lines(brief_path) or [])
    if not brief.strip():
        fail(10, "brief.md is empty")

    files = data["files"]
    by_module = {}
    for x in files:
        a, d, n = by_module.get(x["module"], (0, 0, 0))
        by_module[x["module"]] = (a + x["added"], d + x["deleted"], n + 1)
    added = sum(x["added"] for x in files)
    deleted = sum(x["deleted"] for x in files)

    H = ["<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
         "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
         "<title>Atlas %s</title><style>%s</style></head><body>" % (html.escape(data["id"]), CSS),
         "<header><h1>%s</h1><div class=\"meta\">%s &middot; <code>%s...%s</code> &middot; %d commits &middot; %d files "
         "<span class=\"add\">+%d</span> <span class=\"del\">-%d</span> &middot; generated %s, source %s</div></header>"
         % (html.escape(data["title"]), html.escape(data.get("project") or ""), html.escape(data["base"]),
            html.escape(data["head"]), len(data["commits"]), len(files), added, deleted,
            data["generated"], data["source"]),
         "<nav><a href=\"#brief\">Brief</a><a href=\"#modules\">Modules</a><a href=\"#graph\">Graph</a><a href=\"#files\">Files</a>"
         "<a href=\"#tests\">Tests</a><a href=\"#criteria\">Criteria</a><a href=\"#reven\">Reven</a><a href=\"#commits\">Commits</a></nav>",
         "<main>",
         "<section id=\"brief\" class=\"brief\">%s</section>" % md_to_html(brief),
         "<section id=\"modules\"><h2>Lines changed per module</h2>%s</section>" % bars_svg(by_module),
         "<section id=\"graph\"><h2>Where it falls in the project</h2>%s</section>" % (
             graph_fragment(knowledge_dir(paths), data) or "<p class=\"mut\">No graph.json for this project; run /seed (squad-graph.py extract) to add the import graph.</p>"),
         "<section id=\"files\"><h2>Files</h2><input id=\"q\" type=\"search\" placeholder=\"filter by path\" aria-label=\"filter files\">"]
    for mod in sorted(by_module, key=lambda m: -(by_module[m][0] + by_module[m][1])):
        a, d, n = by_module[mod]
        H.append("<h3>%s <span class=\"mut\">(%d files, +%d -%d)</span></h3>" % (html.escape(mod), n, a, d))
        for x in sorted((f for f in files if f["module"] == mod), key=lambda f: f["path"]):
            note = " <span class=\"mut\">(diff cut at %d lines)</span>" % DIFF_CAP_LINES if x["capped"] else ""
            H.append("<details data-path=\"%s\"><summary>%s %s <span class=\"add\">+%d</span> <span class=\"del\">-%d</span>%s%s</summary>"
                     "<pre class=\"diff\">%s</pre></details>"
                     % (html.escape(x["path"]), x["status"], html.escape(x["path"]), x["added"], x["deleted"],
                        " <span class=\"pill\">test</span>" if x["test"] else "", note, diff_html(x["diff"])))
    H.append("</section>")
    tests = [x["path"] for x in files if x["test"]]
    H.append("<section id=\"tests\"><h2>Tests touched (%d)</h2>%s</section>" % (
        len(tests), "<ul>%s</ul>" % "".join("<li><code>%s</code></li>" % html.escape(t) for t in tests) if tests
        else "<p class=\"mut\">No test file in the diff.</p>"))
    H.append("<section id=\"criteria\"><h2>Acceptance criteria (%d)</h2>%s</section>" % (
        len(data["criteria"]), "<ol>%s</ol>" % "".join("<li>%s</li>" % html.escape(c) for c in data["criteria"])
        if data["criteria"] else "<p class=\"mut\">None found (no PR body fetched and no forge output).</p>"))
    V = data["verdicts"]
    H.append("<section id=\"reven\"><h2>Reven trail (%d rounds)</h2>%s</section>" % (
        len(V), "<table><tr><th>Round</th><th>Verdict</th><th>Observation</th></tr>%s</table>" % "".join(
            "<tr><td>r%d</td><td>%s</td><td>%s</td></tr>" % (v["round"], v["verdict"], html.escape(v["obs"]) or "<span class=\"mut\">none</span>")
            for v in V) if V else "<p class=\"mut\">No review recorded for this range.</p>"))
    H.append("<section id=\"commits\"><h2>Commits (%d)</h2><table><tr><th>sha</th><th>date</th><th>subject</th></tr>%s</table></section>" % (
        len(data["commits"]), "".join("<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>" % (
            c["sha"], c["date"], html.escape(c["subject"])) for c in data["commits"])))
    H.append("</main><script>%s</script></body></html>" % (JS + GRAPH_JS))
    out = os.path.join(adir, "index.html")
    try:
        changed = lib.write_if_changed(out, "\n".join(H))
    except OSError as e:
        fail(20, "cannot write html: %s" % e)
    emit("OUTCOME", "applied" if changed else "unchanged")
    emit("CHANGED", "yes" if changed else "no")
    emit("HTML", out)
    emit("BRIEF", brief_path)


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        sys.exit(2)
    verb, rest = sys.argv[1], sys.argv[2:]
    try:
        if verb == "gather":
            cmd_gather(rest)
        elif verb == "render":
            cmd_render(rest)
        else:
            fail(2, "unknown verb '%s'" % verb)
    except Fatal as e:
        sys.stderr.write("squad-atlas: %s\n" % e.reason)
        sys.exit(e.code)


if __name__ == "__main__":
    main()
