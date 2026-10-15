#!/usr/bin/env python3
"""squad-stats.py -- usage, cost and outcome stats for the squad.

Verbs (stdout follows SCRIPT_CONTRACT.md: KEY=value lines only):

  collect             Import Claude Code transcripts into the stats store.
  report [--days N]   Aggregate the store (plus GitHub PR outcomes in
                      connected mode) into a Markdown report.

Two layers, kept apart on purpose: importers turn a source into
normalized rows; the report reads only normalized rows. Transcripts are
the first importer. A later OpenTelemetry importer writes the same rows
and the report does not change.

Store: $SQUAD_STATS_DIR, else $SECOND_BRAIN_PATH/squad-stats, else
~/second-brain/squad-stats. Files:
  usage.tsv     one row per API message (deduped by message id)
  verdicts.tsv  one row per Reven verdict
  prices.json   optional override, model key -> [input, cache_write_5m,
                cache_write_1h, cache_read, output] in USD per MTok
  reports/      generated reports

Transcripts: $CLAUDE_PROJECTS_DIR, else $CLAUDE_CONFIG_DIR/projects,
else ~/.claude/projects. Claude Code prunes transcripts older than
`cleanupPeriodDays` (default 30), so `collect` must run regularly: rows
already in the store survive the pruning.

Cost is the API-list-price equivalent. On a subscription it is a
comparison unit, not what you pay.

Exit codes: 0 success, 2 usage error, 10 precondition (vault missing),
20 I/O error. A gh failure during `report` is not fatal: the report is
written without the GitHub section and QUALITY=gh-error is emitted
(exception documented in SCRIPT_CONTRACT.md).

Python 3.8+ standard library only.
"""

import bisect
import datetime as dt
import glob
import json
import os
import re
import statistics
import subprocess
import sys

SQUAD_SKILLS = {
    "forge", "archy", "chisel", "ralph", "reven", "lore", "seed",
    "sidecar", "challenge", "stats",
}
SQUAD_AGENTS = {"cody", "reven", "lore", "challenge"}

# USD per million tokens: input, cache write 5m, cache write 1h, cache read, output.
# Source: platform.claude.com/docs/en/about-claude/pricing (October 2026).
# Keys are model ids without the "claude-" prefix and date suffix. Exact
# match only: an unknown model is reported as unpriced, never guessed.
DEFAULT_PRICES = {
    "fable-5-1": [10, 12.5, 20, 0.25, 50],
    "mythos-5-1": [10, 12.5, 20, 0.25, 50],
    "opus-5-5": [4, 5, 8, 0.20, 20],
    "sonnet-5-5": [2, 2.5, 4, 0.10, 10],
    "haiku-5-5": [0.10, 0.125, 0.20, 0.01, 0.50],
    "haiku-5-5>100k": [0.50, 0.625, 1, 0.05, 2.50],
    "fable-5": [10, 12.5, 20, 1, 50],
    "mythos-5": [10, 12.5, 20, 1, 50],
    "opus-5": [5, 6.25, 10, 0.50, 25],
    "opus-4-8": [5, 6.25, 10, 0.50, 25],
    "opus-4-7": [5, 6.25, 10, 0.50, 25],
    "opus-4-6": [5, 6.25, 10, 0.50, 25],
    "opus-4-5": [5, 6.25, 10, 0.50, 25],
    "opus-4-1": [15, 18.75, 30, 1.50, 75],
    "opus-4": [15, 18.75, 30, 1.50, 75],
    "sonnet-5": [2, 2.5, 4, 0.20, 10],
    "sonnet-4-6": [3, 3.75, 6, 0.30, 15],
    "sonnet-4-5": [3, 3.75, 6, 0.30, 15],
    "sonnet-4": [3, 3.75, 6, 0.30, 15],
    "haiku-4-5": [1, 1.25, 2, 0.10, 5],
    "3-5-haiku": [0.80, 1, 1.60, 0.08, 4],
}
HAIKU_TIER_LIMIT = 100_000

USAGE_COLS = ["ts", "session_id", "project", "agent", "skill", "model",
              "input", "cache_write_5m", "cache_write_1h", "cache_read",
              "output", "message_id"]
VERDICT_COLS = ["ts", "session_id", "project", "verdict", "message_id"]
VERDICT_RE = re.compile(r"^Verdict:\s*(APPROVED|CHANGES REQUESTED|COMMENT)\b", re.M)
COMMAND_RE = re.compile(r"<command-name>/?([^<\s]+)</command-name>")
PR_RE = re.compile(r"^\[[^\]]+\]\s+(\d{4}-\d{2}-\d{2})\b.*?\bPR:\s*#(\d+)")


