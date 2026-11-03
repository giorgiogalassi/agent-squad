#!/usr/bin/env python3
"""squad-graph.py -- the project's structure graph: extract, diff, render (DRAFT).

One script owns the graph; no skill extracts or compares on its own. Seed
runs `extract` then `render`; Atlas runs `diff` (through this module) and
draws its result with `change_graph_fragment`. Changing how graphs are
built or drawn means changing this file only.

Verbs (stdout follows SCRIPT_CONTRACT.md: KEY=value lines only):

  extract [--root <dir>] [--ref <ref>] [--level file|unit] [--out <graph.json>]
          [--scout <scout-cache.md>] [--cache <file>]
      Units and import edges of the project, at <ref> (default: the working
      tree, tracked and untracked-not-ignored files). `--level file` (default)
      writes one node per source file; `--level unit` writes unit-to-unit
      edges only, filling the incremental cache. Defaults: root and scout-cache
      from path-resolve.sh, out <SQUAD_DIR>/graph.json.
  diff --base <ref> --head <ref> [--root <dir>] [--merge-base <sha>]
       [--out <graph.json>] [--scout <scout-cache.md>] [--cache <file>]
      The structural change between merge-base(base, head) and head, scoped
      to the changed units plus the units that use something they changed.
      Default out: <SQUAD_DIR>/graph-diff.json.
  render --graph <graph.json> --out <file.html|file.svg>
         [--overlay <atlas.json>] [--title <text>]
      Draw the file-level graph grouped by unit (SVG plus a drill-down table).
  render --diff <diff graph.json> --out <file.html> [--remote <git url>]
      Draw the change graph of `diff` as a standalone page.

Units (nodes of the change graph, `groups` of every graph.json), first
source that yields units wins, so a unit always comes from the project's
own declarations when it has any:
  1. manifest  project.json, pyproject.toml / setup.py / setup.cfg, and
               package.json (the folders `workspaces` / pnpm-workspace.yaml
               name; with none declared, every nested package.json). The
               unit id is the manifest folder, its label the declared name.
  2. scout     the scout-cache Module map, only when at least one of its
               prefixes matches a file at this ref.
  3. folder    top-level folders, descending through folders that only hold
               other folders, so a one-file change still has a graph.
Files outside every unit are the `(workspace)` node (manifest source) or the
folder they sit in / `(root)`. Edges are imports resolved through the
project's own aliases: every target of every tsconfig/jsconfig `paths` entry
(with `extends` and `baseUrl`), workspace package names, Python top-level
packages, relative paths. No tool-specific folders are skipped: the file
list comes from git (tracked files at a ref, tracked plus untracked and
not ignored in the working tree).

graph.json, format version 2 (stable; write another renderer against it,
never a second extractor). Paths are relative to the project folder (the
folder `--root` names, which may sit below the repository root: `prefix` is
the path from the repository root to it, empty at the root). A unit is a
group; `level` says what `nodes` and `edges` hold:
  {
    "version": 2, "level": "file|unit", "kind": "extract|diff",
    "generated": "YYYY-MM-DD", "extractor": "regex", "unit_source": "manifest|scout|folder",
    "groups": [{"id": "<unit id>", "label": "<declared name>", "roots": ["<path>"],
                "source": "manifest|scout|folder", "aliases": ["<import alias>"]}],
    "nodes":  [{"id": "<path>", "group": "<unit id>", "lang": "ts", "fan_in": n,
                "fan_out": n, "in_cycle": bool, "test": bool}],      (level file)
    "edges":  [{"from": "<path>", "to": "<path>"}]                   (level file)
              [{"from": "<unit id>", "to": "<unit id>"}]             (level unit)
  }
extract adds "root" (absolute). `kind: diff` (always level unit) adds "base",
"head", "merge_base", "head_sha", "prefix", "outside" (changed files outside
the project folder) and, per group, "state" (changed: owns a changed file;
affected: outside the change but imports a name a changed declaration
exports; context: the other end of an added or removed edge), "files"
[{"status", "path", "from"?}] and "commits" [{"sha", "subject"}]; each edge
has "kind" (added|removed|unchanged, relative to merge-base) and "uses" (the
touched names the importer uses). Only the unit pairs the change explains are
edges: added, removed, between two changed units, and affected to changed.

Affected is decided per declaration: the -U0 hunks of each changed source file
select the top-level declarations they touch; their exported names are matched
against the names importers pull in (static and dynamic imports; a namespace
import counts as `*`). New, deleted and cross-unit moved files change every
name they export; barrel files (index.*, __init__.py) are not declarations.

Cache: unit-to-unit edges are cached per unit by the git tree id of its
folder (and a digest of the unit/alias configuration), so a run only reads the
units that changed since the last one. Default <vault>/projects/<name>/.squad/
graph-cache.json; `--cache ""` turns it off. A cache that cannot be written
is reported on stderr and the run goes on.

Exit codes: 0 success, 2 usage error, 10 precondition (no root, not a git
repository, unknown ref, empty merge-base, empty diff, no graph), 20 I/O or
git error. Python 3.8+ standard library only.
"""

import datetime as dt
import hashlib
import html
import json
import math
import os
import posixpath
import re
import subprocess
import sys
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import squad_pylib as lib  # noqa: E402  (write_if_changed)

WORKSPACE = "(workspace)"
ROOT_GROUP = "(root)"
EXTS = {".ts": "ts", ".tsx": "ts", ".mts": "ts", ".cts": "ts", ".js": "js", ".jsx": "js", ".mjs": "js",
        ".cjs": "js", ".py": "py", ".sh": "sh", ".bash": "sh"}
FAMILY = {"ts": "ts", "js": "ts", "py": "py", "sh": "sh"}
TEST_RE = re.compile(r"(^|/)(test|tests|spec|specs|__tests__|evals?)(/|$)|\.(test|spec)\.[a-z]+$|^scripts/test-.*\.sh$|_test\.(py|go)$")
MODULE_LINE_RE = re.compile(r"^\s*[-*]\s+(.+?)(?:\s+[-—–]+\s+|\s*[—–]\s*|:\s+)(.*)$")
PATH_RE = re.compile(r"`([^`]+)`|(?<![\w`])((?:[\w.@-]+/)+[\w.@*-]*|[\w.@-]+\.[A-Za-z]{1,5})")
SH_RE = re.compile(r"""^\s*(?:source|\.)\s+(.+?)\s*(?:;.*|#.*|\|\|.*|&&.*)?$""", re.M)
TS_FROM = re.compile(r"""\b(?:import|export)\s+(?P<what>[\w$\s,*{}]{0,2000}?)\s*from\s*['"](?P<spec>[^'"\n]+)['"]""")
TS_SIDE = re.compile(r"""\bimport\s*['"](?P<spec>[^'"\n]+)['"]""")
TS_DYN = re.compile(r"""\bimport\(\s*['"](?P<spec>[^'"\n]+)['"]\s*\)(?P<then>\s*\.then\(\s*\(?\s*(?P<v>\w+)\s*\)?\s*=>\s*(?P=v)\.(?P<n>\w+))?""")
TS_REQ = re.compile(r"""\brequire\(\s*['"](?P<spec>[^'"\n]+)['"]\s*\)""")
PY_FROM = re.compile(r"^[ \t]*from[ \t]+(\.*[\w.]*)[ \t]+import[ \t]+(\([^)]*\)|[^\n#]*)", re.M)
PY_IMPORT = re.compile(r"^[ \t]*import[ \t]+([\w.]+(?:[ \t]*,[ \t]*[\w.]+)*)", re.M)
EXPORT_DECL_RE = re.compile(r"export\s+(?:declare\s+)?(?:abstract\s+)?(?:const|let|var|function\*?|class|interface|type|enum)\s+([A-Za-z_$][\w$]*)")
EXPORT_LIST_RE = re.compile(r"export\s*(?:type\s*)?\{([^}]*)\}")
TS_TOP_RE = re.compile(r"^(?:export\s|(?:declare\s+)?(?:abstract\s+)?(?:const|let|var|function|class|interface|type|enum)\s|@\w)")
PY_TOP_RE = re.compile(r"^(?:(?:async[ \t]+)?def[ \t]+(\w+)|class[ \t]+(\w+)|([A-Za-z_]\w*)[ \t]*(?::[^=\n]+)?=(?!=)|@\w)")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)
# Bump when an extractor regex or the unit rules change: it is part of the cache key.
EXTRACTOR_VERSION = "1"
# Directories whose manifests are test data or third-party code, never project units.
NON_UNIT_DIRS = ("node_modules", "vendor", "third_party", "fixtures", "__fixtures__", "examples", "example")
# Nested manifests in a single-package repo count as its structure only when at
# most this share of the code lies outside them.
OUTSIDE_SHARE = 0.1
MANIFESTS = ("project.json", "package.json", "pyproject.toml", "setup.py", "setup.cfg")
PY_MANIFESTS = ("pyproject.toml", "setup.py", "setup.cfg")
TS_CONFIGS = ("tsconfig.base.json", "tsconfig.json", "jsconfig.json")
MAX_FILE_BYTES = 512 * 1024
MAX_COMMITS = 100
CACHE_KEEP = 6


