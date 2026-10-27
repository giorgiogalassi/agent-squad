---
name: lore
description: >
  Slash-command entrypoint for the Lore second-brain agent. Triggers:
  /lore start (setup/repair only), /lore prefer "<decision>", /lore decide, /lore supersede, /lore audit, /lore recover.
  This skill exists so Lore's subcommands work as slash-commands; it
  delegates immediately to the Lore agent and does no work itself.
  Do NOT use for planning, implementation, architecture, or code review.
allowed-tools: Agent, SendMessage
---

# Lore (entrypoint)

A thin wrapper: it resolves the naming collision where `lore start`
reads like a slash-command but Lore is a subagent that must be delegated
to explicitly.

Delegate to the `lore` agent immediately, passing the subcommand and
arguments exactly as received:

- `/lore start`            → lore start
- `/lore prefer "<text>" [--global|--project|--decision]`  → lore prefer "<text>" [flag]
- `/lore decide "<title>: <body>" [--supersedes "<date> <title>"] [--rule]`  → lore decide with the same arguments
- `/lore supersede "<title>"... [--by "<title>"|--by-new "<title>: <body>"]`  → lore supersede with the same arguments
- `/lore audit [project]`  → lore audit [project]
- `/lore recover`          → lore recover

Never interpret, summarize, or pre-process the subcommand; never read or
write the vault yourself. All behavior, confirmation rules, and output
belong to the agent. No recognized subcommand → list the six above and
stop.

Lore returns any write that needs an explicit yes (Tier 2) as a proposal.
Show the proposal to the user and ask. On a yes, resume the same agent
(SendMessage) with `User confirmed: "<the user's reply, verbatim>"`; on
anything else, tell the agent nothing and stop.
