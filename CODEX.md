# Codex Adaptation Guide

This file documents every change needed to run the Agent Squad on Codex CLI instead of Claude Code. The skill and agent definitions in this repo are written for Claude Code. Apply the changes below when copying files to your Codex config.

---

## Directory Paths

| What | Claude Code | Codex |
|------|-------------|-------|
| Skills | `~/.claude/skills/<name>/SKILL.md` | `~/.codex/skills/<name>/SKILL.md` |
| Agents | `~/.claude/agents/<name>.md` | `~/.codex/agents/<name>.md` (verify with Codex docs) |
| Project config | `.claude/` | `.codex/` (for tool config only — `.squad/` is shared) |

`.squad/` is tool-agnostic and requires no changes. Both Claude Code and Codex read and write to it identically.

---

## MCP Tool Prefix

Every skill that calls Linear MCP tools uses a prefix derived from the server name at configuration time.

| Tool | Claude Code | Codex |
|------|-------------|-------|
| Prefix | `mcp__linear-server__` | `mcp__linear__` |

**Files to update:**

`skills/chisel/SKILL.md` — `allowed-tools` frontmatter and all tool call references:
```
# Claude Code
mcp__linear-server__create_issue
mcp__linear-server__list_issue_labels
mcp__linear-server__search_issues

# Codex
mcp__linear__create_issue
mcp__linear__list_issue_labels
mcp__linear__search_issues
```

`skills/ralph/SKILL.md` — `allowed-tools` frontmatter:
```
# Claude Code
mcp__linear-server__list_issues
mcp__linear-server__get_issue
mcp__linear-server__update_issue

# Codex
mcp__linear__list_issues
mcp__linear__get_issue
mcp__linear__update_issue
```

`agents/cody.md` — `tools` frontmatter:
```
# Claude Code
mcp__linear-server__get_issue
mcp__linear-server__update_issue

# Codex
mcp__linear__get_issue
mcp__linear__update_issue
```

---

## Model Names

| Role | Claude Code | Codex |
|------|-------------|-------|
| Default agent model | `sonnet` (claude-sonnet-*) | equivalent OpenAI model (e.g. `gpt-4.1`) |
| High-complexity / Archy | `opus` (claude-opus-*) | equivalent high-capability model |

**Files to update:** `agents/cody.md`, `agents/reven.md` — `model` frontmatter field.

Archy model is chosen at invocation time, not in frontmatter, so no file change needed there.

---

## Frontmatter Field Differences

| Field | Claude Code | Codex |
|-------|-------------|-------|
| Skill tool permissions | `allowed-tools: Read, Glob, Write, Bash` | verify Codex equivalent — may use `tools:` or be unrestricted |
| Agent tool permissions | `tools: Bash, Read, Write, Edit, Glob, mcp__...` | verify Codex equivalent |
| Max turns | `maxTurns: 40` | verify Codex equivalent field name |

Codex may ignore unknown frontmatter fields silently. Check Codex release notes for the current schema.

---

## Features Not Available in Codex

| Feature | Status |
|---------|--------|
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Claude Code only. Parallel Qugh + Reven not available in Codex. Run sequentially instead. |
| Native Agent() subagent spawning (Ralph → Cody) | Claude Code only. Ralph may not be able to spawn Cody as a subagent in Codex. Verify before activating Ralph on Codex. |
| Prompt caching for Scout | Claude Code only. Scout context will not be cached between sessions in Codex. |

---

## CLAUDE.md equivalent

Claude Code uses `CLAUDE.md` as the entry point loaded automatically in every session. Codex uses a different file — check current Codex documentation for the equivalent (`AGENTS.md` or similar). The `@.squad/architecture.md` and `@.squad/scout-cache.md` import syntax may also differ.

---

## Summary Checklist

When copying skills/agents to a Codex setup, go through this list:

- [ ] Copy `skills/` to `~/.codex/skills/`
- [ ] Copy `agents/` to `~/.codex/agents/` (verify path)
- [ ] Replace `mcp__linear-server__` with `mcp__linear__` in chisel, ralph, cody
- [ ] Update `model:` field in cody.md and reven.md
- [ ] Verify `allowed-tools` / `tools` frontmatter syntax for Codex
- [ ] Verify `maxTurns` field name for Codex
- [ ] Configure Linear MCP in `~/.codex/config.toml` (see JOURNAL.md §8.2)
- [ ] Create equivalent of `CLAUDE.md` for Codex entry point
- [ ] Note Agent Teams and subagent spawning are unavailable — adjust Ralph and Sentry expectations
