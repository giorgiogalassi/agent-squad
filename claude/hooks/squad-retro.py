#!/usr/bin/env python3
"""squad-retro.py -- verdict trail against post-merge events (DRAFT, #402).

Verbs (stdout follows SCRIPT_CONTRACT.md: KEY=value lines only):

  collect --days N | --batch [<ralph-run.md>] [--min M]
                      Build the trail for the window or the batch and
                      cache it under .squad/retro/.trail.json.
  report              Render the cached trail to .squad/retro/<date>.md
                      and emit the summary keys.

Sources, all read-only:
  progress.txt        "[#ID] [date] review: <VERDICT> r<N>[ <anything>]",
                      observations from "Obs:"/"obs:" when present, else
                      the trailing text (surrounding parentheses dropped),
                      "[#ID] review: N rounds, last verdict <X>",
                      "[#ID] [date] resolved. PR: #M (base: ...)",
                      "[#ID] [date] escalated (N attempts). <reason>",
                      "[#ID] [date] skipped. Blocked by escalated <ID>"
                      IDs are "#327" or "ABC-12" (detached projects).
  ralph-run.md        batch table (Issue | Branch | ... | Rounds | Verdict | State)
  verdicts.tsv        not read: progress.txt is the verdict source (model and
                      timestamp per verdict stay a /stats matter)
  squad-stats.py      `branch <name>` for the cost per branch (COST_USD)
  VCS                 merged/reverted/follow-ups/human comments. Until
                      #397 lands this is `gh` directly, reads only
                      (pr view, pr list, api .../comments); it moves
                      onto squad-vcs.sh / squad-tracker.sh unchanged.
                      TRACKER_MODE != connected -> SOURCE=git-only:
                      merge and follow-up state from the local clone.

Window: an issue is in `--days N` when its latest dated line (review,
resolved, escalated, skipped) is within N days; issues with no dated
line are left out.

Blocker kinds are assigned by whole-word keyword (KINDS below) from the
blocking part of CHANGES_REQUESTED observations only: COMMENT rounds
and `non-blocking:` text never count. KINDS is unvalidated until #403
tunes it, so rule candidates are labelled so. A kind seen in >= --min
PRs (default 3) becomes one `/lore decide` line; the script never
writes to the vault beyond .squad/retro/.

Follow-ups, human comments and reopened state are unknown (None, "?")
in git-only mode, never zero: they stay out of HELD_PCT and the
followed-by-a-fix count (HELD_PCT=? when nothing could be judged).

Exit codes: 0 success, 2 usage error, 10 precondition (vault missing,
no progress.txt, no verdicts in window, no ralph-run.md), 20 I/O error.
Python 3.8+ standard library only.
"""

import datetime as dt
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import squad_pylib as lib  # noqa: E402  (shared progress.txt parser)

SUMMARY_RE = re.compile(r"^\[#?([A-Za-z]+-\d+|\d+)\]\s+(?:(\d{4}-\d{2}-\d{2})\s+)?review:\s+(\d+)\s+rounds?,\s+last verdict\s+([A-Z_]+)")
RESOLVED_RE = re.compile(r"^\[#?([A-Za-z]+-\d+|\d+)\]\s+(?:(\d{4}-\d{2}-\d{2})\s+)?resolved\.\s+PR:\s+#(\d+)")
ESCALATED_RE = re.compile(r"^\[#?([A-Za-z]+-\d+|\d+)\]\s+(?:(\d{4}-\d{2}-\d{2})\s+)?escalated(?:\s+(?:after\s+)?\(?(\d+) attempts?\)?)?\.?\s*(.*)$")
SKIPPED_RE = re.compile(r"^\[#?([A-Za-z]+-\d+|\d+)\]\s+(?:(\d{4}-\d{2}-\d{2})\s+)?skipped\.\s*(.*)$")
RUN_ROW_RE = re.compile(r"^\|\s*#?([A-Za-z]+-\d+|\d+)\s*\|")

