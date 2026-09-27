---
name: challenge
description: >
  Use this skill to stress-test a proposal, plan, or piece of writing
  before committing to it. Triggers: /challenge, "challenge this", "push
  back", "poke holes", "devil's advocate", "what do you think about it?".
  Do NOT trigger on ordinary edit requests ("fix this typo", "make it
  shorter") — those are not challenge asks.
allowed-tools: Task
---

# Challenge (entrypoint)

A thin wrapper — but not a pure pass-through like `/lore`: the
`challenge` agent is stateless and cannot see this conversation, so this
skill's one job before delegating is to assemble a self-contained brief
out of what has been said, then hold any pending change until the user
has responded to the result.

## On start

**Path resolution: not applicable.** This skill never runs
`~/.claude/hooks/path-resolve.sh` and never reads or writes `.squad/`
state or touches the vault — see "Statelessness" below. It works
identically inside a squad project, outside one, or in a non-repo
directory.

## Step 1: assemble the brief

Build exactly three fields from the current conversation:

```
Proposal: <the idea, plan, change, or piece of writing to challenge>
Goal: <what it's trying to achieve>
Excerpt: <the relevant text, diff, outline, or code snippet itself>
```

The agent's entire world is this brief — nothing you don't put in it is
visible to it. Pull the excerpt verbatim from the conversation or the
file at hand; do not paraphrase it away.

**Vague request, no clear proposal** (e.g. a bare "what do you think
about it?" with no antecedent, or several candidate proposals in play):
ask the user what exactly is being proposed, or confirm which prior
proposal to use. Never delegate a brief with an empty or guessed
Proposal field.

## Step 2: delegate

Invoke the `challenge` agent (Task) with the assembled brief and nothing
else. Do not pre-judge, summarize, or soften its structured result —
return it to the user as given (per-part `## Verdict: go | revise |
reconsider` plus its sections).

## Step 3: challenge first, hold

If the request that triggered this skill bundled a change alongside the
challenge ask (e.g. "split slides 4–6 into two sections, what do you
think?"), do **not** apply that change yet. Show the challenge result
and wait.

- The user responds to the challenge (agrees, revises, picks an
  alternative, or otherwise engages) → act on that response.
- The user instead overrides outright ("just do it", "apply it anyway")
  → apply the original change without re-arguing the challenge's
  points. An override ends the discussion; it is not an invitation to
  re-litigate.

A challenge asked with no attached change (pure "what do you think")
has nothing to hold — just return the result.

## Statelessness

Do not append anything to a vault `session.log` or any other `.squad/`
file, even when this runs inside a resolved squad project with a vault
available. This skill and the agent it calls are stateless by design:
every invocation is a self-contained brief in, a structured verdict out,
with no record kept of that a challenge happened. This keeps `/challenge`
usable from any directory, squad project or not, without a vault to
write to and without state that would need to be reconciled or cleaned
up later. If a project ever wants a challenge history, that is a
deliberate future addition, not an implicit side effect of this skill.

## Rules

- Never delegate an empty or vague brief — ask first.
- Never apply a bundled change before the user has responded to the
  challenge, except on an explicit override.
- Never write `.squad/` state or touch the vault.
- Never pre-process or soften the agent's structured output.