# ---------------------------------------------------------------- output

def emit(key, value):
    value = str(value)
    if "\n" in value or "\r" in value:
        fail(2, "internal: newline in value for %s" % key)
    print("%s=%s" % (key, value.replace("\\", "\\\\")))


def fail(code, reason):
    sys.stderr.write(reason.replace("\n", " ") + "\n")
    sys.exit(code)


# ----------------------------------------------------------------- paths

def store_dir():
    if os.environ.get("SQUAD_STATS_DIR"):
        return os.environ["SQUAD_STATS_DIR"]
    vault = os.environ.get("SECOND_BRAIN_PATH") or os.path.expanduser("~/second-brain")
    return os.path.join(vault, "squad-stats")


def vault_dir():
    return os.environ.get("SECOND_BRAIN_PATH") or os.path.expanduser("~/second-brain")


def projects_dir():
    if os.environ.get("CLAUDE_PROJECTS_DIR"):
        return os.environ["CLAUDE_PROJECTS_DIR"]
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(base, "projects")


def ensure_store():
    d = store_dir()
    parent = os.path.dirname(d.rstrip("/")) or "/"
    if not os.path.isdir(parent):
        fail(10, "stats store parent %s not found (vault missing?)" % parent)
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as e:
        fail(20, "cannot create %s: %s" % (d, e))
    return d


def now_utc():
    fixed = os.environ.get("SQUAD_STATS_NOW")
    if fixed:
        return parse_ts(fixed) or dt.datetime.now(dt.timezone.utc)
    return dt.datetime.now(dt.timezone.utc)


def parse_ts(s):
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=dt.timezone.utc)
        return t
    except ValueError:
        return None


# --------------------------------------------------------- project names

def load_project_map():
    """lore-config.json `projects` maps a checkout root to a display name."""
    path = os.path.join(vault_dir(), "lore-config.json")
    try:
        with open(path) as f:
            projects = json.load(f).get("projects") or {}
        return sorted(((k.rstrip("/"), v) for k, v in projects.items()
                       if isinstance(v, str)), key=lambda kv: -len(kv[0]))
    except (OSError, ValueError, AttributeError):
        return []


def project_name(cwd, pmap):
    if not cwd:
        return "unknown"
    cwd = cwd.rstrip("/")
    for root, name in pmap:
        if cwd == root or cwd.startswith(root + "/"):
            return name
    cwd = re.sub(r"/\.claude/worktrees/[^/]+$", "", cwd)
    return os.path.basename(cwd) or "unknown"


# ------------------------------------------------------------- importers

def norm_skill(name):
    name = (name or "").strip().lstrip("/")
    if ":" in name:
        name = name.split(":", 1)[1]
    return name.lower()


def read_jsonl(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict):
                    yield rec
    except OSError:
        return


def content_blocks(msg):
    c = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []


def skill_events(records):
    """(ts, skill) each time the main thread switches skill. A non-squad
    slash command (e.g. /clear) resets the active skill to ''."""
    events = []
    for rec in records:
        ts = rec.get("timestamp") or ""
        msg = rec.get("message") or {}
        if rec.get("type") == "user":
            for b in content_blocks(msg):
                for m in COMMAND_RE.finditer(b.get("text") or ""):
                    s = norm_skill(m.group(1))
                    events.append((ts, s if s in SQUAD_SKILLS else ""))
        elif rec.get("type") == "assistant":
            for b in content_blocks(msg):
                if b.get("type") == "tool_use" and b.get("name") == "Skill":
                    inp = b.get("input") or {}
                    s = norm_skill(inp.get("skill") or inp.get("command") or "")
                    if s in SQUAD_SKILLS:
                        events.append((ts, s))
    events.sort(key=lambda e: e[0])
    return events


def skill_at(events, ts):
    if not events:
        return ""
    keys = [e[0] for e in events]
    i = bisect.bisect_right(keys, ts) - 1
    return events[i][1] if i >= 0 else ""


