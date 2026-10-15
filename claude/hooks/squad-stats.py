#!/usr/bin/env python3
"""squad-stats.py -- usage, cost and outcome stats for the squad.

Verbs (stdout follows SCRIPT_CONTRACT.md: KEY=value lines only):

  collect             Import Claude Code transcripts into the stats store.
  report [--days N]   Aggregate the store (plus GitHub PR outcomes in
                      connected mode) into a Markdown report and an HTML
                      view of it with charts (self-contained, offline).

Every Claude Code session is recorded, squad or not. Each row carries
the active skill (any skill or slash command; prompt built-ins as
"builtin:<name>") and the agent type, and the report classifies each
session as squad, custom (another skill, command or agent) or vanilla
(built-in Claude Code only). A slash command stays active until the
next one or a resetting built-in such as /clear; a skill the model loads
lasts until the user's next message. Both are approximations: the
transcript does not mark where a skill's work ends.

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
import math
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
SQUAD_PLUGIN = "agent-squad"

# Built-in slash commands. RESET ones spend no tokens and end the active
# skill; PROMPT ones run a model turn and are recorded as "builtin:<name>".
# A built-in missing here shows up as a custom skill: add it.
BUILTIN_RESET = {
    "add-dir", "agents", "btw", "bug", "clear", "config", "context", "cost",
    "doctor", "effort", "exit", "export", "fast", "feedback", "help", "hooks",
    "ide", "install-github-app", "login", "logout", "mcp", "memory",
    "migrate-installer", "model", "output-style", "permissions", "plugin",
    "plugins", "privacy-settings", "quit", "release-notes", "resume", "rewind",
    "sandbox", "skills", "status", "statusline", "tasks", "terminal-setup",
    "theme", "todos", "upgrade", "usage", "vim",
}
BUILTIN_PROMPT = {"compact", "init", "pr-comments", "review", "security-review"}
# Built-in subagent types: part of vanilla Claude Code, not customizations.
BUILTIN_AGENTS = {"main", "subagent", "general-purpose", "explore", "plan",
                  "statusline-setup", "output-style-setup", "claude-code-guide"}

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
              "output", "message_id", "tools", "tool_errors", "cc_version"]
VERDICT_COLS = ["ts", "session_id", "project", "verdict", "message_id"]
HOOK_COLS = ["ts", "session_id", "project", "event", "hook", "outcome",
             "duration_ms", "chars", "hook_id"]
# store file -> (columns, dedupe key)
TABLES = {
    "usage": (USAGE_COLS, "message_id"),
    "verdicts": (VERDICT_COLS, "message_id"),
    "hooks": (HOOK_COLS, "hook_id"),
}
VERDICT_RE = re.compile(r"^Verdict:\s*(APPROVED|CHANGES REQUESTED|COMMENT)\b", re.M)
COMMAND_RE = re.compile(r"<command-name>/?([^<\s]+)</command-name>")
# Failed tool calls, by who stopped them: hook, classifier (auto mode),
# policy (a permission rule or mode), user, or the tool itself (error).
# Claude Code records the decision on the tool_result line as
# permissionDecision {decision, source, reasonType}; that is the source of
# truth. Text matching is only a fallback for transcripts without it.
ERROR_KINDS = ["hook", "classifier", "policy", "user", "error"]
TEXT_FALLBACK = [
    ("classifier", re.compile(r"denied by the Claude Code auto mode classifier|^Classifier '[^']+' requires approval")),
    ("user", re.compile(r"^The user doesn't want to proceed")),
    ("hook", re.compile(r"Hook (PreToolUse|PermissionRequest)\S* (denied|blocked|asked)"
                        r"|\b(PreToolUse|PermissionRequest)(:\S+)? hook (blocking )?error"
                        r"|Hook '[^']+' (blocked this action|requires approval)")),
]


def decision_kind(pd):
    """Kind for a rejected permissionDecision, None when not a rejection."""
    if not isinstance(pd, dict) or pd.get("decision") != "reject":
        return None
    reason = str(pd.get("reasonType") or "")
    source = str(pd.get("source") or "")
    if reason == "hook" or source == "hook":
        return "hook"
    if "classifier" in reason or "classifier" in source:
        return "classifier"
    if source.startswith("user"):
        return "user"
    return "policy"


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

def norm_name(name):
    """Lowercase, no leading slash. The squad's own plugin prefix is dropped
    (a copy install has none); any other plugin prefix is kept, so two
    plugins' skills with the same name stay apart."""
    name = (name or "").strip().lstrip("/").lower()
    if name.startswith(SQUAD_PLUGIN + ":"):
        name = name[len(SQUAD_PLUGIN) + 1:]
    return name


def command_skill(name):
    """Active-skill value after a slash command."""
    name = norm_name(name)
    if name in BUILTIN_RESET:
        return ""
    if name in BUILTIN_PROMPT:
        return "builtin:" + name
    return name


def is_squad(row):
    return row["skill"] in SQUAD_SKILLS or row["agent"] in SQUAD_AGENTS


def is_custom(row):
    """A skill, command or agent that is not built into Claude Code."""
    skill = row["skill"]
    return bool(skill and not skill.startswith("builtin:")) or row["agent"] not in BUILTIN_AGENTS


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


def is_human_turn(rec):
    """A message the user typed: not injected (isMeta), not a tool result."""
    if rec.get("type") != "user" or rec.get("isMeta"):
        return False
    blocks = content_blocks(rec.get("message") or {})
    return (any(b.get("type") == "text" for b in blocks)
            and not any(b.get("type") == "tool_result" for b in blocks))


def skill_events(records):
    """(ts, skill) each time the active skill of the main thread changes.

    Two scopes. A slash command the user types stays active until the next
    command or a resetting built-in such as /clear. A skill the model loads
    through the Skill tool lasts only until the user's next message, then
    the slash-command skill (if any) is active again: a reference skill
    loaded once must not absorb the rest of the session."""
    events, command, loaded = [], "", ""
    for rec in records:
        ts = rec.get("timestamp") or ""
        msg = rec.get("message") or {}
        if is_human_turn(rec):
            names = [m.group(1) for b in content_blocks(msg)
                     for m in COMMAND_RE.finditer(b.get("text") or "")]
            if names:
                command = command_skill(names[-1])
            if names or loaded:
                loaded = ""
                events.append((ts, command))
        elif rec.get("type") == "assistant":
            for b in content_blocks(msg):
                if b.get("type") == "tool_use" and b.get("name") == "Skill":
                    inp = b.get("input") or {}
                    name = norm_name(inp.get("skill") or inp.get("command") or "")
                    if name:
                        loaded = name
                        events.append((ts, name))
    events.sort(key=lambda e: e[0])
    return events


