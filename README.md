# Agent Squad

A personal multi-agent development workflow with separate Claude Code and
Codex distributions.

Forge -> Archy -> Chisel -> Ralph -> Cody -> Reven

## MVP Flow

```mermaid
graph LR
    A["/seed<br/>Initialize .squad context"] --> B["/clear<br/>Reset session context"]
    B --> C["/forge<br/>Interactive discovery<br/>Writes output.yaml"]
    C --> D{"Complexity<br/>confirmed"}
    D -->|HIGH| E["/archy<br/>Create PRD"]

    F["/chisel<br/>Create Linear issues"] --> G["Review issues in Linear"]
    G --> H["/ralph<br/>Execute in dependency order"]
    H --> I["Cody<br/>Implement issue and open PR"]
    I --> J["Reven<br/>Review PR"]
    J -->|Approved| K["Merge"]
    J -->|Changes requested| I

    D -->|LOW / MED| F
    E --> F
```

The diagram shows the current manual MVP: `Seed` prepares context, `Forge`
structures the work, `Archy` appears only for `HIGH` complexity, `Chisel`
creates Linear issues, `Ralph` drives execution through `Cody`, and `Reven`
reviews before merge.

Source: [assets/mvp-flow.mmd](/abs/path/C:/Users/Giorgio/Desktop/projects/agent-squad/assets/mvp-flow.mmd:1)

## What's in this repo

```text
agent-squad/
  JOURNAL.md        Design journal: iterations, decisions, open points
  PLATFORM_DIFFERENCES.md
                    Semantic and technical differences between trees
  README.md         This file
  claude/
    skills/
      forge/        Interactive brainstorming -> .squad/forge/output.yaml
      archy/        Architecture analysis -> .squad/prd/current.md
      chisel/       YAML/PRD -> Linear issues
      seed/         Project initialization -> .squad/ context files
      ralph/        Agentic loop invoking Cody
    agents/
      cody.md       Claude agent definition for implementation
      reven.md      Claude agent definition for review
  codex/
    skills/
      forge/        Codex skill variants
      archy/
      chisel/
      seed/
      ralph/
    agents/
      cody.toml     Codex custom agent
      reven.toml    Codex custom agent
```

## Quick start

```bash
# Claude Code
cp -r claude/skills/* ~/.claude/skills/
cp -r claude/agents/* ~/.claude/agents/
```

```bash
# Codex
cp -r codex/skills/* ~/.agents/skills/
cp -r codex/agents/* ~/.codex/agents/
```

Then, in your project:

```bash
# Claude Code
/seed
/clear
/forge <your idea>
```

```text
# Codex
Use the `seed` skill, then start a fresh session if desired, then use
the `forge` skill.
```

## Workflow data

All runtime files live in `.squad/` inside your project, not in this repo.
`.squad/` is tool-agnostic and works with both Claude Code and Codex.
Agent Squad does not modify `AGENTS.md` or `CLAUDE.md`; skills and agents read
`.squad/` files directly when needed.

```text
your-project/
  .squad/
    architecture.md       written by Seed
    scout-cache.md        written by Seed
    decisions.md          maintained by you
    forge/output.yaml     written by Forge
    prd/current.md        written by Archy
    prd/archive/          archived by Chisel
    chisel-config.json    written on first Chisel run
```

## Claude vs Codex

See `PLATFORM_DIFFERENCES.md` for the exact semantic and technical
differences between the `claude/` and `codex/` sets.

## Further reading

`JOURNAL.md` contains the full design history: why each component exists,
what was tried and rejected, and when to add the next layer.
