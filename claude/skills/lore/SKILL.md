---
name: lore
description: >
  Slash-command entrypoint for the Lore second-brain agent. Triggers:
  /lore start, /lore prefer "<decision>", /lore recover.
  This skill exists so Lore's subcommands work as slash-commands; it
  delegates immediately to the Lore agent and does no work itself.
  Do NOT use for planning, implementation, architecture, or code review.
allowed-tools: Task
---

# Lore (entrypoint)

A thin wrapper: it resolves the naming collision where `lore start`
reads like a slash-command but Lore is a subagent that must be delegated
to explicitly.

Delegate to the `lore` agent immediately, passing the subcommand and
arguments exactly as received:

- `/lore start`            → lore start
- `/lore prefer "<text>"`  → lore prefer "<text>"
- `/lore recover`          → lore recover

Never interpret, summarize, or pre-process the subcommand; never read or
write the vault yourself. All behavior, confirmation rules, and output
belong to the agent. No recognized subcommand → list the three above and
stop.