def skill_at(events, ts):
    if not events:
        return ""
    keys = [e[0] for e in events]
    i = bisect.bisect_right(keys, ts) - 1
    return events[i][1] if i >= 0 else ""


def result_text(block):
    c = block.get("content")
    if isinstance(c, list):
        return " ".join(x.get("text") or "" for x in c if isinstance(x, dict))
    return str(c or "")


def error_kind(block, pd=None):
    kind = decision_kind(pd)
    if kind:
        return kind
    text = result_text(block)
    for k, rx in TEXT_FALLBACK:
        if rx.search(text):
            return k
    return "error"


def usage_rows(records, agent, events, project):
    """One row per API message id. A message can span several lines (one
    per content block): usage comes from the last line, tool calls from
    all of them. Tool errors are joined back from the tool_result that
    answers each call: "<kind>:<tool>", kind in ERROR_KINDS."""
    errors = {}
    for rec in records:
        if rec.get("type") == "user":
            pd = rec.get("permissionDecision")
            for blk in content_blocks(rec.get("message") or {}):
                if blk.get("type") != "tool_result":
                    continue
                if blk.get("is_error") or decision_kind(pd):
                    errors[blk.get("tool_use_id")] = error_kind(blk, pd)
    by_id, tools = {}, {}
    for rec in records:
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        usage = msg.get("usage")
        model = msg.get("model") or ""
        mid = msg.get("id") or rec.get("requestId") or rec.get("uuid")
        if not mid or model.startswith("<"):
            continue
        for blk in content_blocks(msg):
            if blk.get("type") == "tool_use" and blk.get("name"):
                tools.setdefault(mid, []).append((blk.get("id"), blk["name"]))
        if not isinstance(usage, dict):
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
            "cc_version": rec.get("version") or "",
        }
    for mid, row in by_id.items():
        calls = tools.get(mid, [])
        row["tools"] = ",".join(name for _, name in calls)
        row["tool_errors"] = ",".join("%s:%s" % (errors[i], name) for i, name in calls if i in errors)
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


def hook_name(command):
    """A readable id for a hook command: its executable's basename plus a
    subcommand when the executable is a dispatcher (`tokensave hook-stop`)."""
    parts = str(command or "").split()
    if not parts:
        return "unknown"
    base = os.path.basename(parts[0])
    if len(parts) > 1 and not parts[1].startswith("-") and "/" not in parts[1]:
        return "%s %s" % (base, parts[1])
    return base


HOOK_ATTACHMENT_OUTCOME = {"success": "ok", "non_blocking_error": "error",
                           "blocking_error": "blocking", "additional_context": "context",
                           "cancelled": "error", "error_during_execution": "error"}


def hook_rows(records, session_id, project):
    """Hook executions, from two record shapes: `system` summaries
    (`<event>_hook_summary`, with commands, durations and errors) and
    `attachment` records whose type starts with `hook_`. Field names are
    read defensively: Claude Code has changed them between versions."""
    rows = []
    for rec in records:
        ts = rec.get("timestamp") or ""
        uid = rec.get("uuid") or ""
        if rec.get("type") == "system" and str(rec.get("subtype") or "").endswith("_hook_summary"):
            event = rec["subtype"][:-len("_hook_summary")]
            errors = rec.get("hookErrors") or []
            blocked = bool(rec.get("preventedContinuation"))
            ctx = rec.get("hookAdditionalContext")
            for i, info in enumerate(rec.get("hookInfos") or []):
                info = info if isinstance(info, dict) else {"command": info}
                rows.append({
                    "ts": ts, "session_id": rec.get("sessionId") or session_id, "project": project,
                    "event": event, "hook": hook_name(info.get("command")),
                    "outcome": "blocking" if blocked else ("error" if errors else "ok"),
                    "duration_ms": int(info.get("durationMs") or 0),
                    "chars": len(json.dumps(ctx)) if ctx else 0,
                    "hook_id": "%s:%d" % (uid, i),
                })
        elif rec.get("type") == "attachment":
            a = rec.get("attachment") or {}
            atype = str(a.get("type") or "")
            if not atype.startswith("hook_"):
                continue
            content = a.get("content") or a.get("stdout") or a.get("blockingError") or ""
            rows.append({
                "ts": ts, "session_id": rec.get("sessionId") or session_id, "project": project,
                "event": str(a.get("hookEvent") or a.get("hookName") or "unknown").split(":")[0],
                "hook": hook_name(a.get("command") or a.get("hookName")),
                "outcome": HOOK_ATTACHMENT_OUTCOME.get(atype[len("hook_"):], atype[len("hook_"):]),
                "duration_ms": int(a.get("durationMs") or 0),
                "chars": len(content if isinstance(content, str) else json.dumps(content)),
                "hook_id": uid or "%s:%s" % (ts, atype),
            })
    return rows


def import_transcripts(pmap):
    """Yield (path, {table: rows}) per main transcript plus its subagents."""
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
        hooks = hook_rows(records, session_id, project)
        verdicts = []
        subdir = os.path.join(os.path.splitext(main)[0], "subagents")
        for sub in sorted(glob.glob(os.path.join(subdir, "agent-*.jsonl"))):
            agent = "subagent"
            try:
                with open(sub[:-len(".jsonl")] + ".meta.json") as f:
                    agent = (json.load(f).get("agentType") or "subagent").lower()
            except (OSError, ValueError, AttributeError):
                pass
            agent = norm_name(agent) or "subagent"
            srecs = list(read_jsonl(sub))
            for r in srecs:
                r.setdefault("sessionId", session_id)
            usage.extend(usage_rows(srecs, agent, events, project))
            hooks.extend(hook_rows(srecs, session_id, project))
            if agent == "reven":
                verdicts.extend(verdict_rows(srecs, session_id, project))
        yield main, {"usage": usage, "verdicts": verdicts, "hooks": hooks}


