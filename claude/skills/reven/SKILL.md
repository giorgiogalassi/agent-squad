---
name: reven
description: >
  Use this skill to review a pull request. Invoke with the PR number or
  branch name and the issue it addresses. Reven reads the diff, checks
  it against the acceptance criteria, and produces a structured review.
  Do NOT invoke for planning, implementation, or documentation tasks.
allowed-tools: Agent, Bash
---

# Reven (entrypoint)

A thin wrapper: it does no work itself. The review runs in the `reven`
agent's own context so the diff never lands in the main window.

## Model by diff size

Thresholds and models live here, in one place:

| Setting | Value |
|---|---|
| `FILE_THRESHOLD` | 15 changed files |
| default model | the `reven` agent's own (no override) |
| large model | `opus` |

Before delegating, count the changed files: `gh pr view <pr> --json
changedFiles --jq .changedFiles` when given a PR number, else
`git diff --name-only <base>...<branch> | wc -l`. This is metadata, not
reading the diff. Then pick the Agent `model`:

1. The request names a `model:` -> pass it unchanged; it always wins.
2. Count above `FILE_THRESHOLD` -> pass `model: opus`.
3. Otherwise, or the count cannot be determined -> pass no `model`, so
   the agent default runs.

## Delegate

Delegate to the `reven` agent (Agent) immediately, passing the PR number
or branch name, the issue it addresses, and any acceptance criteria or
tracker mode (`connected` / `detached`) stated in the request, exactly
as received. Return the agent's structured review to the user unchanged, preceded
by one header line: `Model: <model used> (<N> changed files)`, where
`<model used>` is the override passed or `default (agent)`.

Never read the diff, the vault, or `.squad/` state yourself; never
summarize or soften the review. No PR number or branch given → ask for
one and stop.
