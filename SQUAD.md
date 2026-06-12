# Squad

Agent Squad is a personal multi-agent development workflow.
It runs on Claude Code and Codex. Skills are installed globally in
`~/.claude/` and `~/.codex/`. Host projects have zero Squad footprint.

All runtime state lives in the vault (`~/second-brain/` or
`$SECOND_BRAIN_PATH`). Per-project `.squad/` directories live inside the
vault at `<vault>/projects/<project-name>/.squad/`, not in the host project.

## Principles

Context window = RAM: volatile, limited, reset on every session.
Filesystem = disk: persistent, unlimited, survives everything.
Anything important gets written to disk.

## Loading discipline (all companions follow this)

Before reading raw project files, follow this order:
1. Read `<vault>/INDEX.md` + active project
   `<vault>/projects/<n>/status.md` (via Lore)
2. Read `<vault>/projects/<n>/.squad/architecture.md` +
   `<vault>/projects/<n>/.squad/scout-cache.md`
3. Read raw project files only when needed for the current task

Never load all files upfront. Load only what the task requires.
The vault is a plain markdown directory — read files directly,
no MCP required.

## Agent roster

| Agent | Type | Role |
|-------|------|------|
| Seed | Skill | Project initialization |
| Forge | Skill | Interactive discovery → output.yaml |
| Archy | Skill | PRD from Forge YAML (HIGH only) |
| Chisel | Skill | YAML or PRD → Linear issues |
| Ralph | Skill | Agentic loop invoking Cody |
| Cody | Agent | Implements issues, opens PRs |
| Reven | Agent | Reviews PRs |
| Lore | Agent | Second-brain memory management |

## Invocation conventions

- Claude Code: `/seed`, `/forge`, `/archy`, `/chisel`, `/ralph`
- Codex: use the named skill directly
- Lore: `lore start`, `lore end`, `lore prefer "<decision>"`

## Severity model

| Level | Criteria | Flow |
|-------|----------|------|
| low | Isolated, single module, no new deps | Forge → Chisel → Ralph |
| medium | New components, existing patterns | Forge → Chisel → Ralph |
| high | New patterns, new deps, cross-module | Forge → Archy → Chisel → Ralph |

## Second-brain contract

Canonical path schema: all per-project Squad state resolves to
`<vault>/projects/<display-name>/.squad/`, where the display name comes
from the `projects` map in `<vault>/lore-config.json`. Any skill, agent,
or document that references a different `.squad/` location is a bug.

The vault is tool-agnostic. Both Claude Code and Codex read and write it.
Lore is the only agent that writes to the vault. No other agent writes
there directly, except Cody which checkpoints `status.md` at PR open.

Vault layout:

```text
<vault>/                           (default: ~/second-brain/, override: $SECOND_BRAIN_PATH)
  lore-config.json                 Vault config. Written by Lore on first start.
  INDEX.md                         Entry point read by all companions at session start.
  preferences/
    development.md                 Global cross-tool preferences.
  projects/<name>/
    .squad/                        Per-project Squad state (tool-agnostic).
      architecture.md
      scout-cache.md
      decisions.md
      forge/output.yaml
      prd/current.md
      prd/archive/
      chisel-config.json
      progress.txt
      issues/                    Detached-mode batch files and handoff checklists.
    status.md                      Resumption handoff. Written by Lore, checkpointed by Cody.
    decisions.md                   Key decisions log. Append-only.
  experiences/YYYY-MM/             Monthly session logs.
```

Host projects contain only their own source code — no `.squad/` directory
and no `lore-config.json` are written to the project root.

## Session log

Each session has one log at
`<vault>/projects/<display-name>/.squad/session.log`. `lore start` resets
it, skills append milestone lines as they run, and `lore end` reads it by
default. The log is what lets a session survive `/clear` boundaries:
conversation context resets, the log does not.

Line format: `[YYYY-MM-DD HH:MM] [component] event — details`

Writers: lore, seed, forge, archy, chisel, ralph. Agents do not write to
the session log. Cody checkpoints `status.md` at PR open instead, and
Reven runs read-only by design.

## Tracker modes

Chisel, Ralph, and Cody support two tracker modes, selected by
`chisel.mode` in `chisel-config.json` (missing field = `connected`):

- **connected**: issues live in a tracker reached via MCP (Linear).
  Agents create issues, update statuses, and open PRs directly.
- **detached**: agents never touch the tracker or the forge. Chisel
  writes a batch file with local issue IDs, Ralph executes from it and
  accumulates a handoff checklist of tracker actions for the user to
  replay manually, Cody commits locally and prints a paste-ready PR
  description without pushing. Reven diffs the local branch.

Detached mode exists for environments where agents must not hold write
access to company tools (Jira, Bitbucket), and doubles as the fallback
when the tracker MCP is unavailable. Forge, Archy, Seed, and Lore are
identical in both modes.

## Trust domains

One vault per trust domain. Work and personal memory never share a
vault: global files (INDEX.md, preferences/development.md) are written
on every session and would leak one domain's context into the other's
remote. Select the vault per context with `SECOND_BRAIN_PATH` (shell
profile, direnv). A gitignored subdirectory inside a shared vault is
not an acceptable substitute.

## Sentry note

When Sentry is active it calls Lore automatically at session boundaries.
Until then, invoke Lore manually.