# ------------------------------------------------------------------ store

def read_tsv(path, cols):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                parts = line.rstrip("\n").split("\t")
                if i == 0 and parts == cols:
                    continue
                if len(parts) < len(cols) and len(parts) >= 12:
                    parts += [""] * (len(cols) - len(parts))
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
    seen = {t: {r[key] for r in read_tsv(os.path.join(d, t + ".tsv"), cols)}
            for t, (cols, key) in TABLES.items()}
    new = {t: [] for t in TABLES}
    pending = {t: {} for t in TABLES}
    files, oldest = 0, None
    for path, tables in import_transcripts(load_project_map()):
        files += 1
        try:
            m = dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc)
            oldest = m if oldest is None or m < oldest else oldest
        except OSError:
            pass
        for t, rows in tables.items():
            key = TABLES[t][1]
            for r in rows:
                if not r[key]:
                    continue
                if r[key] not in seen[t]:
                    seen[t].add(r[key])
                    pending[t][r[key]] = r
                    new[t].append(r)
                elif r[key] in pending[t]:
                    # The same message can appear in two transcripts (a
                    # session resumed in another directory copies its
                    # history, without some fields): fill the blanks.
                    kept = pending[t][r[key]]
                    for c, v in r.items():
                        if v not in ("", None) and kept.get(c) in ("", None):
                            kept[c] = v
    for t, (cols, _) in TABLES.items():
        new[t].sort(key=lambda r: r["ts"])
        append_tsv(os.path.join(d, t + ".tsv"), cols, new[t])
    changed = any(new.values())
    emit("OUTCOME", "applied" if changed else "unchanged")
    emit("CHANGED", "yes" if changed else "no")
    emit("ROWS_ADDED", len(new["usage"]))
    emit("VERDICTS_ADDED", len(new["verdicts"]))
    emit("HOOK_RUNS_ADDED", len(new["hooks"]))
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


def table(title, groups, total, label, flag=None):
    """flag(key) -> bool adds a Squad column."""
    sq = " Squad |" if flag else ""
    lines = ["## %s" % title, "",
             "| %s |%s Sessions | API calls | Output tokens | Cost | Share | Cost/session |" % (label, sq),
             "|---|" + ("---|" if flag else "") + "---:|---:|---:|---:|---:|---:|"]
    for k, e in groups:
        n = len(e["sessions"])
        cell = (" %s |" % ("yes" if flag(k) else "no")) if flag else ""
        lines.append("| %s |%s %d | %s | %s | %s | %s | %s |" % (
            k, cell, n, "{:,}".format(e["calls"]), "{:,}".format(e["out"]), money(e["cost"]), pct(e["cost"], total),
            money(e["cost"] / n) if n else "n/a"))
    return lines + [""]


KIND_ORDER = ["squad", "custom", "vanilla"]


def prompt_tokens(rows):
    return sum(r["input"] + r["cache_write_5m"] + r["cache_write_1h"] + r["cache_read"] for r in rows)


def cache_read(rows):
    return sum(r["cache_read"] for r in rows)


