"""squad_pylib.py -- helpers shared by squad-retro.py and squad-atlas.py
(and squad-graph.py's callers): the progress.txt review parser and the
write-if-changed helper behind OUTCOME/CHANGED.

Imported with the hooks directory on sys.path; never run directly.
Python 3.8+ standard library only.
"""

import os
import re
import subprocess

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


def state_name(vault):
    """The vault's state directory name, as decided by path-resolve.sh."""
    env = dict(os.environ, SECOND_BRAIN_PATH=vault)
    try:
        out = subprocess.run(
            ["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "path-resolve.sh"),
             "--state-name"], capture_output=True, text=True, timeout=30, env=env).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    return out or ".lore"


def state_dir(paths):
    """<vault>/projects/<name>/<state_dir> from resolved paths (STATE_DIR when
    present, else built from the vault's state directory name). "" when there is
    no project name (#441): callers refuse instead of writing under projects/."""
    if paths.get("STATE_DIR"):
        return paths["STATE_DIR"]
    vault = paths.get("VAULT_PATH") or ""
    name = paths.get("DISPLAY_NAME") or os.path.basename(paths.get("PROJECT_ROOT") or "")
    if not name:
        return ""
    return os.path.join(vault, "projects", name, state_name(vault))


def _project(paths):
    return paths.get("DISPLAY_NAME") or os.path.basename(paths.get("PROJECT_ROOT") or "")


def lore_root(paths, read=False):
    """`lore root` for the mapped project (#443): (rc, {KEY: value}). PR-mode vault:
    the project's session worktree (created on first write, never when read=True);
    direct and local-only vaults: the vault. rc 10 = no project or no write root."""
    vault, name = paths.get("VAULT_PATH") or "", _project(paths)
    if not vault or not name:
        return 10, {}
    argv = ["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lore"),
            "root", "--vault", vault, "--project", name] + (["--read"] if read else [])
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        return 20, {}
    kv = {}
    for line in p.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    return p.returncode, kv


_LAST = {}


def commit_state(sub, message):
    """Commit <state dir>/<sub> (a file or folder) written after write_state_dir()
    through `lore commit`; a no-op in direct and local-only vaults. Warns on stderr
    and leaves the files in place when lore refuses or fails."""
    if not _LAST:
        return 0
    rc = commit_paths(_LAST["paths"], [os.path.join(_LAST["state"], sub)], message)
    if rc != 0:
        import sys
        sys.stderr.write("squad: vault commit not made (lore commit exit %s); %s is left uncommitted\n" % (rc, sub))
    return rc


def write_state_dir(paths):
    """The state directory a writer edits: lore root's STATE_DIR (the session worktree
    in a PR-mode vault). Remembers the root in paths["WROOT"] for commit_paths.
    "" when there is no write root (callers refuse, exit 10 or 20)."""
    rc, kv = lore_root(paths)
    if rc != 0 or not kv.get("STATE_DIR"):
        return ""
    paths["WROOT"] = kv.get("ROOT", "")
    _LAST.update(paths=paths, state=kv["STATE_DIR"])
    return kv["STATE_DIR"]


def read_state_dir(paths):
    """Where state is read from: the project's session worktree when one exists, else
    the vault checkout (lore root --read; nothing is created). "" without a project."""
    rc, kv = lore_root(paths, read=True)
    return kv.get("STATE_DIR", "") if rc == 0 else ""


def commit_paths(paths, targets, message):
    """Commit files a writer put under the write root (paths["WROOT"], set by
    write_state_dir) through `lore commit`. Only when that root is a session
    worktree: direct and local-only vaults keep their uncommitted behaviour.
    Returns 0 (nothing to do or committed) or the lore exit code."""
    root, vault, name = paths.get("WROOT") or "", paths.get("VAULT_PATH") or "", _project(paths)
    if not root or not name or os.path.realpath(root) == os.path.realpath(vault):
        return 0
    rels = [os.path.relpath(os.path.realpath(t), os.path.realpath(root)) for t in targets]
    argv = ["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lore"), "commit",
            "--vault", vault, "--project", name, "--message", message, "--paths"] + rels
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=180).returncode
    except (OSError, subprocess.TimeoutExpired):
        return 20
