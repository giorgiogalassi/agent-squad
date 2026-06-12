# Platform Differences

This file explains the semantic and technical differences between the two
distributions in this repo:

- `claude/`
- `codex/`

Both trees implement the same Agent Squad workflow and write to the same
`.squad/` runtime files. The differences are in platform mechanics, not in the
overall product flow.

---

## Shared Semantics

These behaviors are intentionally the same in both trees:

- `Forge` runs discovery and writes `.squad/forge/output.yaml`
- `Archy` turns high-complexity work into `.squad/prd/current.md`
- `Chisel` decomposes YAML or PRD input into Linear issues
- `Ralph` runs issues in dependency order using `Blocked by:` metadata
- `Cody` implements issues and opens PRs
- `Reven` reviews PRs against acceptance criteria and project conventions
- `.squad/` is the shared workflow contract for both environments

If one of those semantics changes, it should usually change in both trees.

---

## Semantic Differences By Component

### Seed

The biggest semantic difference is `Seed`.

- Claude `Seed` and Codex `Seed` both generate `.squad/` runtime files
- Neither variant modifies the user's project instruction file by default
- Claude `Seed` is still written for Claude-native invocation patterns
- Codex `Seed` is still written for Codex-native invocation patterns

This is no longer about injecting `.squad` into startup instructions. The main
difference is how each platform invokes and orchestrates the workflow.

### Ralph

`Ralph` is the second major semantic divergence.

- Claude `Ralph` is written for Claude subagent orchestration
- Codex `Ralph` is written for Codex subagent orchestration
- The execution intent is the same, but the delegation mechanism is not

### Cody and Reven

`Cody` and `Reven` are behaviorally aligned across both trees, but their
definition format differs enough that they cannot share one file.

- Claude versions are native Claude subagent definitions
- Codex versions are native Codex custom agent definitions
- The role semantics are intentionally kept as close as possible

### Forge, Archy, Chisel

These are mostly semantically aligned. The primary differences are mechanical:

- invocation wording
- MCP tool prefix
- platform-local metadata conventions

### Lore

Lore is the most semantically divergent agent across platforms
because Claude Code has native auto-memory and Codex does not.

**Claude Lore** owns the cross-tool layer only:
- Never duplicates content in ~/.claude/ auto-memory directories
- Writes cross-tool preferences to development.md only
- Does not write to project decisions.md (auto-memory handles that
  locally for Claude Code sessions)

**Codex Lore** owns the full memory layer:
- Writes both global preferences and project-local decisions
- lore prefer writes to both development.md and decisions.md

**Shared behavior (identical across both):**
- Vault location: SECOND_BRAIN_PATH env var → ~/second-brain/ default; lore-config.json lives at the vault root
- lore start deduces project from git, always overwrites INDEX.md
- Timestamp mismatch detection and inline recovery offer
- 7-day staleness check with git branch status
- status.md schema and overwrite behavior
- Experience log schema with type field and 5 type definitions
- lore end confirms active project for next session
- lore recover reconstructs from git evidence
- 100-line cap on development.md with curation step
- Confirmation required before any write
- <private> tag stripping
- Cody incremental checkpoint at PR open
- Instance namespacing ([claude-code] / [codex])
- Invocation aliases (lore start/end/prefer/recover) recognized
  without clarification in both platforms
- Staleness check uses 30-minute wall clock threshold, not
  checkpoint-vs-updated comparison, to prevent false positives
  on tool switches
- Context refs auto-loaded at session start, no confirmation needed
- status.md Done section compressed to ~400 token cap
- Next section uses ACTION/CONTEXT signal marker format

**No MCP dependency in either platform.**
The vault is a plain markdown directory. Both Lore definitions
use Read, Write, and Bash tools exclusively. MCP is not used and
not recommended for Lore's access patterns. See docs/backends.md.

---

## Technical Differences

### Project Entrypoint

| Concern | Claude | Codex |
|---------|--------|-------|
| Project instruction file | `CLAUDE.md` | `AGENTS.md` |
| Required for Agent Squad | no | no |
| Context loading style | skills and agents read `.squad/...` when needed | skills and agents read `.squad/...` when needed |

### Skill Format

| Concern | Claude | Codex |
|---------|--------|-------|
| File shape | `SKILL.md` | `SKILL.md` |
| Frontmatter approach | keeps `allowed-tools` | keeps only portable metadata |
| Install target used in this repo | `~/.claude/skills/` | `~/.agents/skills/` |

The Codex skill install path is based on the current local Codex skill system
and a live Codex run on this machine, which attempted to load user skills from
`~/.agents/skills/`.

### Agent Format

| Concern | Claude | Codex |
|---------|--------|-------|
| File format | Markdown with YAML frontmatter | standalone TOML |
| Verified required fields | `name`, `description` | `name`, `description`, `developer_instructions` |
| Installed location | `.claude/agents/` or `~/.claude/agents/` | `.codex/agents/` or `~/.codex/agents/` |
| Lore | `claude/agents/lore.md` | `codex/agents/lore.toml` |

### Model Naming

| Concern | Claude | Codex |
|---------|--------|-------|
| Default implementation/review model | `sonnet` | `gpt-5.4` |
| High-complexity analysis model | `opus` | `gpt-5.4` |

### Linear MCP Prefix

| Concern | Claude | Codex |
|---------|--------|-------|
| Linear prefix | `mcp__linear-server__` | `mcp__linear__` |

---

## Verification Status

### Verified from official docs

- Claude custom agents are Markdown files with YAML frontmatter under
  `.claude/agents/` or `~/.claude/agents/`
- Claude agent files require `name` and `description`
- Codex custom agents are standalone TOML files under `.codex/agents/` or
  `~/.codex/agents/`
- Codex custom agent files require `name`, `description`, and
  `developer_instructions`

### Verified from the local install

- Codex currently uses `gpt-5.4` by default on this machine
- Codex looks for user skills under `~/.agents/skills/` in live runs on this
  machine
- Codex plugin-packaged agents use `agents/openai.yaml`, but standalone custom
  agents use TOML
- A prompt-driven live check attempted subagent delegation in Codex, which
  suggests custom agent discovery is wired into the runtime, but the
  non-interactive run failed before returning a clean end-to-end confirmation

### Inferred / lower-confidence areas

- I did not validate the Codex custom agents through a clean interactive
  session where they complete a full spawned task end-to-end
- Claude skills in `claude/skills/` remain structurally consistent with the
  repo's intended Claude workflow, but I did not execute a live Claude session
  to validate every slash-command assumption end-to-end

---

## Copy Rules

### Claude

- `claude/skills/*` -> `~/.claude/skills/`
- `claude/agents/*` -> `~/.claude/agents/`
- `claude/agents/lore.md` -> `~/.claude/agents/`

### Codex

- `codex/skills/*` -> `~/.agents/skills/`
- `codex/agents/*` -> `~/.codex/agents/`
- `codex/agents/lore.toml` -> `~/.codex/agents/`

---

## Maintenance Rule

If you change workflow semantics, mirror the change in both trees.

If you change only platform mechanics, change only the relevant tree.
