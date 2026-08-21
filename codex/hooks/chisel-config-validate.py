#!/usr/bin/env python3
"""Validate every chisel-config.json in the vault against the schema
documented in codex/skills/chisel/SKILL.md.

The schema (allowed keys per mode, and the connected-mode disavowed key
list) is parsed at runtime from the SKILL.md's "## Configuration flow"
section — specifically the two fenced ```json blocks (detached shape,
then connected shape) and the "Disavowed keys" bullet list that follows
them. This script carries no hardcoded copy of the schema: change the MD
and this script follows, with no code edit.

Usage: chisel-config-validate.py [--prune]
No positional arguments. Discovers every
<vault>/projects/*/.squad/chisel-config.json via path-resolve.sh (the
vault is never assumed to be CWD, never hardcoded).

By default the script is strictly read-only: it only reports violations
and never writes to any config or to the SKILL.md.

--prune: opt-in removal. For each config that fails validation, remove
only the exact keys the validator flagged as unknown/disavowed (leaving
every documented key and its relative key order untouched), re-validate
the pruned file, and report what was removed and whether the file now
passes. The file is rewritten with canonical JSON formatting (2-space
indent, trailing newline) — original indentation width or other
whitespace styling is NOT preserved, only key presence and order.
Configs that fail to parse as JSON are never pruned — a malformed file
is reported and left alone, never guessed at. Configs that are already
clean are never rewritten (no-op, no touched mtimes).

An empty file, or a config that parses to `{}` (or otherwise has no
`chisel` key), is treated as a violation rather than CLEAN: Chisel's own
"Configuration check" (SKILL.md) treats a missing or fieldless config as
needing the configuration flow, so this validator reports the same
config as failing rather than passing.

Exit codes:
  0 — every discovered config is clean (or no configs were found).
  1 — at least one config has a violation (parse failure, unknown key,
      disavowed key, wrong mode value, empty/fieldless config, etc).
      With --prune, this reflects the post-prune state.
  2 — the schema source of truth itself could not be resolved or
      parsed (path-resolve.sh missing/failed, SKILL.md not found, the
      expected fences/sections missing or malformed). This is a setup
      failure, distinct from a config being invalid, and is fatal:
      the script cannot validate anything without the schema.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

MODE_VALUES = {"detached", "connected"}
PROJECT_KEYS = {"owner", "number"}

SKILL_MD_RELATIVE = "codex/skills/chisel/SKILL.md"


def resolve_paths():
    """Run path-resolve.sh and return (vault_path, project_root)."""
    script = Path.home() / ".codex" / "hooks" / "path-resolve.sh"
    if not script.exists():
        fail(f"path-resolve.sh not found at {script}; cannot resolve vault path.")
    try:
        out = subprocess.run(
            ["bash", str(script)], capture_output=True, text=True, check=True
        ).stdout
    except subprocess.CalledProcessError as exc:
        fail(f"path-resolve.sh failed: {exc}")

    values = {}
    for line in out.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()

    vault = values.get("VAULT_PATH")
    root = values.get("PROJECT_ROOT")
    if not vault:
        fail("path-resolve.sh did not report VAULT_PATH.")
    return vault, root


def fail(message):
    """Loud, unrecoverable failure — used for source-of-truth problems."""
    print(f"FATAL: {message}", file=sys.stderr)
    sys.exit(2)


def find_skill_md(project_root):
    """Locate the Chisel SKILL.md that is the schema's source of truth.

    Checked in order: PROJECT_ROOT first, so a developer working inside a
    checkout always validates against their working tree rather than a
    possibly stale installed copy. Only after that do we fall back to the
    checkout implied by this script's own location, then the documented
    installed layouts (Claude and Codex), so the validator also works when
    run outside any git repository with only the installed files present.
    """
    candidates = []
    if project_root:
        candidates.append(Path(project_root) / SKILL_MD_RELATIVE)
    # Fall back to resolving relative to this script's own repo checkout,
    # in case PROJECT_ROOT points somewhere unexpected.
    candidates.append(Path(__file__).resolve().parents[2] / SKILL_MD_RELATIVE)
    # Documented installed layouts (README): hook under ~/.claude/hooks or
    # ~/.codex/hooks, skill under ~/.claude/skills or ~/.agents/skills.
    candidates.append(Path.home() / ".claude" / "skills" / "chisel" / "SKILL.md")
    candidates.append(Path.home() / ".agents" / "skills" / "chisel" / "SKILL.md")

    for candidate in candidates:
        if candidate.is_file():
            return candidate
    fail(
        "Chisel SKILL.md not found (looked at: "
        + ", ".join(str(c) for c in candidates)
        + "). The schema source of truth is unreadable; refusing to fall "
        "back to a built-in schema."
    )


def parse_schema(skill_md_path):
    """Parse allowed key sets and disavowed keys from SKILL.md.

    Returns a dict:
      {
        "detached": {"allowed": set(...)},
        "connected": {"allowed": set(...), "disavowed": {"tracker": "..."}},
        "state_label_keys": set(...),
      }
    """
    try:
        text = skill_md_path.read_text()
    except OSError as exc:
        fail(f"Could not read {skill_md_path}: {exc}")

    section_match = re.search(
        r"^## Configuration flow\n(.*?)(?=^## |\Z)", text, re.S | re.M
    )
    if not section_match:
        fail(
            f"'## Configuration flow' section not found in {skill_md_path}; "
            "the schema source of truth is unparseable."
        )
    section = section_match.group(1)

    json_blocks = re.findall(r"```json\n(.*?)```", section, re.S)
    if len(json_blocks) != 2:
        fail(
            f"Expected exactly 2 ```json fences in the Configuration flow "
            f"section of {skill_md_path}, found {len(json_blocks)}. The "
            "schema anchors have changed shape and the parser needs updating."
        )

    try:
        detached_shape = json.loads(json_blocks[0])
        connected_shape = json.loads(json_blocks[1])
    except json.JSONDecodeError as exc:
        fail(f"Could not parse json fences in {skill_md_path}: {exc}")

    detached_allowed = set(detached_shape.get("chisel", {}).keys())
    connected_allowed = set(connected_shape.get("chisel", {}).keys())

    if not detached_allowed or not connected_allowed:
        fail(
            f"One of the parsed json fences in {skill_md_path} had no keys "
            "under 'chisel'; the schema anchors have changed shape."
        )

    # state_labels' inner keys are also part of the schema (the connected
    # shape fence), not a separate hardcoded list: change the fence and
    # this parser follows, same as every other key set here.
    connected_state_labels = connected_shape.get("chisel", {}).get(
        "state_labels", {}
    )
    if not isinstance(connected_state_labels, dict) or not connected_state_labels:
        fail(
            f"The connected shape json fence in {skill_md_path} had no "
            "'state_labels' object with keys; the schema anchors have "
            "changed shape."
        )
    state_label_keys = set(connected_state_labels.keys())

    # Disavowed keys (connected mode) bullet list, e.g.:
    # Disavowed keys (connected mode):
    # - `tracker` — must not appear. Report it by name as disavowed, ...
    disavowed = {}
    disavowed_match = re.search(
        r"Disavowed keys \(connected mode\):\n((?:.*\n?)+?)(?=\n\S|\Z)", section
    )
    if disavowed_match:
        # Bullets may wrap onto continuation lines (no leading '-'); join
        # them back onto their bullet before splitting into key/reason.
        bullets = []
        for line in disavowed_match.group(1).splitlines():
            if line.startswith("- "):
                bullets.append(line[2:].strip())
            elif line.strip() and bullets:
                bullets[-1] += " " + line.strip()
        for bullet in bullets:
            bullet_match = re.match(r"`([^`]+)`\s*—\s*(.+)", bullet)
            if bullet_match:
                key, reason = bullet_match.groups()
                disavowed[key] = reason.strip()

    return {
        "detached": {"allowed": detached_allowed},
        "connected": {"allowed": connected_allowed, "disavowed": disavowed},
        "state_label_keys": state_label_keys,
    }


def validate_config(data, schema):
    """Validate a single parsed config dict against the schema.

    Returns (violations, mode) where violations is a list of dicts:
      {
        "message": human-readable violation string,
        "path": tuple of keys to the offending entry, or None if the
                violation is not a single removable key (e.g. 'chisel'
                itself is not an object, or mode has an invalid value),
      }
    An empty violations list means the config is clean.
    """
    violations = []

    chisel = data.get("chisel")
    if chisel is None:
        # Empty {} or missing 'chisel' wrapper key: Chisel's own
        # "Configuration check" (SKILL.md) treats a config that doesn't
        # exist or is missing required fields as needing the
        # configuration flow — not as a valid, already-configured state.
        # Agree with that verdict rather than reporting CLEAN.
        violations.append(
            {
                "message": (
                    "chisel: config is empty or missing the 'chisel' key "
                    "— Chisel's configuration flow has not been run"
                ),
                "path": None,
            }
        )
        return violations, "connected"
    if not isinstance(chisel, dict):
        violations.append({"message": "'chisel' key is not an object", "path": None})
        return violations, "connected"

    mode = chisel.get("mode")
    if mode is None:
        mode = "connected"  # no mode field => connected (backward compat)
    elif mode not in MODE_VALUES:
        violations.append(
            {
                "message": (
                    f"mode: invalid value {mode!r} (expected one of "
                    f"{sorted(MODE_VALUES)})"
                ),
                # Not a removable key: the config still needs a mode.
                "path": None,
            }
        )
        # Can't reliably pick an allowed-key set for an invalid mode
        # value; fall back to connected, per the no-mode-means-connected
        # rule (the invalid value itself is already reported above).
        mode = "connected"

    mode_schema = schema[mode]
    allowed = mode_schema["allowed"]
    disavowed = mode_schema.get("disavowed", {})

    for key in chisel.keys():
        if key == "mode":
            continue
        if key in disavowed:
            violations.append(
                {
                    "message": (
                        f"chisel.{key}: disavowed under mode={mode} — "
                        f"{disavowed[key]}"
                    ),
                    "path": ("chisel", key),
                }
            )
            continue
        if key not in allowed:
            violations.append(
                {
                    "message": f"chisel.{key}: unknown key under mode={mode}",
                    "path": ("chisel", key),
                }
            )
            continue
        if key == "state_labels":
            state_labels = chisel[key]
            if not isinstance(state_labels, dict):
                violations.append(
                    {
                        "message": (
                            f"chisel.state_labels: expected an object, got "
                            f"{type(state_labels).__name__}"
                        ),
                        "path": None,
                    }
                )
            else:
                for inner_key in state_labels.keys():
                    if inner_key not in schema["state_label_keys"]:
                        violations.append(
                            {
                                "message": (
                                    f"chisel.state_labels.{inner_key}: unknown "
                                    f"key under mode={mode}"
                                ),
                                "path": ("chisel", "state_labels", inner_key),
                            }
                        )
        if key == "project":
            project = chisel[key]
            if not isinstance(project, dict):
                violations.append(
                    {
                        "message": (
                            f"chisel.project: expected an object, got "
                            f"{type(project).__name__}"
                        ),
                        "path": None,
                    }
                )
            else:
                for inner_key in project.keys():
                    if inner_key not in PROJECT_KEYS:
                        violations.append(
                            {
                                "message": (
                                    f"chisel.project.{inner_key}: unknown "
                                    f"key under mode={mode}"
                                ),
                                "path": ("chisel", "project", inner_key),
                            }
                        )

    return violations, mode


def prune_config(data, violations):
    """Remove the keys named by each violation's path from data, in place.

    Returns a list of dotted key strings that were actually removed.
    Violations with path=None (not a single removable key) are left
    untouched — they are reported but never guessed at.
    """
    removed = []
    for violation in violations:
        path = violation["path"]
        if not path:
            continue
        # Walk to the parent container and pop the final key.
        container = data
        ok = True
        for step in path[:-1]:
            if isinstance(container, dict) and step in container:
                container = container[step]
            else:
                ok = False
                break
        if ok and isinstance(container, dict) and path[-1] in container:
            del container[path[-1]]
            removed.append(".".join(path))
    return removed


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=(
            "Validate every chisel-config.json in the vault against the "
            "schema documented in codex/skills/chisel/SKILL.md."
        )
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help=(
            "Remove the exact keys flagged as violations from each "
            "failing config (opt-in; the script is read-only without "
            "this flag)."
        ),
    )
    return parser.parse_args(argv)


def main():
    args = parse_args(sys.argv[1:])

    vault, project_root = resolve_paths()
    skill_md_path = find_skill_md(project_root)
    schema = parse_schema(skill_md_path)

    configs = sorted(Path(vault).glob("projects/*/.squad/chisel-config.json"))

    if not configs:
        print("No chisel-config.json files found in the vault.")
        return 0

    clean_count = 0
    failing_count = 0

    for config_path in configs:
        project_name = config_path.parents[1].name
        try:
            raw = config_path.read_text()
        except OSError as exc:
            print(f"FAIL  {project_name}: could not read file ({exc})")
            failing_count += 1
            continue

        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(f"FAIL  {project_name}: invalid JSON ({exc})")
            if args.prune:
                print(
                    "        refusing to prune: file does not parse as "
                    "JSON; will not attempt to repair malformed JSON"
                )
            failing_count += 1
            continue

        violations, mode = validate_config(data, schema)

        if not violations:
            clean_count += 1
            print(f"CLEAN {project_name} (mode={mode})")
            continue

        failing_count += 1
        print(f"FAIL  {project_name} (mode={mode}):")
        for v in violations:
            print(f"        {v['message']}")

        if not args.prune:
            continue

        removed = prune_config(data, violations)
        if not removed:
            print("        prune: nothing removable in this file")
            continue

        pruned_text = json.dumps(data, indent=2) + "\n"
        try:
            config_path.write_text(pruned_text)
        except OSError as exc:
            print(f"        prune: FAILED to write ({exc})")
            continue

        print(f"        prune: removed {', '.join(removed)}")

        # Re-validate the file as written, from disk, so the report
        # reflects reality rather than the in-memory dict.
        reread = json.loads(config_path.read_text())
        post_violations, post_mode = validate_config(reread, schema)
        if post_violations:
            print(
                f"        prune: re-validated, still FAILING "
                f"(mode={post_mode}):"
            )
            for v in post_violations:
                print(f"          {v['message']}")
        else:
            print(f"        prune: re-validated, now CLEAN (mode={post_mode})")

    total = clean_count + failing_count
    print(f"\n{clean_count} clean, {failing_count} failing, {total} total.")

    return 1 if failing_count else 0


if __name__ == "__main__":
    sys.exit(main())