def usage_rows(records, agent, events, project):
    """One row per API message id; later lines of the same message carry
    the final usage, so the last one wins."""
    by_id = {}
    for rec in records:
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        usage = msg.get("usage")
        model = msg.get("model") or ""
        mid = msg.get("id") or rec.get("requestId") or rec.get("uuid")
        if not isinstance(usage, dict) or not mid or model.startswith("<"):
            continue
        cc = usage.get("cache_creation") or {}
        w1h = int(cc.get("ephemeral_1h_input_tokens") or 0)
        w_total = int(usage.get("cache_creation_input_tokens") or 0)
        ts = rec.get("timestamp") or ""
        row_agent = agent
        if agent == "main" and rec.get("isSidechain"):
            row_agent = "subagent"
        by_id[mid] = {
            "ts": ts,
            "session_id": rec.get("sessionId") or "",
            "project": project,
            "agent": row_agent,
            "skill": skill_at(events, ts),
            "model": model,
            "input": int(usage.get("input_tokens") or 0),
            "cache_write_5m": max(w_total - w1h, 0),
            "cache_write_1h": w1h,
            "cache_read": int(usage.get("cache_read_input_tokens") or 0),
            "output": int(usage.get("output_tokens") or 0),
            "message_id": mid,
        }
    return list(by_id.values())


def verdict_rows(records, session_id, project):
    rows = {}
    for rec in records:
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        for b in content_blocks(msg):
            m = VERDICT_RE.search(b.get("text") or "") if b.get("type") == "text" else None
            if m:
                mid = (msg.get("id") or rec.get("uuid") or "") + ":verdict"
                rows[mid] = {"ts": rec.get("timestamp") or "", "session_id": session_id,
                             "project": project, "verdict": m.group(1), "message_id": mid}
    return list(rows.values())


def import_transcripts(pmap):
    """Yield (usage_rows, verdict_rows) per main transcript plus its subagents."""
    root = projects_dir()
    for main in sorted(glob.glob(os.path.join(root, "*", "*.jsonl"))):
        records = list(read_jsonl(main))
        if not records:
            continue
        session_id = next((r.get("sessionId") for r in records if r.get("sessionId")),
                          os.path.splitext(os.path.basename(main))[0])
        cwd = next((r.get("cwd") for r in records if r.get("cwd")), "")
        project = project_name(cwd, pmap)
        events = skill_events(records)
        usage = usage_rows(records, "main", events, project)
        verdicts = []
        subdir = os.path.join(os.path.splitext(main)[0], "subagents")
        for sub in sorted(glob.glob(os.path.join(subdir, "agent-*.jsonl"))):
            agent = "subagent"
            try:
                with open(sub[:-len(".jsonl")] + ".meta.json") as f:
                    agent = (json.load(f).get("agentType") or "subagent").lower()
            except (OSError, ValueError, AttributeError):
                pass
            agent = norm_skill(agent) or "subagent"
            srecs = list(read_jsonl(sub))
            for r in srecs:
                r.setdefault("sessionId", session_id)
            usage.extend(usage_rows(srecs, agent, events, project))
            if agent == "reven":
                verdicts.extend(verdict_rows(srecs, session_id, project))
        yield main, usage, verdicts


# ------------------------------------------------------------------ store

def read_tsv(path, cols):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                parts = line.rstrip("\n").split("\t")
                if i == 0 and parts == cols:
                    continue
                if len(parts) != len(cols):
                    continue
                rows.append(dict(zip(cols, parts)))
    except FileNotFoundError:
        pass
    except OSError as e:
        fail(20, "cannot read %s: %s" % (path, e))
    return rows


def clean_field(v):
    return str(v).replace("\t", " ").replace("\n", " ").replace("\r", " ")


def append_tsv(path, cols, rows):
    if not rows:
        return
    new = not os.path.exists(path)
    try:
        with open(path, "a", encoding="utf-8") as f:
            if new:
                f.write("\t".join(cols) + "\n")
            for r in rows:
                f.write("\t".join(clean_field(r[c]) for c in cols) + "\n")
    except OSError as e:
        fail(20, "cannot write %s: %s" % (path, e))