def normalized_table(label, groups, total):
    """Per-session cost and tokens plus cache hit ratio, one line per group."""
    lines = ["| %s | Sessions | Cost | Share | Cost/session | Tokens/session | Cache hit |" % label,
             "|---|---:|---:|---:|---:|---:|---:|"]
    for k, rs in groups:
        n = len({r["session_id"] for r in rs})
        cost = sum(r["_cost"] or 0 for r in rs)
        tok = prompt_tokens(rs) + sum(r["output"] for r in rs)
        lines.append("| %s | %d | %s | %s | %s | %s | %s |" % (
            k, n, money(cost), pct(cost, total), money(cost / n) if n else "n/a",
            "{:,}".format(int(tok / n)) if n else "n/a", pct(cache_read(rs), prompt_tokens(rs))))
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
                            "merged": merged, "followups": later, "date": prs[n]})
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

    # Everything is classified over the whole store, then cut to the
    # window: the trend section compares against the weeks before it.
    all_rows = [to_int_row(r) for r in read_tsv(os.path.join(d, "usage.tsv"), USAGE_COLS)]
    all_rows = [r for r in all_rows if r["_t"] and r["_t"] <= now]
    for r in all_rows:
        r["_cost"] = row_cost(r, prices)
        r["_squad"] = is_squad(r)
    # Session kind, decided over the whole session: squad beats custom
    # beats vanilla (nothing but built-in Claude Code).
    kind = {}
    for r in all_rows:
        k = "squad" if r["_squad"] else ("custom" if is_custom(r) else "vanilla")
        prev = kind.get(r["session_id"], "vanilla")
        kind[r["session_id"]] = min(prev, k, key=KIND_ORDER.index)
    for r in all_rows:
        r["_kind"] = kind[r["session_id"]]
    rows = [r for r in all_rows if since <= r["_t"]]
    unpriced = {r["model"] for r in rows if r["_cost"] is None}
    all_verdicts = [v for v in read_tsv(os.path.join(d, "verdicts.tsv"), VERDICT_COLS)
                    if parse_ts(v["ts"]) and parse_ts(v["ts"]) <= now]
    for v in all_verdicts:
        v["_t"] = parse_ts(v["ts"])
    verdicts = [v for v in all_verdicts if since <= v["_t"]]
    hook_runs = [h for h in read_tsv(os.path.join(d, "hooks.tsv"), HOOK_COLS)
                 if parse_ts(h["ts"]) and since <= parse_ts(h["ts"]) <= now]

    total = sum(r["_cost"] or 0 for r in rows)
    sessions = {r["session_id"] for r in rows}
    squad_cost = sum(r["_cost"] or 0 for r in rows if r["_squad"])
    squad_rows = [r for r in rows if r["_squad"]]
    by_skill = group(rows, lambda r: r["skill"] or "(no skill)")
    named = [kv for kv in by_skill if kv[0] != "(no skill)"]

    horizon = now - dt.timedelta(days=max(days, 2 * TREND_DAYS))
    quality, gh = pr_outcomes(horizon, resolve_paths())
    all_prs = gh["prs"] if gh else []

    L = ["# Claude Code stats: last %d days" % days, "",
         "Window: %s to %s (UTC). Generated by `squad-stats.py report`." % (
             since.strftime("%Y-%m-%d"), now.strftime("%Y-%m-%d")), "",
         "> Cost is the API list-price equivalent. On a subscription it is a unit "
         "for comparing sessions, skills and agents, not what you pay.", "",
         "## Totals", "",
         "| Metric | Value |", "|---|---:|",
         "| Sessions | %d |" % len(sessions),
         "| API calls | %d |" % len(rows),
         "| Cost | %s |" % money(total),
         "| Squad cost (squad skills and agents only) | %s (%s) |" % (money(squad_cost), pct(squad_cost, total)),
         "| Cache hit ratio (cache reads / prompt tokens) | %s |" % pct(cache_read(rows), prompt_tokens(rows)),
         ""]
    if unpriced:
        L += ["Unpriced models (tokens counted, cost missing; add them to "
              "`prices.json`): %s" % ", ".join(sorted(unpriced)), ""]
    L += ["## Sessions by kind", "",
          "squad: used a squad skill or agent. custom: used another skill, command "
          "or agent. vanilla: built-in Claude Code only.", ""]
    L += normalized_table("Kind", [(k, [r for r in rows if r["_kind"] == k]) for k in KIND_ORDER], total)
    L += table("Cost by skill", by_skill, total, "Skill", flag=lambda k: k in SQUAD_SKILLS)
    L += table("Cost by agent", group(rows, lambda r: r["agent"]), total, "Agent",
               flag=lambda k: k in SQUAD_AGENTS)
    L += table("Cost by project", group(rows, lambda r: r["project"]), total, "Project")
    L += table("Cost by model", group(rows, lambda r: r["model"]), total, "Model")
    tool_lines, tstats = tool_sections(rows)
    L += tool_lines
    L += hook_section(hook_runs)
    L += ["## By Claude Code version", "",
          "An update of Claude Code can move cost more than any change of yours.", ""]
    L += normalized_table("Version", sorted(
        group_rows(rows, lambda r: r["cc_version"] or "(unknown)").items(),
        key=lambda kv: version_key(kv[0])), total)

    weeks = {}
    for r in rows:
        y, w, _ = r["_t"].isocalendar()
        weeks.setdefault("%d-W%02d" % (y, w), []).append(r)
    L += ["## Weekly trend", "",
          "Per-session figures, so a change such as a token-saving tool shows up "
          "even when the number of sessions moves. Compare like with like: a week "
          "of heavy /ralph runs is not a week of small fixes.", ""]
    L += normalized_table("Week", sorted(weeks.items()), total)
    L += ["## Daily", "", "| Day | Sessions | Cost | Squad | Custom | Vanilla |",
          "|---|---:|---:|---:|---:|---:|"]
    days_map = {}
    for r in rows:
        days_map.setdefault(r["_t"].strftime("%Y-%m-%d"), []).append(r)
    for k, rs in sorted(days_map.items()):
        by = {kk: sum(r["_cost"] or 0 for r in rs if r["_kind"] == kk) for kk in KIND_ORDER}
        L.append("| %s | %d | %s | %s | %s | %s |" % (
            k, len({r["session_id"] for r in rs}), money(sum(r["_cost"] or 0 for r in rs)),
            money(by["squad"]), money(by["custom"]), money(by["vanilla"])))
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
        prs = [p for p in all_prs if p["date"] >= since.strftime("%Y-%m-%d")]
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

    trend_lines, trend = trend_section(all_rows, all_verdicts, all_prs,
                                       gh["project"] if gh else None, now)
    L += trend_lines

    L += ["## Questions", "",
          "Write down the questions you ask while reading this in `questions.md`, "
          "one level up from this report. The ones that keep coming back become the KPIs.", ""]

    rdir = os.path.join(d, "reports")
    rpath = os.path.join(rdir, "report-%s.md" % now.strftime("%Y-%m-%d"))
    try:
        os.makedirs(rdir, exist_ok=True)
        with open(rpath, "w", encoding="utf-8") as f:
            f.write("\n".join(L))
    except OSError as e:
        fail(20, "cannot write %s: %s" % (rpath, e))

    pt = prompt_tokens(rows)
    ctx = {
        "total": total, "days": days, "sessions": len(sessions),
        "kinds": tuple(sum(1 for sid in sessions if kind[sid] == k) for k in KIND_ORDER),
        "cache": pct(cache_read(rows), pt),
        "prs": "%d/%d" % (merged_n, total_prs) if gh else "n/a",
        "prs_note": "project %s" % gh["project"] if gh else "connected mode only",
        "window": "Last %d days, %s to %s (UTC). Cost is the API list-price equivalent." % (
            days, since.strftime("%Y-%m-%d"), now.strftime("%Y-%m-%d")),
        "days_map": days_map, "weeks": weeks, "by_skill": by_skill,
    }
    hpath = rpath[:-3] + ".html"
    try:
        with open(hpath, "w", encoding="utf-8") as f:
            f.write(render_html(L, ctx))
    except OSError as e:
        fail(20, "cannot write %s: %s" % (hpath, e))

    emit("OUTCOME", "applied")
    emit("CHANGED", "yes")
    emit("REPORT", rpath)
    emit("HTML", hpath)
    emit("DAYS", days)
    emit("SESSIONS", len(sessions))
    for k in KIND_ORDER:
        emit("%s_SESSIONS" % k.upper(), sum(1 for sid in sessions if kind[sid] == k))
        emit("%s_COST_USD" % k.upper(), "%.2f" % sum(r["_cost"] or 0 for r in rows if r["_kind"] == k))
    emit("COST_USD", "%.2f" % total)
    emit("CACHE_HIT_PCT", "%.0f" % (100.0 * cache_read(rows) / pt) if pt else "")
    emit("TOP_SKILL", named[0][0] if named else "")
    emit("VERDICTS", nv)
    emit("QUALITY", quality)
    emit("PRS_TOTAL", total_prs)
    emit("PRS_MERGED", merged_n)
    emit("UNPRICED_MODELS", ",".join(sorted(unpriced)))
    emit("TOOL_CALLS", tstats["calls"])
    emit("TOOL_FAILED", tstats["failed"])
    emit("HOOK_BLOCKS", tstats["hook"])
    emit("MCP_SERVERS", ",".join(tstats["servers"]))
    emit("HOOK_RUNS", len(hook_runs))
    emit("TREND_COST_PER_SESSION", trend["cost_per_session"])
    emit("TREND_SESSIONS", trend["sessions"])


