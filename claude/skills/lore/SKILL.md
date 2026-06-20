---
name: lore
description: >
  Slash-command entrypoint for the Lore second-brain agent. Triggers:
  /lore start, /lore end, /lore prefer "<decision>", /lore recover.
  This skill exists so Lore's subcommands work as slash-commands; it
  delegates immediately to the Lore agent and does no work itself.
  Do NOT use for planning, implementation, architecture, or code review.
allowed-tools: Task
---

# Lore (entrypoint)

This skill is a thin wrapper. It does not manage memory itself. Its only
job is to resolve the naming collision in Claude Code, where `lore start`
reads like a slash-command but Lore is a subagent that must be delegated
to explicitly.

When invoked, delegate to the `lore` agent immediately, passing the
subcommand and any arguments exactly as received:

- `/lore start`            -> invoke the lore agent with: lore start
- `/lore end [logfile]`    -> invoke the lore agent with: lore end [logfile]
- `/lore prefer "<text>"`  -> invoke the lore agent with: lore prefer "<text>"
- `/lore recover`          -> invoke the lore agent with: lore recover

Do not interpret, summarize, or pre-process the subcommand. Do not read
or write the vault yourself. Hand off to the agent and let it run. All
behavior, confirmation rules, and output belong to the agent, not this
wrapper.

If no recognized subcommand is given, list the four above and stop.