# Kind -> keywords matched case-insensitively, on word boundaries (a
# hyphen counts as part of the word: "scout-cache" is not "cache"), in
# the blocking part of CHANGES_REQUESTED observations only.
# Order matters: the first kind whose keyword matches wins per observation.
# UNVALIDATED: tuned on a handful of reviews; #403 validates and tunes it,
# and rule candidates are labelled accordingly until then.
KINDS = [
    ("tests", ("test", "spec", "coverage", "assert", "fixture")),
    ("security", ("secret", "token", "injection", "sanitize", "escape", "auth", "authentication", "authorization")),
    ("error handling", ("error", "exception", "fallback", "retry", "exit code", "timeout")),
    ("scope", ("out of scope", "unrelated", "scope", "acceptance", "criteria")),
    ("naming", ("rename", "naming", "name", "misleading")),
    ("docs", ("readme", "docstring", "comment", "document", "changelog", "skill.md")),
    ("performance", ("performance", "slow", "n+1", "cache", "memory")),
]
KIND_RES = [(k, re.compile("|".join(r"(?<![\w-])%s(?:s|es|ed|ing)?(?![\w-])" % re.escape(w) for w in ws), re.I))
            for k, ws in KINDS]
FOLLOWUP_DAYS = 14


def emit(key, value):
    sys.stdout.write("%s=%s\n" % (key, value))


def fail(code, reason):
    sys.stderr.write("squad-retro: %s\n" % reason)
    sys.exit(code)


def resolve_paths():
    env = {k: os.environ.get("SQUAD_" + k, "") for k in
           ("VAULT_PATH", "PROJECT_ROOT", "DISPLAY_NAME", "TRACKER_MODE")}
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


def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f]
    except OSError:
        return None


def read_tsv(path, cols):
    rows = []
    lines = read_lines(path) or []
    for line in lines[1:] if lines and lines[0].startswith(cols[0]) else lines:
        parts = line.split("\t")
        if len(parts) >= len(cols):
            rows.append(dict(zip(cols, parts)))
    return rows


# ---------------------------------------------------------------- trail

def parse_progress(lines):
    """issue -> {rounds: [(n, verdict, obs)], pr, resolved, escalated, skipped, summary}
    Issue ids are strings: "327" or "ABC-12"."""
    trail = {}

    def rec(issue):
        return trail.setdefault(issue, {"rounds": [], "pr": None, "resolved": None,
                                        "escalated": None, "skipped": None, "summary": None})

    for line in lines:
        rv = lib.parse_review(line)
        if rv:
            r = rec(rv["issue"])
            r["rounds"].append((rv["round"], rv["verdict"], rv["obs"]))
            if rv["date"]:
                r["review_date"] = max(r.get("review_date") or "", rv["date"])
            continue
        m = SUMMARY_RE.match(line)
        if m:
            r = rec(m.group(1))
            r["summary"] = (int(m.group(3)), m.group(4))
            if m.group(2):
                r["review_date"] = max(r.get("review_date") or "", m.group(2))
            continue
        m = RESOLVED_RE.match(line)
        if m:
            r = rec(m.group(1))
            r["pr"] = int(m.group(3))
            r["resolved"] = m.group(2)
            continue
        m = ESCALATED_RE.match(line)
        if m:
            rec(m.group(1))["escalated"] = {"date": m.group(2) or "?", "attempts": int(m.group(3)) if m.group(3) else None,
                                          "reason": (m.group(4) or "").strip()}
            continue
        m = SKIPPED_RE.match(line)
        if m:
            rec(m.group(1))["skipped"] = {"date": m.group(2) or "?", "reason": (m.group(3) or "").strip()}
    for r in trail.values():
        r["rounds"].sort()
        r.setdefault("review_date", None)
    return trail


def batch_issues(path):
    lines = read_lines(path)
    if lines is None:
        fail(10, "no ralph-run.md at %s" % path)
    issues = []
    for line in lines:
        m = RUN_ROW_RE.match(line)
        if m and not line.lstrip("|").strip().startswith("Issue"):
            issues.append(m.group(1))
    return issues


def kind_of(obs):
    for kind, rx in KIND_RES:
        if rx.search(obs):
            return kind
    return "other"


