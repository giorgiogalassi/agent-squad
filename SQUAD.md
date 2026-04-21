claude --resume 91ea0866-fe9f-4b75-bdfa-ebe52655e852

# Squad

Agent Squad is a personal multi-agent development workflow.
It runs on Claude Code and Codex. All runtime files live in `.squad/`.
Second-brain files live in `second-brain/`.

## Principles

Context window = RAM: volatile, limited, reset on every session.
Filesystem = disk: persistent, unlimited, survives everything.
Anything important gets written to disk.

## Loading discipline (all companions follow this)

Before reading raw project files, follow this order:
1. Read `second-brain/INDEX.md` + active project
   `second-brain/projects/<n>/status.md` (via Lore)
2. Read `.squad/architecture.md` + `.squad/scout-cache.md`
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

`second-brain/` is tool-agnostic. Both Claude Code and Codex read and
write it. Lore is the only agent that writes to `second-brain/`.
No other agent writes there directly.

## Sentry note

When Sentry is active it calls Lore automatically at session boundaries.
Until then, invoke Lore manually.
