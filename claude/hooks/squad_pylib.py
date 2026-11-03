"""squad_pylib.py -- helpers shared by squad-retro.py and squad-atlas.py
(and squad-graph.py's callers): the progress.txt review parser and the
write-if-changed helper behind OUTCOME/CHANGED.

Imported with the hooks directory on sys.path; never run directly.
Python 3.8+ standard library only.
"""

import os
import re

ID = r"([A-Za-z]+-\d+|\d+)"
REVIEW_RE = re.compile(r"^\[#?" + ID + r"\]\s+(?:(\d{4}-\d{2}-\d{2})\s+)?review:\s+([A-Z_]+|incomplete)\s+r(\d+)\b(.*)$")
OBS_RE = re.compile(r"\b[Oo]bs:\s*(.*)$")


def unwrap(text):
    """Drop one pair of parentheses around the whole text."""
    if text.startswith("(") and text.endswith(")"):
        depth = 0
        for i, c in enumerate(text):
            depth += c == "("
            depth -= c == ")"
            if depth == 0:
                return text[1:-1].strip() if i == len(text) - 1 else text
    return text


def review_obs(rest):
    """Observations from the text after `rN`: the `Obs:` tail when present,
    else the whole trailing text."""
    rest = rest.strip().lstrip(".,;:-").strip()
    m = OBS_RE.search(rest)
    if m:
        obs = m.group(1).strip()
        if obs.endswith(")") and obs.count(")") > obs.count("("):
            obs = obs[:-1].rstrip()
        return obs
    return unwrap(rest)


def parse_review(line):
    """-> {issue, date, verdict, round, obs} for a review line, else None."""
    m = REVIEW_RE.match(line)
    if not m:
        return None
    return {"issue": m.group(1), "date": m.group(2), "verdict": m.group(3).upper(),
            "round": int(m.group(4)), "obs": review_obs(m.group(5))}


_MARK_RE = re.compile(r"\b((?:no|nothing|not)\s+)?(non-?blocking|blocking)\b\s*:?\s*", re.I)


def blocking_part(obs):
    """The part of a CHANGES_REQUESTED observation that blocks: text before
    any marker, plus segments introduced by `blocking:`; segments after
    `non-blocking:` (or `nothing blocking`) are dropped."""
    out, pos, keep = [], 0, True
    for m in _MARK_RE.finditer(obs):
        if keep:
            out.append(obs[pos:m.start()])
        pos = m.end()
        keep = not (m.group(1) or m.group(2).lower().startswith("non"))
    if keep:
        out.append(obs[pos:])
    return " ".join(s.strip() for s in out if s.strip())


def write_if_changed(path, text):
    """Write text to path; True when the content differs from what was there."""
    try:
        with open(path, encoding="utf-8") as f:
            if f.read() == text:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return True