# ------------------------------------------------------------------- html
# A second view of the same report: the Markdown tables converted to HTML,
# plus three charts drawn as inline SVG. Self-contained (no network), so
# it opens from the vault offline. Palette: the dataviz reference
# categorical slots 1-3, validated light and dark (aqua is under 3:1 on
# the light surface, so every chart has a legend, tooltips and a table).

HTML_CSS = """
:root{color-scheme:light;--page:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;
--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;
--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;
--axis:#383835;--s1:#3987e5;--s2:#d95926;--s3:#199e70}}
:root[data-theme="dark"]{color-scheme:dark;--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;
--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;--s1:#3987e5;--s2:#d95926;--s3:#199e70}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);
font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:1040px;margin:0 auto;padding:32px 16px 64px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:0 0 12px}
.sub,.note{color:var(--ink2);margin:0 0 16px}.note{font-size:13px}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--ink2)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:24px 0}
.tile,.card{background:var(--surface);border:1px solid var(--grid);border-radius:12px;padding:16px}
.tile .k{color:var(--ink2);font-size:12px}.tile .v{font-size:26px;font-weight:600;
font-variant-numeric:tabular-nums;margin-top:4px}.tile .d{color:var(--muted);font-size:12px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}
@media (max-width:760px){.grid2{grid-template-columns:1fr}}
.card{margin-bottom:12px;overflow-x:auto}
svg{display:block;width:100%;height:auto}svg.wide{min-width:640px}svg text{fill:var(--muted);font-size:11px}
svg .lbl{fill:var(--ink2)}svg .val{fill:var(--ink);font-weight:600}
.legend{display:flex;gap:16px;flex-wrap:wrap;color:var(--ink2);font-size:12px;margin:0 0 8px}
.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{padding:6px 10px;border-bottom:1px solid var(--grid);text-align:left;white-space:nowrap}
th{color:var(--ink2);font-weight:500;font-size:12px}td.n,th.n{text-align:right}
.tag{font-size:11px;color:var(--ink2);border:1px solid var(--axis);border-radius:6px;padding:0 5px;margin-left:6px}
#tip{position:fixed;pointer-events:none;background:var(--ink);color:var(--surface);font-size:12px;
padding:6px 8px;border-radius:6px;opacity:0;transition:opacity .1s;max-width:280px;z-index:9}
[data-tip]{cursor:default}
"""

HTML_JS = """
const t=document.getElementById('tip');
document.addEventListener('pointerover',e=>{const el=e.target.closest('[data-tip]');
if(!el){t.style.opacity=0;return}t.textContent=el.dataset.tip;t.style.opacity=1});
document.addEventListener('pointermove',e=>{t.style.left=Math.min(e.clientX+12,innerWidth-290)+'px';
t.style.top=(e.clientY+14)+'px'});
"""


