---
name: reven
description: >
  Use this skill to review a pull request. Invoke with the PR number or
  branch name and the issue it addresses. Reven reads the diff, checks
  it against the acceptance criteria, and produces a structured review.
  Do NOT invoke for planning, implementation, or documentation tasks.
allowed-tools: Agent
---

# Reven (entrypoint)

A thin wrapper: it does no work itself. The review runs in the `reven`
agent's own context so the diff never lands in the main window.

Delegate to the `reven` agent (Agent) immediately, passing the PR number
or branch name, the issue it addresses, and any acceptance criteria or
tracker mode (`connected` / `detached`) stated in the request, exactly
as received. Return the agent's structured review (`Verdict:` line
included) to the user unchanged.

Never read the diff, the vault, or `.squad/` state yourself; never
summarize or soften the review. No PR number or branch given → ask for
one and stop.