def emit(key, value):
    sys.stdout.write("%s=%s\n" % (key, value))


class GraphError(Exception):
    """A failure with its SCRIPT_CONTRACT exit code."""

    def __init__(self, code, reason):
        Exception.__init__(self, reason)
        self.code, self.reason = code, reason


def fail(code, reason):
    raise GraphError(code, reason)


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


def default_cache(paths):
    """The vault's run-state folder (never the repo's .squad)."""
    if not paths.get("VAULT_PATH"):
        return ""
    name = paths.get("DISPLAY_NAME") or os.path.basename(paths.get("PROJECT_ROOT") or "")
    return os.path.join(paths["VAULT_PATH"], "projects", name, ".squad", "graph-cache.json") if name else ""


def read_text(path):
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return ""
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def parse_opts(argv, valued, flags=()):
    """-> dict of option values; usage error (2) on anything unknown."""
    out, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a in valued:
            if i + 1 >= len(argv):
                fail(2, "%s needs a value" % a)
            out[a[2:].replace("-", "_")] = argv[i + 1]
            i += 2
        elif a in flags:
            out[a[2:].replace("-", "_")] = True
            i += 1
        else:
            fail(2, "unknown argument '%s'" % a)
    return out


# ------------------------------------------------------------------ git

def git_bytes(root, args, inp=None, ok=(0,), code=20):
    try:
        p = subprocess.run(["git", "--literal-pathspecs"] + list(args), cwd=root, input=inp,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        fail(20, "git is not available: %s" % e)
    if p.returncode not in ok:
        msg = p.stderr.decode("utf-8", "replace").strip().splitlines()
        fail(code, "git %s failed: %s" % (args[0], msg[-1] if msg else "exit %d" % p.returncode))
    return p.stdout


def git_text(root, args, ok=(0,), code=20):
    return git_bytes(root, args, ok=ok, code=code).decode("utf-8", "replace")


def normrel(path):
    """Normalised project-relative path; '' for the project folder itself."""
    p = posixpath.normpath(path)
    if p == ".":
        return ""
    while p.startswith("./"):
        p = p[2:]
    return p.rstrip("/")


def strip_prefix(path, prefix):
    return path[len(prefix):] if prefix and path.startswith(prefix) else path


class Snapshot(object):
    """The files of a project at one point, and a way to read them."""

    def __init__(self, root):
        self.root = root
        self.files = []
        self.objs = {}   # path -> git object id (trees and blobs); empty for the working tree
        self.memo = {}

    def read(self, path):
        return self.read_many([path]).get(path, "")


class GitSnapshot(Snapshot):
    def __init__(self, root, ref):
        Snapshot.__init__(self, root)
        self.ref = ref
        out = git_bytes(root, ["ls-tree", "-r", "-t", "-z", ref])
        for rec in out.split(b"\0"):
            if not rec:
                continue
            meta, _, path = rec.decode("utf-8", "replace").partition("\t")
            mode, otype, sha = (meta.split() + ["", "", ""])[:3]
            if otype == "tree":
                self.objs[path] = sha
            elif otype == "blob" and mode != "120000":
                self.objs[path] = sha
                self.files.append(path)
        self.files.sort()

    def read_many(self, paths):
        paths = [p for p in paths if p and "\n" not in p]
        if not paths:
            return {}
        inp = "".join("%s:./%s\n" % (self.ref, p) for p in paths).encode("utf-8")
        out = git_bytes(self.root, ["cat-file", "--batch"], inp=inp)
        res, pos = {}, 0
        for p in paths:
            nl = out.find(b"\n", pos)
            if nl < 0:
                break
            head = out[pos:nl].decode("utf-8", "replace").split()
            pos = nl + 1
            if len(head) == 3 and head[1] == "blob":
                size = int(head[2])
                if size <= MAX_FILE_BYTES:
                    res[p] = out[pos:pos + size].decode("utf-8", "replace")
                pos += size + 1
        return res


class TreeSnapshot(Snapshot):
    def __init__(self, root):
        Snapshot.__init__(self, root)
        listed = None
        try:
            p = subprocess.run(["git", "ls-files", "-z", "-c", "-o", "--exclude-standard"], cwd=root,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if p.returncode == 0:
                listed = [x for x in p.stdout.decode("utf-8", "replace").split("\0") if x]
        except OSError:
            pass
        if listed is None:   # not a git repository: walk, skipping hidden folders and node_modules
            listed = []
            for dp, dns, fns in os.walk(root):
                dns[:] = [d for d in dns if not d.startswith(".") and d != "node_modules"]
                for fn in fns:
                    listed.append(os.path.relpath(os.path.join(dp, fn), root).replace(os.sep, "/"))
        self.files = sorted(f for f in set(listed) if os.path.isfile(os.path.join(root, f)))

    def read_many(self, paths):
        return {p: t for p, t in ((p, read_text(os.path.join(self.root, p))) for p in paths) if t}


# ------------------------------------------------------- unit discovery

def strip_jsonc(text):
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 1
        else:
            out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def load_json(text):
    if not text:
        return None
    for t in (text, None):
        try:
            return json.loads(t if t is not None else strip_jsonc(text))
        except ValueError:
            continue
    return None


def module_map(scout_path):
    """Groups from the scout-cache Module map, bullets or a table
    (| Module | Path | Role |). A bullet may list several paths
    (`a/`, `b/` -- label), then the label names the group and every path
    is a prefix of it; a table row is named by its first cell. Returns
    [{"id", "label", "prefixes"}]; prefixes are matched longest first."""
    groups = []
    inside = False
    for line in (read_text(scout_path) or "").splitlines():
        if line.startswith("## "):
            inside = line.lower().startswith("## module map")
            continue
        if not inside:
            continue
        if line.lstrip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 2 or set(cells[0]) <= {"-", ":"} or cells[0].lower() in ("module", "name"):
                continue
            head, label = cells[1], (cells[2] if len(cells) > 2 else cells[0])
            name = cells[0].strip("`")
        else:
            m = MODULE_LINE_RE.match(line)
            if not m:
                continue
            head, label, name = m.group(1), m.group(2).strip(), None
        prefixes = []
        for a, b in PATH_RE.findall(head):
            pth = (a or b).strip().strip("/")
            if pth and not pth.startswith("*") and pth not in prefixes:
                prefixes.append(pth.replace("/*", ""))
        if not prefixes:
            continue
        gid = name or (prefixes[0] if len(prefixes) == 1 else (label or prefixes[0]))
        if any(g["id"] == gid for g in groups):
            gid = "%s (%s)" % (gid, prefixes[0])
        groups.append({"id": gid, "label": label or gid, "prefixes": prefixes})
    return groups


def lang_of(path):
    return EXTS.get(os.path.splitext(path)[1])


class Unit(object):
    def __init__(self, uid, label, roots, source):
        self.id, self.label, self.roots, self.source = uid, label, roots, source
        self.aliases = []


class Alias(object):
    """An import alias: `pattern` (may hold one `*`) maps to target paths."""

    def __init__(self, pattern, targets, prefix=False):
        self.pattern, self.targets, self.prefix = pattern, targets, prefix

    def targets_for(self, spec):
        pat = self.pattern
        if "*" in pat:
            pre, suf = pat.split("*", 1)
            if spec.startswith(pre) and spec.endswith(suf) and len(spec) >= len(pre) + len(suf):
                cap = spec[len(pre):len(spec) - len(suf)]
                return [t.replace("*", cap) for t in self.targets]
            return []
        if spec == pat:
            return list(self.targets)
        if self.prefix and spec.startswith(pat + "/"):
            return ["%s/%s" % (t, spec[len(pat) + 1:]) for t in self.targets]
        return []


class Config(object):
    def __init__(self, source, units, aliases, py_pkgs, base_urls):
        self.source, self.units = source, dict((u.id, u) for u in units)
        self.aliases, self.py_pkgs, self.base_urls = aliases, py_pkgs, base_urls
        self.rootmap = {}
        for u in units:
            for r in u.roots:
                self.rootmap[r] = u.id
        self.exact = dict((a.pattern, a) for a in aliases if "*" not in a.pattern and not a.prefix)
        self.wild = [a for a in aliases if "*" in a.pattern or a.prefix]
        for a in aliases:
            for t in a.targets:
                uid = self.unit_of(t.replace("*", "x"))
                if uid and a.pattern not in self.units[uid].aliases:
                    self.units[uid].aliases.append(a.pattern)
        blob = json.dumps([EXTRACTOR_VERSION] + [[u.id, u.roots] for u in units] + [[a.pattern, a.targets, a.prefix] for a in aliases]
                          + [sorted(py_pkgs.items()), base_urls], sort_keys=True)
        self.digest = hashlib.sha1(blob.encode("utf-8")).hexdigest()[:12]
        self._by_unit = None

    def unit_of(self, path):
        p = path
        while p:
            if p in self.rootmap:
                return self.rootmap[p]
            p = p.rsplit("/", 1)[0] if "/" in p else ""
        return None

    def group_of(self, path):
        u = self.unit_of(path)
        if u:
            return u
        if self.source == "manifest":
            return WORKSPACE
        return path.split("/")[0] if "/" in path else ROOT_GROUP

    def by_unit(self, files):
        if self._by_unit is None:
            self._by_unit = {}
            for f in files:
                u = self.unit_of(f)
                if u:
                    self._by_unit.setdefault(u, []).append(f)
        return self._by_unit

    def alias_targets(self, spec):
        out = []
        a = self.exact.get(spec)
        if a:
            out += a.targets_for(spec)
        for a in self.wild:
            out += a.targets_for(spec)
        return out

    def spec_units(self, spec, src, family):
        """Unit ids an import specifier resolves to (the importer's own included)."""
        found = set()
        if family == "ts":
            if spec.startswith("."):
                u = self.unit_of(normrel(posixpath.join(posixpath.dirname(src), spec)))
                if u:
                    found.add(u)
            else:
                for t in self.alias_targets(spec):
                    u = self.unit_of(normrel(t))
                    if u:
                        found.add(u)
                if not found:
                    for b in self.base_urls:
                        u = self.unit_of(normrel(posixpath.join(b, spec)))
                        if u:
                            found.add(u)
        elif family == "py":
            if spec.startswith("."):
                dots = len(spec) - len(spec.lstrip("."))
                base = posixpath.dirname(src)
                for _ in range(dots - 1):
                    base = posixpath.dirname(base)
                u = self.unit_of(normrel(posixpath.join(base, spec.lstrip(".").replace(".", "/"))))
            else:
                top = spec.split(".")[0]
                d = self.py_pkgs.get(top)
                u = self.unit_of(normrel(posixpath.join(d, *spec.split(".")[1:]))) if d is not None else None
            if u:
                found.add(u)
        return found


def glob_re(pattern):
    pat = pattern.strip().strip("/")
    out, i = [], 0
    while i < len(pat):
        if pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif pat[i] == "*":
            out.append("[^/]*")
            i += 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def workspace_patterns(pkg, pnpm_text):
    pats = []
    ws = (pkg or {}).get("workspaces")
    if isinstance(ws, dict):
        ws = ws.get("packages")
    if isinstance(ws, list):
        pats += [p for p in ws if isinstance(p, str)]
    inside = False
    for line in (pnpm_text or "").splitlines():
        if re.match(r"^packages\s*:", line):
            inside = True
        elif inside and re.match(r"^\s*-\s*", line):
            pats.append(re.sub(r"^\s*-\s*['\"]?|['\"]?\s*(#.*)?$", "", line))
        elif inside and line.strip() and not line.startswith((" ", "\t")):
            inside = False
    return pats or None


def ts_paths(snap, path, depth=0):
    """-> ({pattern: [project-relative targets]}, [baseUrl dirs]) of a tsconfig, `extends` followed."""
    data = load_json(snap.read(path)) or {}
    paths, bases = {}, []
    here = posixpath.dirname(path)
    parent = data.get("extends")
    if isinstance(parent, str) and parent.startswith(".") and depth < 4:
        pp = normrel(posixpath.join(here, parent))
        pp = pp if pp.endswith(".json") else pp + ".json"
        if pp in snap.objs or not snap.objs:
            paths, bases = ts_paths(snap, pp, depth + 1)
    co = data.get("compilerOptions") if isinstance(data.get("compilerOptions"), dict) else {}
    bu = co.get("baseUrl")
    root_dir = normrel(posixpath.join(here, bu)) if isinstance(bu, str) else here
    if isinstance(bu, str):
        bases = bases + [root_dir]
    if isinstance(co.get("paths"), dict):
        for pat, tg in co["paths"].items():
            if isinstance(tg, list):
                paths[pat] = [normrel(posixpath.join(root_dir, t)) for t in tg if isinstance(t, str)]
    return paths, bases


def folder_units(files):
    """Unit roots from the folder layout: split folders that hold other folders."""
    code = [f for f in files if lang_of(f)]
    roots = []

    def expand(prefix, depth):
        cut = len(prefix) + 1 if prefix else 0
        under = [f for f in code if f.startswith(prefix + "/" if prefix else "")]
        direct = [f for f in under if "/" not in f[cut:]]
        kids = sorted(set(f[cut:].split("/")[0] for f in under if "/" in f[cut:]))
        split = depth < 3 and (len(kids) >= 2 or (len(kids) == 1 and not direct))
        if prefix and (direct or not split):
            roots.append(prefix)
        if split:
            for k in kids:
                expand(posixpath.join(prefix, k) if prefix else k, depth + 1)

    expand("", 0)
    return [Unit(r, r, [r], "folder") for r in roots]


def discover(snap, scout_path=None):
    files = snap.files
    mf = {}
    for f in files:
        b = f.rsplit("/", 1)[-1]
        if b in MANIFESTS:
            mf.setdefault(f.rsplit("/", 1)[0] if "/" in f else "", {})[b] = f
    wanted = [p for ms in mf.values() for p in ms.values()]
    wanted += [c for c in TS_CONFIGS if c in snap.objs or (not snap.objs and c in files)]
    if "pnpm-workspace.yaml" in files:
        wanted.append("pnpm-workspace.yaml")
    texts = snap.read_many(wanted)
    patterns = workspace_patterns(load_json(texts.get("package.json")), texts.get("pnpm-workspace.yaml"))
    globs = [glob_re(p) for p in patterns if not p.startswith("!")] if patterns else None
    skips = [glob_re(p[1:]) for p in patterns if p.startswith("!")] if patterns else []
    cands, pkg_names = [], {}
    for d in sorted(mf):
        if d == "":
            continue
        # Declared units (project.json, workspace-glob package.json) count wherever
        # they live; NON_UNIT_DIRS only filters manifests nothing declares.
        non_unit = any(seg in NON_UNIT_DIRS for seg in d.split("/"))
        ms = mf[d]
        name, declared = None, False
        if "project.json" in ms:
            name = (load_json(texts.get(ms["project.json"])) or {}).get("name")
            declared = True
        py = [m for m in PY_MANIFESTS if m in ms]
        if name is None and py:
            m = re.search(r"""(?m)^\s*name\s*=\s*['"]?([\w.-]+)|\bname\s*=\s*['"]([\w.-]+)['"]""", texts.get(ms[py[0]], ""))
            name = (m.group(1) or m.group(2)) if m else d
        elif name is None and "package.json" in ms:
            if globs is not None and not (any(g.match(d) for g in globs) and not any(s.match(d) for s in skips)):
                continue
            declared = globs is not None
            name = (load_json(texts.get(ms["package.json"])) or {}).get("name")
        elif "project.json" not in ms and not py:
            continue
        if non_unit and not declared:
            continue
        cands.append((d, name, declared))
    # A single-package repo (own root manifest) keeps its layout unless the nested
    # manifests that no workspace/project file declares are its actual structure.
    if any(not dec for _, _, dec in cands) and any(m in mf.get("", {}) for m in ("package.json",) + PY_MANIFESTS):
        code = [f for f in files if lang_of(f)]
        inside = [f for f in code if any(f.startswith(d + "/") for d, _, _ in cands)]
        if len(code) - len(inside) > OUTSIDE_SHARE * len(code):
            cands = [c for c in cands if c[2]]
    units = []
    for d, name, _ in cands:
        ms = mf[d]
        units.append(Unit(d, name if isinstance(name, str) and name else d, [d], "manifest"))
        pj = load_json(texts.get(ms.get("package.json", ""))) if "package.json" in ms else None
        if isinstance(pj, dict) and isinstance(pj.get("name"), str):
            pkg_names[pj["name"]] = d
    source = "manifest" if units else None
    if not units:
        groups = module_map(scout_path) if scout_path else []
        cand = [Unit(g["id"], g["label"], g["prefixes"], "scout") for g in groups]
        probe = Config("scout", cand, [], {}, [])
        if cand and any(probe.unit_of(f) for f in files):
            units, source = cand, "scout"
    if not units:
        units, source = folder_units(files), "folder"
    aliases, bases = [], []
    for c in TS_CONFIGS:
        if c in texts:
            paths, bs = ts_paths(snap, c)
            aliases += [Alias(p, t) for p, t in sorted(paths.items())]
            bases += [b for b in bs if b not in bases]
    for n, d in sorted(pkg_names.items()):
        aliases.append(Alias(n, [d], prefix=True))
    py_pkgs = {}
    inits = [f for f in files if f.endswith("/__init__.py")]
    for u in units:
        if u.source == "manifest" and any(m in mf.get(u.id, {}) for m in PY_MANIFESTS):
            for f in inits:
                m = re.match(r"^" + re.escape(u.id) + r"/(?:src/)?([A-Za-z_]\w*)/__init__\.py$", f)
                if m:
                    py_pkgs[m.group(1)] = posixpath.dirname(f)
    return Config(source, units, aliases, py_pkgs, bases)



# ------------------------------------------------------------- imports

def names_of(group):
    out = set()
    for part in group.split(","):
        part = part.strip()
        if part.startswith("type "):
            part = part[5:].strip()
        part = part.split(" as ")[0].strip()
        if part:
            out.add(part)
    return out


def imports_in(family, text):
    """-> [(spec, names)]; names is a set, {'*'} when the whole module is used."""
    out = []
    if family == "ts":
        for m in TS_FROM.finditer(text):
            what = m.group("what")
            br = re.search(r"\{([^}]*)\}", what)
            names = names_of(br.group(1)) if br and not re.search(r"\*", what) else {"*"}
            if br and re.sub(r"^type\b", "", what[:br.start()].strip().rstrip(",").strip()).strip():
                names = names | {"*"}  # `import D, { a }`: the default export is used too
            out.append((m.group("spec"), names))
        out += [(m.group("spec"), {"*"}) for m in TS_SIDE.finditer(text)]
        for m in TS_DYN.finditer(text):
            out.append((m.group("spec"), {m.group("n")} if m.group("then") else {"*"}))
        out += [(m.group("spec"), {"*"}) for m in TS_REQ.finditer(text)]
    elif family == "py":
        for m in PY_FROM.finditer(text):
            raw = m.group(2).strip().strip("()")
            names = names_of(raw.replace("\n", " "))
            out.append((m.group(1), names if names and "*" not in names else {"*"}))
        for m in PY_IMPORT.finditer(text):
            out += [(x.strip(), {"*"}) for x in m.group(1).split(",") if x.strip()]
    return out


def file_unit_imports(cfg, path, text):
    """-> [(unit id, names)] for every import of `path` that lands in a unit."""
    fam = FAMILY.get(lang_of(path) or "")
    out = []
    for spec, names in imports_in(fam, text) if fam in ("ts", "py") else []:
        for u in cfg.spec_units(spec, path, fam):
            out.append((u, names))
    return out


def scannable(path):
    return FAMILY.get(lang_of(path) or "") in ("ts", "py") and not TEST_RE.search(path)


class Cache(object):
    """Unit-to-unit edges per unit, keyed by the unit folder's git tree id."""

    def __init__(self, path):
        self.path, self.hits, self.misses, self.dirty = path or "", 0, 0, False
        self.data = {"v": 1, "units": {}}
        if self.path:
            try:
                with open(self.path, encoding="utf-8") as f:
                    d = json.load(f)
                if isinstance(d, dict) and d.get("v") == 1 and isinstance(d.get("units"), dict):
                    self.data = d
            except (OSError, ValueError):
                pass

    def get(self, uid, key, digest):
        for e in self.data["units"].get(uid, []):
            if e.get("tree") == key and e.get("cfg") == digest:
                self.hits += 1
                return e.get("targets", [])
        return None

    def put(self, uid, key, digest, targets):
        self.misses += 1
        if self.path:
            lst = [e for e in self.data["units"].get(uid, []) if not (e.get("tree") == key and e.get("cfg") == digest)]
            self.data["units"][uid] = [{"tree": key, "cfg": digest, "targets": sorted(targets)}] + lst[:CACHE_KEEP - 1]
            self.dirty = True

    def save(self):
        if not (self.path and self.dirty):
            return
        try:
            lib.write_if_changed(self.path, json.dumps(self.data, sort_keys=True))
        except OSError as e:
            sys.stderr.write("squad-graph: cache not written: %s\n" % e)


def unit_targets(snap, cfg, uid, cache):
    """Unit ids that unit `uid` imports at this snapshot (itself excluded)."""
    unit = cfg.units.get(uid)
    if not unit:
        return set()
    memo = snap.memo.setdefault(cfg.digest, {})
    if uid in memo:
        return memo[uid]
    key = None
    if snap.objs and all(r in snap.objs for r in unit.roots):
        key = "|".join(snap.objs[r] for r in unit.roots)
    cached = cache.get(uid, key, cfg.digest) if (cache and key) else None
    if cached is not None:
        memo[uid] = set(cached)
        return memo[uid]
    files = [f for f in cfg.by_unit(snap.files).get(uid, []) if scannable(f)]
    targets = set()
    for f, text in snap.read_many(files).items():
        for u, _ in file_unit_imports(cfg, f, text):
            if u != uid:
                targets.add(u)
    if cache:
        cache.put(uid, key, cfg.digest, targets)
    memo[uid] = targets
    return targets


# ------------------------------------------------------------- extract

def resolve_target(spec, src, lang, files, cfg):
    """Map an import specifier to a project file, or None for packages."""
    cands = []
    fam = FAMILY.get(lang)
    if fam == "ts":
        bases = []
        if spec.startswith("."):
            bases.append(normrel(posixpath.join(posixpath.dirname(src), spec)))
        else:
            bases += [normrel(t) for t in cfg.alias_targets(spec)]
            bases += [normrel(posixpath.join(b, spec)) for b in cfg.base_urls]
            if spec.startswith(("src/", "app/", "libs/", "apps/", "packages/")):
                bases.append(spec)
        for base in bases:
            for suf in ("", ".ts", ".tsx", ".js", ".jsx", ".mjs", "/index.ts", "/index.tsx", "/index.js"):
                cands.append(base + suf)
    elif fam == "py":
        if spec.startswith("."):
            dots = len(spec) - len(spec.lstrip("."))
            parts = os.path.dirname(src).split("/") if "/" in src else []
            parts = parts[:len(parts) - (dots - 1)] if dots > 1 else parts
            tail = spec.lstrip(".").replace(".", "/")
            base = "/".join([p for p in parts if p] + ([tail] if tail else []))
        else:
            top = spec.split(".")[0]
            d = cfg.py_pkgs.get(top)
            base = posixpath.join(d, *spec.split(".")[1:]) if d is not None else spec.replace(".", "/")
        cands += [base + ".py", base + "/__init__.py"]
    elif fam == "sh":
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


def file_specs(lang, text):
    fam = FAMILY.get(lang)
    if fam == "ts":
        return [s for s, _ in imports_in("ts", text)]
    if fam == "py":
        return [s for s, _ in imports_in("py", text)]
    if fam == "sh":
        return [m.group(1) for m in SH_RE.finditer(text)]
    return []


def cmd_extract(argv):
    o = parse_opts(argv, ("--root", "--ref", "--level", "--out", "--scout", "--cache"))
    level = o.get("level", "file")
    if level not in ("file", "unit"):
        fail(2, "--level must be file or unit")
    paths = resolve_paths()
    root = os.path.abspath(o.get("root") or paths.get("PROJECT_ROOT") or "")
    if not root or not os.path.isdir(root):
        fail(10, "no root: pass --root or resolve the project")
    squad_dir = paths.get("DIR") or ""
    out = o.get("out") or (os.path.join(squad_dir, "graph.json") if squad_dir else None)
    if not out:
        fail(10, "no --out and no squad dir")
    scout = o.get("scout") or (os.path.join(squad_dir, "scout-cache.md") if squad_dir else None)
    ref = o.get("ref")
    if ref:
        git_text(root, ["rev-parse", "--show-prefix"], code=10)
        if not git_text(root, ["rev-parse", "--verify", "-q", ref + "^{commit}"], ok=(0, 1)).strip():
            fail(10, "unknown ref '%s'" % ref)
    snap = GitSnapshot(root, ref) if ref else TreeSnapshot(root)
    cfg = discover(snap, scout)
    if level == "unit":
        cache = Cache(o["cache"] if "cache" in o else default_cache(paths))
        edges = sorted((u, t) for u in cfg.units for t in unit_targets(snap, cfg, u, cache))
        cache.save()
        data = new_doc("extract", "unit", cfg)
        data.update({"root": root, "nodes": [], "edges": [{"from": a, "to": b} for a, b in edges]})
        stats = [("UNITS", len(cfg.units)), ("EDGES", len(edges)), ("CACHE_HITS", cache.hits), ("CACHE_MISSES", cache.misses)]
    else:
        files = dict((f, lang_of(f)) for f in snap.files if lang_of(f))
        fileset = set(files)
        edges = set()
        for src, text in snap.read_many(list(files)).items():
            for spec in file_specs(files[src], text):
                tgt = resolve_target(spec, src, files[src], fileset, cfg)
                if tgt and tgt != src:
                    edges.add((src, tgt))
        fan_in, fan_out = {}, {}
        for a, b in edges:
            fan_out[a] = fan_out.get(a, 0) + 1
            fan_in[b] = fan_in.get(b, 0) + 1
        cyc = tarjan_cycles(list(files), edges)
        nodes, seen = [], {}
        for p in sorted(files):
            g = cfg.group_of(p)
            seen.setdefault(g, 1)
            nodes.append({"id": p, "group": g, "lang": files[p], "fan_in": fan_in.get(p, 0),
                          "fan_out": fan_out.get(p, 0), "in_cycle": p in cyc, "test": bool(TEST_RE.search(p))})
        data = new_doc("extract", "file", cfg, extra_groups=sorted(seen))
        data.update({"root": root, "nodes": nodes, "edges": [{"from": a, "to": b} for a, b in sorted(edges)]})
        stats = [("FILES", len(nodes)), ("EDGES", len(edges)), ("MODULES", len(data["groups"])),
                 ("CYCLES", sum(1 for n in nodes if n["in_cycle"])),
                 ("UNTESTED_MODULES", sum(1 for g in data["groups"] if not any(n["test"] for n in nodes if n["group"] == g["id"])))]
    emit_head("GRAPH", out, write_graph(out, data))
    for k, v in stats:
        emit(k, v)
    emit("UNIT_SOURCE", cfg.source)
    emit("EXTRACTOR", "regex")


def new_doc(kind, level, cfg, extra_groups=()):
    groups = [{"id": u.id, "label": u.label, "roots": u.roots, "source": u.source, "aliases": sorted(u.aliases)}
              for u in sorted(cfg.units.values(), key=lambda u: u.id)]
    known = set(cfg.units)
    for g in extra_groups:
        if g not in known:
            groups.append({"id": g, "label": WORKSPACE + " files outside any unit" if g == WORKSPACE else g,
                           "roots": [], "source": cfg.source if g != WORKSPACE else "workspace", "aliases": []})
    return {"version": 2, "level": level, "kind": kind, "generated": dt.date.today().isoformat(),
            "extractor": "regex", "unit_source": cfg.source, "groups": groups}


def write_graph(out, data):
    """True when the file content changed."""
    try:
        return lib.write_if_changed(out, json.dumps(data, indent=1))
    except OSError as e:
        fail(20, "cannot write graph: %s" % e)


def emit_head(key, out, changed):
    emit("OUTCOME", "applied" if changed else "unchanged")
    emit("CHANGED", "yes" if changed else "no")
    emit(key, out)



# ---------------------------------------------------------------- diff

def exported_names(family, text):
    if family == "py":
        return set(n for m in PY_TOP_RE.finditer(text or "") for n in m.groups() if n and not n.startswith("_"))
    names = set(EXPORT_DECL_RE.findall(text or ""))
    for group in EXPORT_LIST_RE.findall(text or ""):
        for part in group.split(","):
            part = part.strip().split(" as ")[-1].strip()
            if part:
                names.add(part)
    return names


def touched_exports(family, text, lines):
    """Exported names whose top-level declaration contains a changed line."""
    rows = (text or "").splitlines()
    top = TS_TOP_RE if family == "ts" else PY_TOP_RE
    starts = []
    for i, r in enumerate(rows):
        if not top.match(r):
            continue
        # a declaration keeps the decorator block above it
        if starts and rows[starts[-1] - 1].startswith("@") and not r.startswith("@"):
            continue
        starts.append(i + 1)
    starts.append(len(rows) + 1)
    names = set()
    for k, start in enumerate(starts[:-1]):
        if any(n in lines for n in range(start, starts[k + 1])):
            names |= exported_names(family, "\n".join(rows[start - 1:starts[k + 1] - 1]))
    return names


def is_barrel(path):
    b = posixpath.basename(path)
    return b.startswith("index.") or b == "__init__.py"


def name_status(raw):
    """Parse `git diff --name-status -z` -> [(status letter, old path, new path)]."""
    toks = [t for t in raw.split("\0")]
    if toks and toks[-1] == "":
        toks.pop()
    out, i = [], 0
    while i < len(toks):
        st = toks[i][:1]
        if st in ("R", "C"):
            out.append(("R" if st == "R" else "A", toks[i + 1], toks[i + 2]))
            i += 3
        else:
            p = toks[i + 1]
            out.append((st, None if st == "A" else p, None if st == "D" else p))
            i += 2
    return out


def hunk_lines(root, mb, head, bp, hp):
    """Changed line numbers on each side of one file's diff (-U0 hunks)."""
    spec = [bp or hp] if bp == hp else [x for x in (bp, hp) if x]
    out = git_text(root, ["diff", "-U0", "-M", mb, head, "--"] + spec)
    old_l, new_l = set(), set()
    for m in HUNK_RE.finditer(out):
        a, b, c, d = int(m.group(1)), int(m.group(2) or 1), int(m.group(3)), int(m.group(4) or 1)
        old_l.update(range(a, a + b))
        new_l.update(range(c, c + d))
    return old_l, new_l


def build_diff(root, base, head, merge_base=None, scout=None, cache_path=None):
    """-> (doc, stats) for the structural change merge-base(base, head)..head."""
    prefix = git_text(root, ["rev-parse", "--show-prefix"], code=10).strip()

    def rev(ref):
        sha = git_text(root, ["rev-parse", "--verify", "-q", ref + "^{commit}"], ok=(0, 1)).strip()
        if not sha:
            fail(10, "unknown ref '%s'" % ref)
        return sha
    bsha, hsha = rev(base), rev(head)
    mb = merge_base and rev(merge_base) or git_text(root, ["merge-base", bsha, hsha], ok=(0, 1)).strip()
    if not mb:
        fail(10, "no merge-base between %s and %s" % (base, head))
    entries = name_status(git_bytes(root, ["diff", "--name-status", "-M", "-z", "--relative", mb, hsha]).decode("utf-8", "replace"))
    if not entries:
        fail(10, "no changes under the project folder between %s and %s" % (mb[:12], head))
    n_all = len([x for x in git_bytes(root, ["diff", "--name-only", "-z", "--no-renames", mb, hsha]).split(b"\0") if x])
    n_rel = len([x for x in git_bytes(root, ["diff", "--name-only", "-z", "--no-renames", "--relative", mb, hsha]).split(b"\0") if x])
    outside = max(0, n_all - n_rel)
    sb, sh = GitSnapshot(root, mb), GitSnapshot(root, hsha)
    cfg_b, cfg_h = discover(sb, scout), discover(sh, scout)
    cache = Cache(cache_path)

    files_by_unit = {}
    for st, bp, hp in entries:
        uid = cfg_h.group_of(hp) if hp else cfg_b.group_of(bp)
        rec = {"status": st, "path": hp or bp}
        if st == "R" and bp != hp:
            rec["from"] = bp
        files_by_unit.setdefault(uid, []).append(rec)
        if st == "R" and bp != hp and cfg_b.group_of(bp) != uid:
            files_by_unit.setdefault(cfg_b.group_of(bp), []).append({"status": "D", "path": bp})
    changed = set(files_by_unit)

    # unit edges of the changed units, at merge-base and at head
    base_e, head_e = set(), set()
    for u in changed:
        base_e |= set((u, t) for t in unit_targets(sb, cfg_b, u, cache))
        head_e |= set((u, t) for t in unit_targets(sh, cfg_h, u, cache))

    # names this change touched, per unit
    changed_names = {}
    for st, bp, hp in entries:
        ref_path = hp or bp
        fam = FAMILY.get(lang_of(ref_path) or "")
        if fam not in ("ts", "py") or TEST_RE.search(ref_path) or is_barrel(ref_path):
            continue
        u = cfg_h.unit_of(hp) if hp else cfg_b.unit_of(bp)
        if not u:
            continue
        base_text = sb.read(bp) if bp else ""
        head_text = sh.read(hp) if hp else ""
        old_u = cfg_b.unit_of(bp) if bp else None
        moved = st == "R" and old_u != u
        if st in ("A", "D") or moved:
            names = exported_names(fam, base_text) | exported_names(fam, head_text)
        else:
            old_l, new_l = hunk_lines(root, mb, hsha, bp, hp)
            names = touched_exports(fam, base_text, old_l) | touched_exports(fam, head_text, new_l)
        if names:
            changed_names.setdefault(u, set()).update(names)
            if moved and old_u:
                changed_names.setdefault(old_u, set()).update(names)

    # affected: units outside the change that import one of those names
    uses = {}
    if changed_names:
        importers = {}
        for uid in cfg_h.units:
            for t in unit_targets(sh, cfg_h, uid, cache):
                importers.setdefault(t, set()).add(uid)
        for u, names in changed_names.items():
            for d in sorted(importers.get(u, set()) - changed):
                files = [f for f in cfg_h.by_unit(sh.files).get(d, []) if scannable(f)]
                for f, text in sh.read_many(files).items():
                    for target, imp in file_unit_imports(cfg_h, f, text):
                        if target == u:
                            used = names & imp
                            if "*" in imp:
                                used = used | {"*"}
                            if used:
                                uses.setdefault((d, u), set()).update(used)
    edges = {}
    for e in head_e - base_e:
        edges[e] = "added"
    for e in base_e - head_e:
        edges[e] = "removed"
    for a, b in head_e & base_e:
        if a in changed and b in changed:
            edges[(a, b)] = "unchanged"
    for e in uses:
        edges.setdefault(e, "unchanged")
    affected = set(d for d, u in uses if d not in changed)
    context = set(b for (a, b), k in edges.items() if k != "unchanged" and b not in changed and b not in affected)
    context |= set(a for (a, b), k in edges.items() if k != "unchanged" and a not in changed and a not in affected)

    groups = []
    for uid in sorted(changed | affected | context):
        unit = cfg_h.units.get(uid) or cfg_b.units.get(uid)
        state = "changed" if uid in changed else "affected" if uid in affected else "context"
        commits, total = [], 0
        if uid in changed:
            spec = list(unit.roots) if unit else [f["path"] for f in files_by_unit[uid][:200]]
            log = git_text(root, ["log", "--format=%H%x09%s", "%s..%s" % (mb, hsha), "--"] + spec)
            rows = [l.split("\t", 1) for l in log.splitlines() if "\t" in l]
            total = len(rows)
            commits = [{"sha": r[0], "subject": r[1][:160]} for r in rows[:MAX_COMMITS]]
        groups.append({
            "id": uid, "label": unit.label if unit else ("workspace (files outside any unit)" if uid == WORKSPACE else uid),
            "roots": unit.roots if unit else [], "source": unit.source if unit else cfg_h.source,
            "aliases": sorted(unit.aliases) if unit else [], "state": state,
            "files": sorted(files_by_unit.get(uid, []), key=lambda f: f["path"]),
            "commits": commits, "commits_total": total})
    doc = {"version": 2, "level": "unit", "kind": "diff", "generated": dt.date.today().isoformat(),
           "extractor": "regex", "unit_source": cfg_h.source, "base": base, "head": head, "merge_base": mb,
           "head_sha": hsha, "prefix": prefix, "outside": outside, "nodes": [], "groups": groups,
           "edges": [{"from": a, "to": b, "kind": k, "uses": sorted(uses.get((a, b), []))}
                     for (a, b), k in sorted(edges.items())]}
    cache.save()
    return doc, {"hits": cache.hits, "misses": cache.misses, "cache": cache_path or "off"}


def cmd_diff(argv):
    o = parse_opts(argv, ("--root", "--base", "--head", "--merge-base", "--out", "--scout", "--cache"))
    if not o.get("base") or not o.get("head"):
        fail(2, "usage: diff --base <ref> --head <ref> [--root <dir>] [--merge-base <sha>] [--out <graph.json>] [--scout <file>] [--cache <file>]")
    paths = resolve_paths()
    root = os.path.abspath(o.get("root") or paths.get("PROJECT_ROOT") or "")
    if not root or not os.path.isdir(root):
        fail(10, "no root: pass --root or resolve the project")
    squad_dir = paths.get("DIR") or ""
    out = o.get("out") or (os.path.join(squad_dir, "graph-diff.json") if squad_dir else None)
    if not out:
        fail(10, "no --out and no squad dir")
    scout = o.get("scout") or (os.path.join(squad_dir, "scout-cache.md") if squad_dir else None)
    cache = o["cache"] if "cache" in o else default_cache(paths)
    doc, st = build_diff(root, o["base"], o["head"], o.get("merge_base"), scout, cache)
    emit_head("GRAPH", out, write_graph(out, doc))
    emit("BASE", doc["base"])
    emit("HEAD", doc["head"])
    emit("MERGE_BASE", doc["merge_base"][:12])
    emit("UNIT_SOURCE", doc["unit_source"])
    emit("PREFIX", doc["prefix"])
    emit("OUTSIDE", doc["outside"])
    for state in ("changed", "affected", "context"):
        emit("UNITS_" + state.upper(), sum(1 for g in doc["groups"] if g["state"] == state))
    emit("EDGES_ADDED", sum(1 for e in doc["edges"] if e["kind"] == "added"))
    emit("EDGES_REMOVED", sum(1 for e in doc["edges"] if e["kind"] == "removed"))
    emit("CACHE_HITS", st["hits"])
    emit("CACHE_MISSES", st["misses"])
    emit("CACHE", st["cache"])


# -------------------------------------------------------------- hosts

def host_urls(remote):
    """Commit and source URL prefixes from a git remote URL, or None for a host
    whose URL shapes are unknown. Credentials in the remote are dropped."""
    remote = (remote or "").strip()
    m = re.match(r"^(?:https?|ssh|git)://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+?)(?:\.git)?/?$", remote) \
        or re.match(r"^(?:[^@/:]+@)?([^:/]+):(?!//)(.+?)(?:\.git)?/?$", remote)
    if not m:
        return None
    host, path = m.group(1).lower(), m.group(2).strip("/")
    if not re.match(r"^[a-z0-9.-]+$", host) or not re.match(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$", path):
        return None
    base = "https://%s/%s" % (host, path)
    if host == "github.com":
        return {"kind": "github", "commit": base + "/commit/", "src": base + "/blob/"}
    if host == "bitbucket.org":
        return {"kind": "bitbucket", "commit": base + "/commits/", "src": base + "/src/"}
    if host == "gitlab.com":
        return {"kind": "gitlab", "commit": base + "/-/commit/", "src": base + "/-/blob/"}
    return None


def safe_url(url):
    return url if re.match(r"^https://[^\s\"'<>\\]+$", url or "") else None




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



def json_for_script(obj):
    """JSON safe inside a <script> element: no `<`, `>` or `&` survive, and
    ensure_ascii escapes U+2028/U+2029."""
    return json.dumps(obj, separators=(",", ":")).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


CHANGE_CSS = """
.cg{--cg-chg:#9a4d2c;--cg-aff:#2f6f8f;--cg-ctx:#9b968c;--cg-add:#2e7d32;--cg-del:#b3261e;--cg-line:#c9c4ba;--cg-card:#fff;--cg-fg:#1f1d1a;--cg-mut:#6b665e;color:var(--cg-fg)}
@media (prefers-color-scheme:dark){.cg{--cg-chg:#e08a5f;--cg-aff:#6fb3d4;--cg-ctx:#7d786f;--cg-add:#7fc583;--cg-del:#f08b84;--cg-line:#4a463f;--cg-card:#201e1b;--cg-fg:#ece8e1;--cg-mut:#a39d93}}
.cg .legend{display:flex;gap:14px;flex-wrap:wrap;padding:6px 0;font-size:12px}
.cg .sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:middle}
.cg .body{display:grid;grid-template-columns:minmax(0,3fr) minmax(260px,1fr);border:1px solid var(--cg-line);border-radius:6px}
.cg .canvas{overflow:auto;border-right:1px solid var(--cg-line)}.cg svg{display:block}
.cg .panel{padding:12px 16px;max-height:520px;overflow:auto}.cg .panel h4{margin:.8em 0 .3em;font-size:13px}
.cg .panel ul{padding-left:18px;margin:.3em 0}.cg .panel li{margin:.15em 0;font-size:13px;word-break:break-all}
.cg .mut{color:var(--cg-mut)}.cg .node rect{rx:6;stroke-width:1.5;fill:var(--cg-card);cursor:pointer}
.cg .node text{font-size:12px;pointer-events:none;fill:var(--cg-fg)}.cg .node.sel rect{stroke-width:3}
.cg .node.changed rect{stroke:var(--cg-chg)}.cg .node.affected rect{stroke:var(--cg-aff)}.cg .node.context rect{stroke:var(--cg-ctx)}
.cg .edge{fill:none;stroke:var(--cg-line);stroke-width:1.4}.cg .edge.added{stroke:var(--cg-add);stroke-width:2.6}
.cg .edge.removed{stroke:var(--cg-del);stroke-width:2.6;stroke-dasharray:5 4}
.cg .mk-added{fill:var(--cg-add)}.cg .mk-removed{fill:var(--cg-del)}.cg .mk-unchanged{fill:var(--cg-line)}
@media (max-width:900px){.cg .body{grid-template-columns:1fr}.cg .canvas{border-right:0;border-bottom:1px solid var(--cg-line)}}
"""

CHANGE_JS = r"""
(function(){
var el=document.getElementById('cg-data');var G=JSON.parse(el.textContent);
var NS='http://www.w3.org/2000/svg';
function h(tag,attrs,kids){var e=document.createElement(tag);for(var k in attrs||{})e.setAttribute(k,attrs[k]);(kids||[]).forEach(function(c){e.appendChild(typeof c==='string'?document.createTextNode(c):c)});return e}
function sv(tag,attrs){var e=document.createElementNS(NS,tag);for(var k in attrs||{})e.setAttribute(k,attrs[k]);return e}
function safe(u){return (typeof u==='string'&&/^https:\/\/[^\s"'<>\\]+$/.test(u))?u:null}
function trunc(t,n){return t.length>n?t.slice(0,n-1)+'…':t}
function link(url,text,code){var u=safe(url);var inner=code?h('code',{},[text]):document.createTextNode(text);if(!u)return inner;var a=h('a',{href:u,target:'_blank',rel:'noopener noreferrer'});a.appendChild(inner);return a}
var cols={affected:[],changed:[],context:[]};G.groups.forEach(function(g){cols[g.state].push(g)});
var W=280,H=34,GX=90,GY=14,order=['affected','changed','context'];
var rows=Math.max(1,cols.affected.length,cols.changed.length,cols.context.length);
var height=rows*(H+GY)+40,width=3*W+2*GX+40,pos={};
order.forEach(function(k,i){var c=cols[k];var off=(height-c.length*(H+GY))/2;c.forEach(function(g,j){pos[g.id]={x:20+i*(W+GX),y:off+j*(H+GY)}})});
var svg=sv('svg',{width:width,height:height,viewBox:'0 0 '+width+' '+height,role:'img','aria-label':'Change graph'});
var defs=sv('defs');['added','removed','unchanged'].forEach(function(k){var m=sv('marker',{id:'cg-m-'+k,viewBox:'0 0 10 10',refX:9,refY:5,markerWidth:7,markerHeight:7,orient:'auto'});m.appendChild(sv('path',{d:'M0,0L10,5L0,10z','class':'mk-'+k}));defs.appendChild(m)});
svg.appendChild(defs);
var byId={};G.groups.forEach(function(g){byId[g.id]=g});
G.edges.forEach(function(e){var a=pos[e.from],b=pos[e.to];if(!a||!b)return;
 var ax=a.x+(b.x>=a.x?W:0),bx=b.x+(b.x>=a.x?0:W),ay=a.y+H/2,by=b.y+H/2,dx=(bx-ax)/2||40;
 var d=a.x===b.x?'M'+(a.x+W)+','+ay+' C'+(a.x+W+60)+','+ay+' '+(b.x+W+60)+','+by+' '+(b.x+W)+','+by:'M'+ax+','+ay+' C'+(ax+dx)+','+ay+' '+(bx-dx)+','+by+' '+bx+','+by;
 svg.appendChild(sv('path',{d:d,'class':'edge '+e.kind,'marker-end':'url(#cg-m-'+e.kind+')'}))});
var sel=null,panel=document.getElementById('cg-panel');
function name(id){return byId[id]?byId[id].label:id}
function list(items,fn){var ul=h('ul');items.forEach(function(i){ul.appendChild(h('li',{},fn(i)))});return ul}
function show(n){panel.textContent='';panel.appendChild(h('h3',{},[n.label]));panel.appendChild(h('div',{'class':'mut'},[n.id+' · '+n.state]));
 if(n.files.length){panel.appendChild(h('h4',{},['Files in this change ('+n.files.length+')']));panel.appendChild(list(n.files,function(f){return [f.s+' ',link(f.url,f.p)]}))}
 if(n.commits.length){panel.appendChild(h('h4',{},['Commits that touched it ('+(n.commits_total||n.commits.length)+')']));panel.appendChild(list(n.commits,function(c){return [link(c.url,c.h,true),' '+c.m]}))}
 var outs=G.edges.filter(function(e){return e.from===n.id}),ins=G.edges.filter(function(e){return e.to===n.id});
 function dep(key){return function(e){var out=[];if(e.kind!=='unchanged')out.push(h('strong',{},[e.kind+' ']));out.push(name(e[key]));if(e.uses.length){out.push(h('br'));out.push(h('span',{'class':'mut'},['uses ']));e.uses.forEach(function(u,i){if(i)out.push(', ');out.push(h('code',{},[u]))})}return out}}
 if(outs.length){panel.appendChild(h('h4',{},['Depends on']));panel.appendChild(list(outs,dep('to')))}
 if(ins.length){panel.appendChild(h('h4',{},['Used by']));panel.appendChild(list(ins,dep('from')))}}
G.groups.forEach(function(n){var p=pos[n.id];var g=sv('g',{'class':'node '+n.state,tabindex:0,role:'button','aria-label':n.label+', '+n.state});
 g.appendChild(sv('rect',{x:p.x,y:p.y,width:W,height:H}));
 var t=sv('text',{x:p.x+10,y:p.y+21});t.textContent=trunc(n.label,38)+(n.files.length?' · '+n.files.length+' files':'');g.appendChild(t);
 var ti=sv('title');ti.textContent=n.label;g.appendChild(ti);
 function pick(){if(sel)sel.classList.remove('sel');sel=g;g.classList.add('sel');show(n)}
 g.addEventListener('click',pick);g.addEventListener('keydown',function(ev){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();pick()}});svg.appendChild(g)});
document.getElementById('cg-canvas').appendChild(svg);
})();
"""


def change_graph_fragment(doc, host=None):
    """HTML fragment (style, legend, canvas, panel, data, script) for a `diff`
    graph. `host` is host_urls() output; without it nodes list files and
    commits as plain text. Everything the page script reads is escaped JSON;
    the script builds nodes with textContent and follows https links only."""
    head, prefix = doc.get("head_sha") or "", doc.get("prefix") or ""
    groups = []
    for g in doc["groups"]:
        files = []
        for f in g.get("files", []):
            url = safe_url(host["src"] + head + "/" + quote(prefix + f["path"])) if host and head else None
            files.append({"s": f["status"], "p": f["path"], "url": url})
        commits = []
        for c in g.get("commits", []):
            url = safe_url(host["commit"] + quote(c["sha"])) if host else None
            commits.append({"h": c["sha"][:7], "m": c["subject"], "url": url})
        groups.append({"id": g["id"], "label": g["label"], "state": g["state"], "files": files,
                       "commits": commits, "commits_total": g.get("commits_total", len(commits))})
    edges = [{"from": e["from"], "to": e["to"], "kind": e["kind"], "uses": e.get("uses", [])} for e in doc["edges"]]
    return (
        "<style>%s</style><div class=\"cg\"><div class=\"legend\">"
        "<span><i class=\"sw\" style=\"background:var(--cg-chg)\"></i>changed</span>"
        "<span><i class=\"sw\" style=\"background:var(--cg-aff)\"></i>affected (uses a name this change touched)</span>"
        "<span><i class=\"sw\" style=\"background:var(--cg-ctx)\"></i>context (dependency added or removed)</span>"
        "<span style=\"color:var(--cg-add)\">&mdash; edge added</span><span style=\"color:var(--cg-del)\">&#8943; edge removed</span>"
        "<span class=\"mut\">&mdash; unchanged</span></div>"
        "<div class=\"body\"><div class=\"canvas\" id=\"cg-canvas\"></div>"
        "<aside class=\"panel\" id=\"cg-panel\"><p class=\"mut\">Select a node to see its files and the commits that touched it.</p></aside></div>"
        "<script type=\"application/json\" id=\"cg-data\">%s</script><script>%s</script></div>"
        % (CHANGE_CSS, json_for_script({"groups": groups, "edges": edges}), CHANGE_JS))


def cmd_render(argv):
    o = parse_opts(argv, ("--graph", "--out", "--overlay", "--title", "--diff", "--remote"))
    graph, out, overlay, title, diff = o.get("graph"), o.get("out"), o.get("overlay"), o.get("title"), o.get("diff")
    if not out or bool(graph) == bool(diff):
        fail(2, "usage: render --graph <graph.json> --out <file> [--overlay <atlas.json>] [--title <text>] | render --diff <graph.json> --out <file.html> [--remote <git url>]")
    try:
        with open(graph or diff, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        fail(10, "no graph at %s" % (graph or diff))
    if diff:
        if data.get("kind") != "diff":
            fail(10, "%s is not a diff graph" % diff)
        host = host_urls(o.get("remote", ""))
        title = title or "Change graph"
        doc = ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
               "<title>%s</title></head><body><main style=\"font:15px/1.5 system-ui,sans-serif;max-width:1100px;margin:0 auto;padding:16px\">"
               "<h1 style=\"font-size:20px\">%s</h1>%s</main></body></html>" % (html.escape(title), html.escape(title), change_graph_fragment(data, host)))
        stats = None
    else:
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
            doc, stats = module_svg(data, ov)[0], None
        else:
            body, stats = graph_section(data, ov, title)
            doc = ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                   "<title>%s</title><style>%s</style></head><body><main><h1>%s</h1><div class=\"meta\">%d files, %d edges, generated %s, extractor %s%s</div>"
                   "<h2>Modules</h2>%s</main><script>%s</script></body></html>"
                   % (html.escape(title), PAGE_CSS, html.escape(title), len(data["nodes"]), len(data["edges"]),
                      data.get("generated", "?"), data.get("extractor", "?"),
                      (", overlay: %s" % html.escape(ov["title"] or overlay)) if ov else "", body, PAGE_JS))
    try:
        changed = lib.write_if_changed(out, doc)
    except OSError as e:
        fail(20, "cannot write: %s" % e)
    emit("OUTCOME", "applied" if changed else "unchanged")
    emit("CHANGED", "yes" if changed else "no")
    emit("OUT", out)
    if stats:
        emit("MODULES", stats["modules"])
        emit("MODULE_EDGES", stats["edges"])
        emit("TOUCHED_MODULES", stats["touched_modules"])


def main():
    if len(sys.argv) >= 2 and sys.argv[1] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        sys.exit(0)
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    verb, rest = sys.argv[1], sys.argv[2:]
    if any(a in ("-h", "--help") for a in rest):
        sys.stdout.write(__doc__)
        sys.exit(0)
    try:
        if verb == "extract":
            cmd_extract(rest)
        elif verb == "diff":
            cmd_diff(rest)
        elif verb == "render":
            cmd_render(rest)
        else:
            fail(2, "unknown verb '%s'" % verb)
    except GraphError as e:
        sys.stderr.write("squad-graph: %s\n" % e.reason)
        sys.exit(e.code)


if __name__ == "__main__":
    main()