def blocker_kinds(rounds):
    """Kinds of what blocked: the blocking part of CHANGES_REQUESTED rounds.
    COMMENT/APPROVED rounds and `non-blocking:` text never count."""
    kinds = set()
    for _, verdict, obs in rounds:
        if verdict == "CHANGES_REQUESTED":
            part = lib.blocking_part(obs)
            if part:
                kinds.add(kind_of(part))
    return sorted(kinds)


def gh_json(args):
    out = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError((out.stderr or "").strip().splitlines()[-1:] or ["gh failed"])
    return json.loads(out.stdout or "null")


def git_out(args, root):
    out = subprocess.run(["git"] + args, capture_output=True, text=True, cwd=root or None)
    return out.stdout if out.returncode == 0 else ""


def post_merge_vcs(pr, root):
    """Via gh until #397; same shape expected from squad-vcs.sh pr-events."""
    d = gh_json(["pr", "view", str(pr), "--json",
                 "state,mergedAt,mergeCommit,files,reviews,comments,headRefName,baseRefName"])
    merged_at = d.get("mergedAt") or ""
    ev = {"state": d.get("state"), "merged": merged_at[:10] or None,
          "human_comments": 0, "reverted": False, "followups": 0, "reopened": None}
    bot_markers = ("reven", "agent-squad", "claude")
    for c in (d.get("comments") or []) + (d.get("reviews") or []):
        body = (c.get("body") or "").lower()
        login = ((c.get("author") or {}).get("login") or "").lower()
        if not any(b in body[:200] or b in login for b in bot_markers):
            ev["human_comments"] += 1
    if merged_at:
        files = [f.get("path") for f in d.get("files") or []]
        try:
            since = dt.datetime.strptime(merged_at, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            since = dt.datetime.combine(dt.date.fromisoformat(ev["merged"]), dt.time())
        until = since + dt.timedelta(days=FOLLOWUP_DAYS)
        oid = (d.get("mergeCommit") or {}).get("oid", "")
        sha = oid[:7]
        head = d.get("headRefName") or ""
        # Commits after the merge instant that the merge commit and the PR's
        # own head do not already contain, touching the PR's files.
        args = ["log", "--since=%s" % since.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "--until=%s" % until.strftime("%Y-%m-%dT%H:%M:%SZ"), "--format=%h%x09%s"]
        if oid:
            args.append("^" + oid)
        for h in (head, "origin/" + head):
            if head and subprocess.run(["git", "rev-parse", "--verify", "-q", h + "^{commit}"],
                                       cwd=root or None, capture_output=True).returncode == 0:
                args.append("^" + h)
                break
        args += ["HEAD", "--"] + files
        for line in git_out(args, root).splitlines():
            h, _, subj = line.partition("\t")
            if sha and h.startswith(sha):
                continue
            if "revert" in subj.lower() and ((sha and sha in subj) or (head and head in subj)):
                ev["reverted"] = True
            else:
                ev["followups"] += 1
    return ev


def esc_ere(s):
    return re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", s)


def branch_pattern(branch):
    """ERE matching the branch as a whole name in a merge subject
    ("from user/<branch>", "Merge branch '<branch>'"), not as a substring
    of a longer branch name."""
    return r"(^|[/' ])%s('|$| )" % esc_ere(branch)


def post_merge_git(pr, branch, root):
    """Local clone only: merged if a merge commit for the branch (or the
    squash `(#N)`) is in history. Follow-ups and human comments are not
    knowable here: None means unknown, never zero."""
    ev = {"state": "UNKNOWN", "merged": None, "human_comments": None, "reverted": False,
          "followups": None, "reopened": None}
    if not branch:
        return ev
    pat = branch_pattern(branch)
    out = git_out(["log", "--all", "-E", "--grep=%s" % pat, "--format=%cs%x09%s", "-n", "1"], root).strip()
    if out:
        ev["merged"], _, _ = out.partition("\t")
        ev["state"] = "MERGED"
    rev = git_out(["log", "--all", "-E", "--grep=^Revert", "--grep=%s" % pat, "--all-match",
                   "--format=%h", "-n", "1"], root).strip()
    ev["reverted"] = bool(rev)
    return ev


def cmd_collect(argv):
    days, batch, min_occ = None, None, 3
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--days":
            i += 1
            try:
                days = int(argv[i])
            except (IndexError, ValueError):
                fail(2, "--days requires a positive integer")
            if days <= 0:
                fail(2, "--days requires a positive integer")
        elif a == "--batch":
            batch = argv[i + 1] if i + 1 < len(argv) and not argv[i + 1].startswith("--") else "current"
            if batch != "current":
                i += 1
        elif a == "--min":
            i += 1
            min_occ = int(argv[i]) if i < len(argv) and argv[i].isdigit() else fail(2, "--min requires an integer")
        else:
            fail(2, "unknown argument '%s'" % a)
        i += 1
    if days and batch:
        fail(2, "--days and --batch are exclusive")
    if not days and not batch:
        days = 30

    paths = resolve_paths()
    if not paths.get("VAULT_PATH") or not os.path.isdir(paths["VAULT_PATH"]):
        fail(10, "vault not found")
    sd = squad_dir(paths)
    lines = read_lines(os.path.join(sd, "progress.txt"))
    if lines is None:
        fail(10, "no progress.txt under %s" % sd)
    trail = parse_progress(lines)

    if batch:
        run = os.path.join(sd, "ralph-run.md") if batch == "current" else batch
        keep = set(batch_issues(run))
        window = "batch %s" % os.path.basename(run)
    else:
        since = (dt.date.today() - dt.timedelta(days=days)).isoformat()
        def in_window(r):
            # Latest dated event of the issue; an issue with no dated line
            # at all cannot be placed in a window and is left out.
            dates = [d for d in (r["resolved"], r["review_date"], (r["escalated"] or {}).get("date"),
                                 (r["skipped"] or {}).get("date")) if d and d != "?"]
            return bool(dates) and max(dates) >= since
        keep = {i for i, r in trail.items() if in_window(r)}
        window = "last %d days" % days
    trail = {i: r for i, r in trail.items() if i in keep
             and (r["rounds"] or r["summary"] or r["pr"] or r["escalated"] or r["skipped"])}
    if not trail:
        fail(10, "no verdicts in the window")

    connected = paths.get("TRACKER_MODE") == "connected"
    source = "vcs" if connected else "git-only"
    run_rows = {}
    rl = read_lines(os.path.join(sd, "ralph-run.md")) or []
    for line in rl:
        m = RUN_ROW_RE.match(line)
        if m:
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            run_rows[m.group(1)] = cells
    for issue, r in trail.items():
        branch = run_rows.get(issue, [None, None])[1] if issue in run_rows else None
        r["branch"] = branch
        r["kinds"] = blocker_kinds(r["rounds"])
        if r["pr"] and connected:
            try:
                r["post"] = post_merge_vcs(r["pr"], paths.get("PROJECT_ROOT"))
            except (RuntimeError, OSError, ValueError, json.JSONDecodeError) as e:
                sys.stderr.write("squad-retro: PR #%s: %s\n" % (r["pr"], e))
                r["post"] = post_merge_git(r["pr"], branch, paths.get("PROJECT_ROOT"))
                source = "git-only"
        else:
            r["post"] = post_merge_git(r["pr"], branch, paths.get("PROJECT_ROOT"))

    out_dir = os.path.join(sd, "retro")
    try:
        changed = lib.write_if_changed(os.path.join(out_dir, ".trail.json"), json.dumps(
            {"window": window, "source": source, "min": min_occ,
             "project": paths.get("DISPLAY_NAME"), "trail": trail}, indent=1))
    except OSError as e:
        fail(20, "cannot write trail: %s" % e)

    posts = [r["post"] for r in trail.values()]
    known_fu = [p for p in posts if p.get("followups") is not None]
    emit("OUTCOME", "applied" if changed else "unchanged")
    emit("CHANGED", "yes" if changed else "no")
    emit("PRS", sum(1 for r in trail.values() if r["pr"] or r["rounds"] or r["summary"]))
    emit("REVIEWED", sum(1 for r in trail.values() if r["rounds"] or r["summary"]))
    emit("ESCALATED", sum(1 for r in trail.values() if r["escalated"]))
    emit("SKIPPED", sum(1 for r in trail.values() if r["skipped"] and not r["pr"]))
    emit("MERGED", sum(1 for p in posts if p.get("merged")))
    emit("REVERTED", sum(1 for p in posts if p.get("reverted")))
    emit("FOLLOWED_UP", sum(1 for p in known_fu if p["followups"] > 0) if known_fu else "?")
    emit("UNKNOWN", sum(1 for p in posts if p.get("state") == "UNKNOWN"))
    emit("SOURCE", source)
    emit("WINDOW", window)


# --------------------------------------------------------------- report

def cmd_report(argv):
    if argv:
        fail(2, "report takes no arguments")
    paths = resolve_paths()
    sd = squad_dir(paths)
    try:
        with open(os.path.join(sd, "retro", ".trail.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        fail(10, "no collected trail; run collect first")
    trail = dict(data["trail"])
    min_occ = data.get("min", 3)

    reviewed = [r for r in trail.values() if r["rounds"] or r["summary"]]
    rounds = [len(r["rounds"]) or (r["summary"][0] if r["summary"] else 0) for r in reviewed]
    first_pass = sum(1 for r in reviewed if r["rounds"] and r["rounds"][0][1] == "APPROVED")
    approved = [r for r in reviewed if (r["rounds"] and r["rounds"][-1][1] == "APPROVED")
                or (r["summary"] and r["summary"][1] == "APPROVED")]
    # followups None = unknown (git-only mode): such an approval is neither
    # held nor failed, so it stays out of the HELD_PCT denominator.
    judged = [r for r in approved if r["post"].get("merged")
              and (r["post"].get("reverted") or r["post"].get("followups") is not None)]
    held = [r for r in judged if not r["post"].get("reverted") and r["post"]["followups"] == 0]
    unknown_fu = [r for r in approved if r["post"].get("merged") and not r["post"].get("reverted")
                  and r["post"].get("followups") is None]
    by_kind = {}
    for issue, r in trail.items():
        for k in r["kinds"]:
            by_kind.setdefault(k, []).append(issue)
    top = max(by_kind.items(), key=lambda kv: len(kv[1]), default=("none", []))

    cost = cost_per_merged(paths, trail)

    cands = []
    for kind, issues in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
        if len(issues) >= min_occ:
            cands.append('- unvalidated: /lore decide "Reven blocks on %s: raised in %d of %d reviewed PRs (%s); '
                         'add the check to Cody\'s pre-PR list" --rule'
                         % (kind, len(issues), len(reviewed), ", ".join(ref(i) for i in issues)))

    today = dt.date.today().isoformat()
    L = ["# Retro: %s, %s" % (data.get("project") or "project", data["window"]),
         "", "Source: %s. Generated %s by squad-retro.py (draft)." % (data["source"], today), "",
         "## Trail", "",
         "| Issue | PR | Rounds | Verdicts | Merged | Reverted | Follow-ups | Human comments | Reopened | Cost |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for issue in sorted(trail, key=sort_key):
        r = trail[issue]
        if not (r["pr"] or r["rounds"] or r["summary"]):
            continue
        p = r["post"]
        verdicts = " > ".join("%s r%d" % (v, n) for n, v, _ in r["rounds"]) or (
            "%s (%d rounds)" % (r["summary"][1], r["summary"][0]) if r["summary"] else "-")
        L.append("| %s | %s | %d | %s | %s | %s | %s | %s | %s | %s |" % (
            ref(issue), "#%d" % r["pr"] if r["pr"] else ("escalated" if r["escalated"] else "-"),
            len(r["rounds"]) or (r["summary"][0] if r["summary"] else 0), verdicts,
            p.get("merged") or "-", "yes" if p.get("reverted") else "no",
            na(p.get("followups")), na(p.get("human_comments")), na(p.get("reopened")),
            ("$%.2f" % cost["per_issue"][issue]) if issue in cost["per_issue"] else "-"))
    L += ["", "## Approvals", "",
          "- Approved: %d; held after merge: %d; followed by a fix or revert: %d; "
          "merged with follow-ups unknown: %d; not merged or unknown: %d"
          % (len(approved), len(held), len(judged) - len(held), len(unknown_fu),
             sum(1 for r in approved if not r["post"].get("merged"))),
          "", "## Blockers by kind", "", "| Kind | PRs | Where |", "|---|---|---|"]
    for kind, issues in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
        L.append("| %s | %d | %s |" % (kind, len(issues), ", ".join(ref(i) for i in issues)))
    esc = [(i, r) for i, r in trail.items() if r["escalated"]]
    skp = [(i, r) for i, r in trail.items() if r["skipped"] and not r["pr"]]
    L += ["", "## Escalations (%d) and blocked skips (%d)" % (len(esc), len(skp)), ""]
    if esc:
        L += ["| Issue | Date | Attempts | Reason |", "|---|---|---|---|"]
        for i, r in sorted(esc, key=lambda t: sort_key(t[0])):
            e = r["escalated"]
            L.append("| %s | %s | %s | %s |" % (ref(i), e["date"], na(e["attempts"]), e["reason"][:160].replace("|", "/")))
    else:
        L.append("No escalation in the window.")
    if skp:
        L.append("")
        L.append("Skipped because blocked: " + ", ".join(ref(i) for i, _ in sorted(skp, key=lambda t: sort_key(t[0]))))
    L += ["", "## Rounds", "",
          "- Reviewed PRs: %d; approved at round 1: %d; rounds on average: %s"
          % (len(reviewed), first_pass, "%.1f" % (sum(rounds) / len(rounds)) if rounds else "n/a"),
          "", "## Rule candidates (min %d PRs, unvalidated until #403 tunes the kinds)" % min_occ, ""]
    L += cands or ["No pattern reached %d PRs." % min_occ]
    L.append("")

    report = os.path.join(sd, "retro", "%s.md" % today)
    try:
        changed = lib.write_if_changed(report, "\n".join(L))
    except OSError as e:
        fail(20, "cannot write report: %s" % e)

    emit("OUTCOME", "applied" if changed else "unchanged")
    emit("CHANGED", "yes" if changed else "no")
    emit("REPORT", report)
    emit("ROUNDS_AVG", "%.1f" % (sum(rounds) / len(rounds)) if rounds else "0")
    emit("FIRST_PASS_PCT", int(100 * first_pass / len(reviewed)) if reviewed else 0)
    emit("HELD_PCT", int(100 * len(held) / len(judged)) if judged else "?")
    emit("TOP_BLOCKER_KIND", top[0])
    emit("TOP_BLOCKER_COUNT", len(top[1]))
    emit("COST_PER_MERGED_PR", "%.2f" % cost["per_merged"])
    emit("ESCALATED", len(esc))
    emit("CANDIDATES", len(cands))


def na(v):
    return "?" if v is None else str(v)


def ref(issue):
    return issue if "-" in issue else "#%s" % issue


def sort_key(issue):
    m = re.match(r"^([A-Za-z]*-?)(\d+)$", issue)
    return (m.group(1), int(m.group(2))) if m else (issue, 0)


def cost_per_merged(paths, trail):
    """Cost per branch through `squad-stats.py branch <name>` (COST_USD),
    so Retro and /stats never disagree on a figure."""
    per_issue, merged_total, merged_n = {}, 0.0, 0
    stats = os.path.join(HERE, "squad-stats.py")
    for issue, r in trail.items():
        if not r.get("branch"):
            continue
        try:
            out = subprocess.run([sys.executable, stats, "branch", r["branch"]],
                                 capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if out.returncode != 0:
            continue
        for line in out.stdout.splitlines():
            if line.startswith("COST_USD="):
                try:
                    per_issue[issue] = float(line.split("=", 1)[1])
                except ValueError:
                    pass
        if issue in per_issue and r["post"].get("merged"):
            merged_total += per_issue[issue]
            merged_n += 1
    return {"per_issue": per_issue, "per_merged": merged_total / merged_n if merged_n else 0.0}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        sys.exit(2)
    verb, rest = sys.argv[1], sys.argv[2:]
    if verb == "collect":
        cmd_collect(rest)
    elif verb == "report":
        cmd_report(rest)
    else:
        fail(2, "unknown verb '%s'" % verb)


if __name__ == "__main__":
    main()