def cmd_collect(args):
    if args:
        fail(2, "collect takes no arguments")
    d = ensure_store()
    upath = os.path.join(d, "usage.tsv")
    vpath = os.path.join(d, "verdicts.tsv")
    seen_u = {r["message_id"] for r in read_tsv(upath, USAGE_COLS)}
    seen_v = {r["message_id"] for r in read_tsv(vpath, VERDICT_COLS)}
    new_u, new_v, files, oldest = [], [], 0, None
    for path, usage, verdicts in import_transcripts(load_project_map()):
        files += 1
        try:
            m = dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc)
            oldest = m if oldest is None or m < oldest else oldest
        except OSError:
            pass
        for r in usage:
            if r["message_id"] not in seen_u:
                seen_u.add(r["message_id"])
                new_u.append(r)
        for r in verdicts:
            if r["message_id"] not in seen_v:
                seen_v.add(r["message_id"])
                new_v.append(r)
    new_u.sort(key=lambda r: r["ts"])
    new_v.sort(key=lambda r: r["ts"])
    append_tsv(upath, USAGE_COLS, new_u)
    append_tsv(vpath, VERDICT_COLS, new_v)
    changed = bool(new_u or new_v)
    emit("OUTCOME", "applied" if changed else "unchanged")
    emit("CHANGED", "yes" if changed else "no")
    emit("ROWS_ADDED", len(new_u))
    emit("VERDICTS_ADDED", len(new_v))
    emit("FILES_SCANNED", files)
    emit("OLDEST_TRANSCRIPT", oldest.strftime("%Y-%m-%d") if oldest else "")
    emit("STORE", d)


# ----------------------------------------------------------------- report

def load_prices(d):
    prices = dict(DEFAULT_PRICES)
    try:
        with open(os.path.join(d, "prices.json")) as f:
            override = json.load(f)
        for k, v in override.items():
            if isinstance(v, list) and len(v) == 5:
                prices[k] = [float(x) for x in v]
    except FileNotFoundError:
        pass
    except (OSError, ValueError, TypeError) as e:
        sys.stderr.write("squad-stats: prices.json ignored: %s\n" % e)
    return prices


def model_key(model):
    m = re.sub(r"\[.*\]$", "", model or "")
    m = re.sub(r"^claude-", "", m)
    return re.sub(r"-\d{8}$", "", m)


def row_cost(r, prices):
    """USD for one row, or None when the model has no price."""
    key = model_key(r["model"])
    if key == "haiku-5-5":
        prompt = r["input"] + r["cache_write_5m"] + r["cache_write_1h"] + r["cache_read"]
        if prompt > HAIKU_TIER_LIMIT:
            key = "haiku-5-5>100k"
    p = prices.get(key)
    if p is None:
        return None
    return (r["input"] * p[0] + r["cache_write_5m"] * p[1] + r["cache_write_1h"] * p[2]
            + r["cache_read"] * p[3] + r["output"] * p[4]) / 1_000_000


def to_int_row(r):
    out = dict(r)
    for c in ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output"):
        try:
            out[c] = int(r[c])
        except (ValueError, KeyError):
            out[c] = 0
    out["_t"] = parse_ts(r.get("ts"))
    return out


def money(x):
    return "$%.2f" % x


def pct(a, b):
    return "%.0f%%" % (100.0 * a / b) if b else "n/a"


def group(rows, key):
    g = {}
    for r in rows:
        k = key(r) or "(none)"
        e = g.setdefault(k, {"cost": 0.0, "calls": 0, "sessions": set(), "out": 0})
        e["cost"] += r["_cost"] or 0.0
        e["calls"] += 1
        e["sessions"].add(r["session_id"])
        e["out"] += r["output"]
    return sorted(g.items(), key=lambda kv: -kv[1]["cost"])


def table(title, groups, total, label):
    lines = ["## %s" % title, "",
             "| %s | Sessions | API calls | Output tokens | Cost | Share | Cost/session |" % label,
             "|---|---:|---:|---:|---:|---:|---:|"]
    for k, e in groups:
        n = len(e["sessions"])
        lines.append("| %s | %d | %d | %d | %s | %s | %s |" % (
            k, n, e["calls"], e["out"], money(e["cost"]), pct(e["cost"], total),
            money(e["cost"] / n) if n else "n/a"))
    return lines + [""]


def gh_json(args):
    try:
        out = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(str(e))
    if out.returncode != 0:
        lines = (out.stderr or "").strip().splitlines()
        raise RuntimeError(lines[-1] if lines else "gh exited %d" % out.returncode)
    return json.loads(out.stdout or "null")