def esc(x):
    return (str(x).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def inline_md(text):
    out = esc(text)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    return re.sub(r"\*([^*]+)\*", r"<em>\1</em>", out)


def md_table(rows):
    head, body = rows[0], rows[2:]
    num = [bool(body) and all(j < len(r) and re.search(r"\d", r[j])
                              and re.match(r"^[\d$.,%()\- ]*$", r[j])
                              and not re.match(r"^\d{4}-\d{2}", r[j]) for r in body)
           for j in range(len(head))]
    th = "".join('<th class="%s">%s</th>' % ("n" if num[j] else "", inline_md(h))
                 for j, h in enumerate(head))
    tr = "".join("<tr>%s</tr>" % "".join(
        '<td class="%s">%s</td>' % ("n" if j < len(num) and num[j] else "", inline_md(c))
        for j, c in enumerate(r)) for r in body)
    return "<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>" % (th, tr)


def md_to_html(lines):
    """The subset of Markdown the report writes, one card per h2 section:
    tables, blockquotes and paragraphs. Numeric columns align right."""
    sections, cur, i = [], None, 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("## "):
            cur = ["<h2>%s</h2>" % inline_md(ln[3:])]
            sections.append(cur)
        elif cur is None:
            pass
        elif ln.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            cur.append(md_table(rows))
            continue
        elif ln.strip():
            cur.append('<p class="note">%s</p>' % inline_md(ln.lstrip("> ")))
        i += 1
    return "".join('<section class="card">%s</section>' % "".join(c) for c in sections)


def nice_max(v):
    if v <= 0:
        return 1.0
    mag = 10 ** math.floor(math.log10(v))
    for m in (1, 2, 2.5, 5, 10):
        if v <= m * mag:
            return m * mag
    return 10 * mag


def fmt_usd(v, top):
    return "$%.0f" % v if top >= 10 else "$%.2f" % v


def y_axis(W, H, P, top):
    out = []
    for k in range(5):
        val = top * k / 4
        y = H - P["b"] - (H - P["t"] - P["b"]) * k / 4
        out.append('<line x1="%d" x2="%d" y1="%.1f" y2="%.1f" stroke="var(%s)" stroke-width="1"/>' % (
            P["l"], W - P["r"], y, y, "--axis" if k == 0 else "--grid"))
        out.append('<text x="%d" y="%.1f" text-anchor="end" dominant-baseline="middle">%s</text>' % (
            P["l"] - 8, y, fmt_usd(val, top)))
    return out


def col_path(x, y, w, h, rounded):
    """Column segment; the top one gets a 4px rounded data-end."""
    if h <= 0:
        return ""
    r = min(4, w / 2, h) if rounded else 0
    return ('M%.1f,%.1f V%.1f Q%.1f,%.1f %.1f,%.1f H%.1f Q%.1f,%.1f %.1f,%.1f V%.1f Z' % (
        x, y + h, y + r, x, y, x + r, y, x + w - r, x + w, y, x + w, y + r, y + h))


def daily_chart(days_map):
    keys = sorted(days_map)
    if not keys:
        return "<p class='note'>No usage in the window.</p>"
    d0 = dt.date.fromisoformat(keys[0])
    d1 = dt.date.fromisoformat(keys[-1])
    span = [(d0 + dt.timedelta(n)).isoformat() for n in range((d1 - d0).days + 1)]
    W, H, P = 960, 240, {"l": 52, "r": 12, "t": 12, "b": 28}
    totals = {k: {kk: sum(r["_cost"] or 0 for r in days_map.get(k, []) if r["_kind"] == kk)
                  for kk in KIND_ORDER} for k in span}
    top = nice_max(max(sum(v.values()) for v in totals.values()))
    band = (W - P["l"] - P["r"]) / len(span)
    bw = min(24, band * 0.6)
    ph = H - P["t"] - P["b"]
    out = y_axis(W, H, P, top)
    every = max(1, len(span) // 8)
    for i, k in enumerate(span):
        x = P["l"] + band * i + (band - bw) / 2
        y = H - P["b"]
        segs = [(kk, totals[k][kk] / top * ph) for kk in KIND_ORDER if totals[k][kk] > 0]
        for j, (kk, h) in enumerate(segs):
            gap = 2 if j < len(segs) - 1 else 0
            out.append('<path d="%s" fill="var(--s%d)"/>' % (
                col_path(x, y - h + gap, bw, h - gap, j == len(segs) - 1), KIND_ORDER.index(kk) + 1))
            y -= h
        tip = "%s: %s (squad %s, custom %s, vanilla %s)" % (
            k, money(sum(totals[k].values())), money(totals[k]["squad"]),
            money(totals[k]["custom"]), money(totals[k]["vanilla"]))
        out.append('<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="transparent" data-tip="%s"/>' % (
            P["l"] + band * i, P["t"], band, ph, esc(tip)))
        if i % every == 0 or i == len(span) - 1:
            out.append('<text x="%.1f" y="%d" text-anchor="middle">%s</text>' % (
                x + bw / 2, H - 8, k[5:]))
    legend = "".join('<span><i style="background:var(--s%d)"></i>%s</span>' % (n + 1, k)
                     for n, k in enumerate(KIND_ORDER))
    return '<div class="legend">%s</div><svg class="wide" viewBox="0 0 %d %d" role="img" aria-label="Daily cost by session kind">%s</svg>' % (
        legend, W, H, "".join(out))


def weekly_chart(weeks):
    pts = []
    for k, rs in sorted(weeks.items()):
        n = len({r["session_id"] for r in rs})
        pts.append((k, sum(r["_cost"] or 0 for r in rs) / n if n else 0, n))
    if not pts:
        return "<p class='note'>No usage in the window.</p>"
    W, H, P = 460, 220, {"l": 52, "r": 56, "t": 16, "b": 28}
    top = nice_max(max(p[1] for p in pts))
    ph = H - P["t"] - P["b"]
    step = (W - P["l"] - P["r"]) / max(len(pts) - 1, 1)
    xy = [(P["l"] + (step * i if len(pts) > 1 else (W - P["l"] - P["r"]) / 2),
           H - P["b"] - v / top * ph) for i, (_, v, _) in enumerate(pts)]
    out = y_axis(W, H, P, top)
    if len(xy) > 1:
        out.append('<polyline points="%s" fill="none" stroke="var(--s1)" stroke-width="2" '
                   'stroke-linejoin="round" stroke-linecap="round"/>' % " ".join("%.1f,%.1f" % p for p in xy))
    for (k, v, n), (x, y) in zip(pts, xy):
        out.append('<circle cx="%.1f" cy="%.1f" r="5" fill="var(--s1)" stroke="var(--surface)" stroke-width="2"/>' % (x, y))
        out.append('<circle cx="%.1f" cy="%.1f" r="14" fill="transparent" data-tip="%s: %s per session (%d sessions)"/>' % (
            x, y, k, money(v), n))
        out.append('<text x="%.1f" y="%d" text-anchor="middle">%s</text>' % (x, H - 8, k[5:]))
    x, y = xy[-1]
    out.append('<text class="val" x="%.1f" y="%.1f" dominant-baseline="middle">%s</text>' % (
        x + 10, y, money(pts[-1][1])))
    return '<svg viewBox="0 0 %d %d" role="img" aria-label="Cost per session by week">%s</svg>' % (W, H, "".join(out))


def skills_chart(by_skill, total):
    items = by_skill[:8]
    if not items:
        return "<p class='note'>No usage in the window.</p>"
    W, rowh, P = 460, 30, {"l": 150, "r": 64}
    H = rowh * len(items) + 8
    top = max(e["cost"] for _, e in items) or 1
    out = []
    for i, (k, e) in enumerate(items):
        y = 4 + i * rowh
        w = max((W - P["l"] - P["r"]) * e["cost"] / top, 1)
        name = k if len(k) <= 22 else k[:21] + "…"
        out.append('<text class="lbl" x="%d" y="%.1f" text-anchor="end" dominant-baseline="middle">%s%s</text>' % (
            P["l"] - 10, y + rowh / 2, esc(name), " · squad" if k in SQUAD_SKILLS else ""))
        out.append('<path d="M%d,%.1f H%.1f Q%.1f,%.1f %.1f,%.1f V%.1f Q%.1f,%.1f %.1f,%.1f H%d Z" fill="var(--s1)"/>' % (
            P["l"], y + 7, P["l"] + w - 4, P["l"] + w, y + 7, P["l"] + w, y + 11, y + rowh - 11,
            P["l"] + w, y + rowh - 7, P["l"] + w - 4, y + rowh - 7, P["l"]))
        out.append('<text class="val" x="%.1f" y="%.1f" dominant-baseline="middle">%s</text>' % (
            P["l"] + w + 8, y + rowh / 2, money(e["cost"])))
        out.append('<rect x="0" y="%.1f" width="%d" height="%d" fill="transparent" data-tip="%s: %s, %s of total, %d sessions, %d calls"/>' % (
            y, W, rowh, esc(k), money(e["cost"]), pct(e["cost"], total), len(e["sessions"]), e["calls"]))
    return '<svg viewBox="0 0 %d %d" role="img" aria-label="Cost by skill">%s</svg>' % (W, H, "".join(out))


MCP_RE = re.compile(r"^mcp__(.+?)__")


def split_list(v):
    return [x for x in (v or "").split(",") if x]


def tool_sections(rows):
    """Tool mix and MCP servers: every tool the model called, failures by
    who stopped them, and for each MCP server the sessions that used it
    against those that did not, in the same window."""
    kinds = ERROR_KINDS
    tools = {}
    for r in rows:
        for name in split_list(r["tools"]):
            e = tools.setdefault(name, {"calls": 0, "sessions": set(), **{k: 0 for k in kinds}})
            e["calls"] += 1
            e["sessions"].add(r["session_id"])
        for item in split_list(r["tool_errors"]):
            kind, _, name = item.partition(":")
            if name in tools and kind in kinds:
                tools[name][kind] += 1
    total_calls = sum(e["calls"] for e in tools.values())
    L = ["## Tools", "",
         "Every tool call the model made. Failed calls are split by who stopped "
         "them: a hook, the auto-mode classifier, a permission rule or mode "
         "(policy), you, or the tool itself (error).", ""]
    if tools:
        L += ["| Tool | Calls | Share | Sessions | Failed | Hook | Classifier | Policy | User | Error |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for name, e in sorted(tools.items(), key=lambda kv: -kv[1]["calls"])[:25]:
            failed = sum(e[k] for k in kinds)
            L.append("| %s | %s | %s | %d | %d | %s |" % (
                name, "{:,}".format(e["calls"]), pct(e["calls"], total_calls), len(e["sessions"]),
                failed, " | ".join(str(e[k]) for k in kinds)))
    else:
        L.append("No tool calls in the window.")
    L.append("")

    servers = {}
    for r in rows:
        for name in split_list(r["tools"]):
            m = MCP_RE.match(name)
            if m:
                servers.setdefault(m.group(1), set()).add(r["session_id"])
    by_session = {}
    for r in rows:
        by_session.setdefault(r["session_id"], []).append(r)

    def per_session(sids):
        rs = [r for sid in sids for r in by_session[sid]]
        n = len(sids)
        if not n:
            return "n/a", "n/a", "n/a", "n/a"
        cost = sum(x["_cost"] or 0 for x in rs) / n
        tok = (prompt_tokens(rs) + sum(x["output"] for x in rs)) / n
        blocked = sum(1 for x in rs for i in split_list(x["tool_errors"])
                      if not i.startswith("error:")) / n
        return money(cost), "{:,}".format(int(tok)), pct(cache_read(rs), prompt_tokens(rs)), "%.1f" % blocked

    L += ["## MCP servers", "",
          "Each cell is *with / without*: sessions that called the server against "
          "the other sessions in the window. Not an experiment: you choose when a "
          "server is used, and the work differs. A server installed everywhere has "
          "no *without* sessions; compare against a window from before it instead.", ""]
    if servers:
        L += ["| Server | Calls | Sessions | Cost/session | Tokens/session | Cache hit | Blocked calls/session |",
              "|---|---:|---:|---:|---:|---:|---:|"]
        everyone = set(by_session)
        for srv, sids in sorted(servers.items(), key=lambda kv: -len(kv[1])):
            calls = sum(e["calls"] for n, e in tools.items() if n.startswith("mcp__%s__" % srv))
            w, wo = per_session(sids), per_session(everyone - sids)
            L.append("| %s | %s | %d / %d | %s / %s | %s / %s | %s / %s | %s / %s |" % (
                srv, "{:,}".format(calls), len(sids), len(everyone - sids),
                w[0], wo[0], w[1], wo[1], w[2], wo[2], w[3], wo[3]))
    else:
        L.append("No MCP server calls in the window.")
    L.append("")
    stats = {
        "calls": total_calls,
        "failed": sum(e[k] for e in tools.values() for k in kinds),
        "hook": sum(e["hook"] for e in tools.values()),
        "servers": sorted(servers),
    }
    return L, stats


TREND_DAYS = 28
MIN_UNITS = 10


def group_rows(rows, key):
    g = {}
    for r in rows:
        g.setdefault(key(r), []).append(r)
    return g


def version_key(v):
    return [int(x) if x.isdigit() else -1 for x in re.split(r"[.\-]", v)]


def hook_section(runs):
    """Hook executions recorded natively by Claude Code: which hooks ran on
    which event, how long they took, how often they blocked, and how much
    context they added to the prompt."""
    L = ["## Hooks", "",
         "Hook runs as Claude Code records them (hook summaries and hook "
         "attachments). Context is what a hook added to the prompt, in "
         "characters: it costs input tokens on every later call.", ""]
    if not runs:
        return L + ["No hook runs in the window.", ""]
    g = {}
    for h in runs:
        e = g.setdefault((h["hook"], h["event"]), {"runs": 0, "sessions": set(), "ms": 0,
                                                   "blocking": 0, "error": 0, "chars": 0})
        e["runs"] += 1
        e["sessions"].add(h["session_id"])
        e["ms"] += int(h["duration_ms"] or 0)
        e["chars"] += int(h["chars"] or 0)
        if h["outcome"] in ("blocking", "error"):
            e[h["outcome"]] += 1
    L += ["| Hook | Event | Runs | Sessions | Avg ms | Blocking | Errors | Context chars |",
          "|---|---|---:|---:|---:|---:|---:|---:|"]
    for (hook, event), e in sorted(g.items(), key=lambda kv: -kv[1]["runs"]):
        L.append("| %s | %s | %s | %d | %d | %d | %d | %s |" % (
            hook, event, "{:,}".format(e["runs"]), len(e["sessions"]), e["ms"] // e["runs"],
            e["blocking"], e["error"], "{:,}".format(e["chars"])))
    return L + [""]


def trend_section(all_rows, all_verdicts, all_prs, project, now):
    """Last TREND_DAYS against the TREND_DAYS before: cost and outcome per
    unit of work, never cost alone. A change is shown only when both
    periods have at least MIN_UNITS units."""
    cut = now - dt.timedelta(days=TREND_DAYS)
    start = cut - dt.timedelta(days=TREND_DAYS)
    periods = {"prev": lambda t: start <= t < cut, "last": lambda t: cut <= t <= now}

    def metrics(inp):
        rs = [r for r in all_rows if inp(r["_t"])]
        sess = group_rows(rs, lambda r: r["session_id"])
        m = {}

        def per_session(sids, f):
            return (sum(f(sess[s]) for s in sids) / len(sids) if sids else None, len(sids))
        cost = lambda x: sum(r["_cost"] or 0 for r in x)
        m["cost_session"] = per_session(list(sess), cost)
        for k in KIND_ORDER:
            m["cost_" + k] = per_session([s for s in sess if sess[s][0]["_kind"] == k], cost)
        m["tok_session"] = per_session(list(sess), lambda x: prompt_tokens(x) + sum(r["output"] for r in x))
        pt = prompt_tokens(rs)
        m["cache"] = (100.0 * cache_read(rs) / pt if pt else None, len(sess))
        m["blocked"] = per_session(list(sess), lambda x: sum(
            1 for r in x for i in split_list(r["tool_errors"]) if not i.startswith("error:")))
        first = {}
        for v in sorted((v for v in all_verdicts if inp(v["_t"])), key=lambda v: v["ts"]):
            first.setdefault(v["session_id"], v["verdict"])
        m["first_pass"] = (100.0 * sum(1 for v in first.values() if v == "APPROVED") / len(first)
                           if first else None, len(first))
        prs = [p for p in all_prs if inp(dt.datetime.fromisoformat(p["date"]).replace(tzinfo=dt.timezone.utc))]
        merged = [p for p in prs if p["merged"]]
        pcost = sum(r["_cost"] or 0 for r in rs if r["_squad"] and r["project"] == project)
        m["cost_pr"] = (pcost / len(merged) if merged else None, len(merged))
        m["rework"] = (100.0 * sum(1 for p in prs if p["followups"] > 0) / len(prs) if prs else None, len(prs))
        return m

    prev, last = metrics(periods["prev"]), metrics(periods["last"])
    spec = [
        ("Cost per session", "cost_session", "$", "lower"),
        ("Cost per squad session", "cost_squad", "$", "lower"),
        ("Cost per custom session", "cost_custom", "$", "lower"),
        ("Cost per vanilla session", "cost_vanilla", "$", "lower"),
        ("Tokens per session", "tok_session", "n", "lower"),
        ("Cache hit ratio", "cache", "%", "higher"),
        ("Blocked calls per session", "blocked", "x", "lower"),
        ("Reven approval at first review", "first_pass", "%", "higher"),
        ("Squad cost per merged PR", "cost_pr", "$", "lower"),
        ("PRs with commits after opening", "rework", "%", "lower"),
    ]

    def fmt(v, unit):
        if v is None:
            return "n/a"
        return {"$": money(v), "%": "%.0f%%" % v, "n": "{:,}".format(int(v)), "x": "%.1f" % v}[unit]

    def change(a, b, unit):
        (va, na), (vb, nb) = a, b
        if va is None or vb is None:
            return "n/a", ""
        if na < MIN_UNITS or nb < MIN_UNITS:
            return "too few units", ""
        if unit == "%":
            d = vb - va
            return "%+.0f pp" % d, d
        if va == 0:
            return "n/a", ""
        d = 100.0 * (vb - va) / va
        return "%+.0f%%" % d, d

    L = ["## Are you improving?", "",
         "Last %d days against the %d days before, per unit of work. Read cost "
         "next to outcome: cost down with more rework is not an improvement. A "
         "change needs at least %d units in both periods; below that it is "
         "noise. Not an experiment: the work itself differs between periods." % (
             TREND_DAYS, TREND_DAYS, MIN_UNITS), "",
         "| Metric | Better if | Previous | Last | Change | Units (prev / last) |",
         "|---|---|---:|---:|---:|---:|"]
    for label, key, unit, better in spec:
        ch, _ = change(prev[key], last[key], unit)
        L.append("| %s | %s | %s | %s | %s | %d / %d |" % (
            label, better, fmt(prev[key][0], unit), fmt(last[key][0], unit), ch,
            prev[key][1], last[key][1]))
    L.append("")
    ch, _ = change(prev["cost_session"], last["cost_session"], "$")
    return L, {"cost_per_session": ch, "sessions": "%d/%d" % (prev["cost_session"][1], last["cost_session"][1])}


def render_html(md_lines, ctx):
    tiles = [
        ("Cost", money(ctx["total"]), "API-equivalent, %d days" % ctx["days"]),
        ("Sessions", "%d" % ctx["sessions"], "%d squad, %d custom, %d vanilla" % ctx["kinds"]),
        ("Cache hit ratio", ctx["cache"], "cache reads / prompt tokens"),
        ("PRs merged", ctx["prs"], ctx["prs_note"]),
    ]
    tiles_html = "".join('<div class="tile"><div class="k">%s</div><div class="v">%s</div>'
                         '<div class="d">%s</div></div>' % tuple(esc(x) for x in t) for t in tiles)
    return """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Code stats</title><style>%s</style></head><body><main>
<h1>Claude Code stats</h1><p class="sub">%s</p>
<div class="tiles">%s</div>
<section class="card"><h2>Daily cost by session kind</h2>%s</section>
<div class="grid2"><section class="card"><h2>Cost per session, by week</h2>%s</section>
<section class="card"><h2>Top skills by cost</h2>%s</section></div>
%s
</main><div id="tip" role="tooltip"></div><script>%s</script></body></html>""" % (
        HTML_CSS, esc(ctx["window"]), tiles_html, daily_chart(ctx["days_map"]),
        weekly_chart(ctx["weeks"]), skills_chart(ctx["by_skill"], ctx["total"]),
        md_to_html(md_lines), HTML_JS)



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