def resolve_paths():
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        out = subprocess.run(["bash", os.path.join(here, "path-resolve.sh")],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    res = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            res[k] = v
    return res


def pr_outcomes(since, paths):
    """Outcomes of the PRs Ralph and Sidecar recorded in progress.txt."""
    if paths.get("TRACKER_MODE") != "connected":
        return "skipped-detached", None
    name = paths.get("DISPLAY_NAME") or os.path.basename(paths.get("PROJECT_ROOT") or "")
    progress = os.path.join(paths.get("VAULT_PATH") or "", "projects", name, ".squad", "progress.txt")
    prs = {}
    try:
        with open(progress, encoding="utf-8") as f:
            for line in f:
                m = PR_RE.search(line)
                if m and m.group(1) >= since.strftime("%Y-%m-%d"):
                    prs[int(m.group(2))] = m.group(1)
    except OSError:
        return "skipped-no-progress", None
    if not prs:
        return "skipped-no-prs", None
    results = []
    try:
        for n in sorted(prs):
            d = gh_json(["pr", "view", str(n), "--json", "number,state,createdAt,mergedAt,commits"])
            created = parse_ts(d.get("createdAt"))
            merged = parse_ts(d.get("mergedAt"))
            later = sum(1 for c in d.get("commits") or []
                        if created and (parse_ts(c.get("committedDate")) or created) > created)
            results.append({"number": n, "state": d.get("state"), "created": created,
                            "merged": merged, "followups": later})
    except (RuntimeError, ValueError) as e:
        sys.stderr.write("squad-stats: GitHub section skipped: %s\n" % e)
        return "gh-error", None
    return "github", {"project": name, "prs": results}


def cmd_report(args):
    days = 30
    while args:
        if args[0] == "--days" and len(args) > 1 and args[1].isdigit() and int(args[1]) > 0:
            days = int(args[1])
            args = args[2:]
        else:
            fail(2, "report: usage: report [--days N]")
    d = ensure_store()
    now = now_utc()
    since = now - dt.timedelta(days=days)
    prices = load_prices(d)

    rows = [to_int_row(r) for r in read_tsv(os.path.join(d, "usage.tsv"), USAGE_COLS)]
    rows = [r for r in rows if r["_t"] and since <= r["_t"] <= now]
    unpriced = set()
    for r in rows:
        r["_cost"] = row_cost(r, prices)
        if r["_cost"] is None:
            unpriced.add(r["model"])
        r["_squad"] = bool(r["skill"]) or r["agent"] in SQUAD_AGENTS
    verdicts = [v for v in read_tsv(os.path.join(d, "verdicts.tsv"), VERDICT_COLS)
                if parse_ts(v["ts"]) and since <= parse_ts(v["ts"]) <= now]

    total = sum(r["_cost"] or 0 for r in rows)
    sessions = {r["session_id"] for r in rows}
    squad_sessions = {r["session_id"] for r in rows if r["_squad"]}
    squad_cost = sum(r["_cost"] or 0 for r in rows if r["_squad"])
    prompt_tok = sum(r["input"] + r["cache_write_5m"] + r["cache_write_1h"] + r["cache_read"] for r in rows)
    read_tok = sum(r["cache_read"] for r in rows)
    squad_rows = [r for r in rows if r["_squad"]]
    by_skill = group(squad_rows, lambda r: r["skill"])

    quality, gh = pr_outcomes(since, resolve_paths())

    L = ["# Squad stats: last %d days" % days, "",
         "Window: %s to %s (UTC). Generated by `squad-stats.py report`." % (
             since.strftime("%Y-%m-%d"), now.strftime("%Y-%m-%d")), "",
         "> Cost is the API list-price equivalent. On a subscription it is a unit "
         "for comparing skills and agents, not what you pay.", "",
         "## Totals", "",
         "| Metric | Value |", "|---|---:|",
         "| Sessions | %d |" % len(sessions),
         "| Squad sessions | %d (%s) |" % (len(squad_sessions), pct(len(squad_sessions), len(sessions))),
         "| API calls | %d |" % len(rows),
         "| Cost, all Claude Code | %s |" % money(total),
         "| Cost, squad | %s (%s) |" % (money(squad_cost), pct(squad_cost, total)),
         "| Cache hit ratio (cache reads / prompt tokens) | %s |" % pct(read_tok, prompt_tok),
         ""]
    if unpriced:
        L += ["Unpriced models (tokens counted, cost missing; add them to "
              "`prices.json`): %s" % ", ".join(sorted(unpriced)), ""]
    L += table("Squad cost by skill", by_skill, squad_cost, "Skill")
    L += table("Cost by agent", group(rows, lambda r: r["agent"]), total, "Agent")
    L += table("Cost by project", group(rows, lambda r: r["project"]), total, "Project")
    L += table("Cost by model", group(rows, lambda r: r["model"]), total, "Model")

    daily = {}
    for r in rows:
        k = r["_t"].strftime("%Y-%m-%d")
        e = daily.setdefault(k, [set(), 0.0, 0.0])
        e[0].add(r["session_id"])
        e[1] += r["_cost"] or 0
        e[2] += (r["_cost"] or 0) if r["_squad"] else 0
    L += ["## Daily", "", "| Day | Sessions | Cost | Squad cost |", "|---|---:|---:|---:|"]
    L += ["| %s | %d | %s | %s |" % (k, len(v[0]), money(v[1]), money(v[2]))
          for k, v in sorted(daily.items())]
    L.append("")

    counts = {}
    for v in verdicts:
        counts[v["verdict"]] = counts.get(v["verdict"], 0) + 1
    nv = len(verdicts)
    L += ["## Reven verdicts", ""]
    if nv:
        L += ["| Verdict | Count | Share |", "|---|---:|---:|"]
        L += ["| %s | %d | %s |" % (k, c, pct(c, nv)) for k, c in sorted(counts.items())]
    else:
        L.append("No Reven verdicts in the window.")
    L.append("")

    merged_n = total_prs = 0
    L += ["## PR outcomes (GitHub)", ""]
    if gh:
        prs = gh["prs"]
        total_prs = len(prs)
        merged = [p for p in prs if p["merged"]]
        merged_n = len(merged)
        closed = [p for p in prs if p["state"] == "CLOSED"]
        hours = [(p["merged"] - p["created"]).total_seconds() / 3600 for p in merged if p["created"]]
        rework = [p for p in prs if p["followups"] > 0]
        pcost = sum(r["_cost"] or 0 for r in squad_rows if r["project"] == gh["project"])
        L += ["Project `%s`, PRs recorded in progress.txt within the window." % gh["project"], "",
              "| Metric | Value |", "|---|---:|",
              "| PRs | %d |" % total_prs,
              "| Merged | %d (%s) |" % (merged_n, pct(merged_n, total_prs)),
              "| Closed without merge | %d |" % len(closed),
              "| Open | %d |" % (total_prs - merged_n - len(closed)),
              "| PRs with commits after opening (rework proxy) | %d (%s) |" % (len(rework), pct(len(rework), total_prs)),
              "| Median hours to merge | %s |" % ("%.1f" % statistics.median(hours) if hours else "n/a"),
              "| Squad cost per merged PR (project) | %s |" % (money(pcost / merged_n) if merged_n else "n/a"),
              ""]
    else:
        reason = {"skipped-detached": "detached mode: no GitHub calls.",
                  "skipped-no-progress": "no progress.txt for this project.",
                  "skipped-no-prs": "no PRs recorded in progress.txt within the window.",
                  "gh-error": "gh failed; see stderr."}.get(quality, quality)
        L += ["Skipped: %s" % reason, ""]

    L += ["## Questions", "",
          "Write down the questions you ask while reading this in `../questions.md` (the stats folder) "
          "next to this folder. The ones that keep coming back become the KPIs.", ""]

    rdir = os.path.join(d, "reports")
    rpath = os.path.join(rdir, "report-%s.md" % now.strftime("%Y-%m-%d"))
    try:
        os.makedirs(rdir, exist_ok=True)
        with open(rpath, "w", encoding="utf-8") as f:
            f.write("\n".join(L))
    except OSError as e:
        fail(20, "cannot write %s: %s" % (rpath, e))

    emit("OUTCOME", "applied")
    emit("CHANGED", "yes")
    emit("REPORT", rpath)
    emit("DAYS", days)
    emit("SESSIONS", len(sessions))
    emit("SQUAD_SESSIONS", len(squad_sessions))
    emit("COST_USD", "%.2f" % total)
    emit("SQUAD_COST_USD", "%.2f" % squad_cost)
    emit("CACHE_HIT_PCT", "%.0f" % (100.0 * read_tok / prompt_tok) if prompt_tok else "")
    emit("TOP_SKILL", by_skill[0][0] if by_skill else "")
    emit("VERDICTS", nv)
    emit("QUALITY", quality)
    emit("PRS_TOTAL", total_prs)
    emit("PRS_MERGED", merged_n)
    emit("UNPRICED_MODELS", ",".join(sorted(unpriced)))


def main(argv):
    if not argv:
        fail(2, "usage: squad-stats.py collect | report [--days N]")
    verb, args = argv[0], argv[1:]
    if verb == "collect":
        cmd_collect(args)
    elif verb == "report":
        cmd_report(args)
    else:
        fail(2, "unknown verb: %s" % verb)


if __name__ == "__main__":
    main(sys.argv[1:])
