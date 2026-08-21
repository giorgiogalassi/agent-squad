# Label State Machine

The canonical definition of what happens to GitHub issue labels across
the squad's lifecycle — Chisel creates issues, Cody claims and opens
PRs, Ralph orchestrates and escalates, and `.github/workflows/issue-lifecycle.yml`
reconciles state on PR close. Four label families are in play, three
configured under `chisel.state_labels` and one under `chisel.review_label`
in `chisel-config.json` (see `claude/skills/chisel/SKILL.md` /
`codex/skills/chisel/SKILL.md` for the config shape):

- `review_label` (default `needs-review`) — connected mode only. Applied
  by Chisel to every issue (and its parent, if any) at creation. Means
  "a human has not yet triaged this issue"; Ralph's batch-discovery gate
  excludes anything still carrying it.
- `state_labels.in_progress` (default `in-progress`) — applied by Cody
  when it claims an issue.
- `state_labels.in_review` (default `in-review`) — applied by Cody when
  it opens a PR.
- `state_labels.blocked` (default `blocked`) — applied by Ralph when an
  issue escalates after exhausting its retry budget.

> **This document is not read by any skill or agent at runtime.** Like
> `PATH_RESOLUTION.md`, it exists so a human changing the lifecycle has
> the full picture and the rationale in one place. Skills stay
> self-contained (Iteration 19, see `JOURNAL.md`) — each of Chisel,
> Cody, and Ralph carries its own copy of the label commands relevant to
> its own steps. Keep those copies in sync with the table below; this
> file is the tie-breaker when they'd otherwise drift, not a thing any
> agent loads.

## The state machine

| Step | Actor | Mode | `review_label` | `in_progress` | `in_review` | `blocked` |
|---|---|---|---|---|---|---|
| Create | Chisel | connected | **+ add** | — | — | — |
| Claim | Cody | connected | untouched | **+ add** | — | — |
| PR opens (review) | Cody | connected | **− remove** (if configured) | **− remove** | **+ add** | — |
| Escalate (3 failed attempts) | Ralph | connected | untouched | **− remove** | untouched | **+ add** |
| Close via merge | `.github/workflows/issue-lifecycle.yml` | connected | **− remove** (idempotent) | **− remove** | **− remove** | **− remove** |
| PR closed without merging | `.github/workflows/issue-lifecycle.yml` | connected | untouched | untouched | **− remove** | untouched |
| Issue closed manually, no PR | — (human action) | connected | untouched | untouched | untouched | untouched |
| Every step | Ralph / Cody | detached | n/a — `review_label` is a connected-only config field | simulated via handoff checklist line | simulated via handoff checklist line | simulated via handoff checklist line |

Detached mode never calls `gh`, so nothing in this table applies beyond
"n/a" / "simulated": Ralph appends checklist lines
(`- [ ] Move <KEY> to In Progress` / `In Review` / `Blocked`) to the
batch handoff file, and the human replays them into whatever tracker
they actually use. `review_label` isn't part of the detached config
shape at all (see the Configuration flow in either Chisel SKILL.md) —
there is no pre-work review gate to model.

## Where `review_label` is removed, and why not earlier

Two removal points are correct, and one that looks tempting is
deliberately avoided:

- **Not at claim.** Batch discovery already filters on `review_label`
  *before* Cody ever sees the issue — by the time a normal (non-override)
  claim happens, the label is already gone, because a human removed it
  themselves as their actual act of review. The one path where an issue
  can reach claim while still carrying it is Ralph's explicit-ID
  override (`ralph <issue-id>` on an issue that still carries the
  label — "an explicit ID is a user override of the review gate", per
  `claude/skills/ralph/SKILL.md`). If Cody's claim step stripped the
  label automatically as a side effect of that override, it would
  silently record "reviewed" for an issue nobody actually reviewed —
  the override bypasses the gate's *enforcement*, it should not also
  fabricate the gate's *evidence*. So claim never touches it.
- **At PR-open (Cody's review step), in both trees.** This is the first
  point after claim where the removal is unambiguously justified: a PR
  is now open, a human reviewer is about to look at real code, and
  `in_review` becomes the operative "needs review" signal going
  forward. Retiring the stale pre-work `review_label` here is safe
  (idempotent no-op if it was already gone) and keeps a single issue
  from visually carrying two different "needs review" labels with two
  different meanings at once.
- **At merge-close, in the shared GitHub Actions workflow.** Already
  implemented (`STATE_LABELS` in `.github/workflows/issue-lifecycle.yml`
  includes the review label's default name alongside the two Cody/Ralph
  state labels) as a final, idempotent belt-and-suspenders sweep. This
  file is shared by both distributions — it reconciles state for
  whichever agent tree did the work, so there is nothing tree-specific
  left to duplicate here.
- **Not at escalation.** An escalated (`blocked`) issue that still
  carries `review_label` is not a bug: it genuinely still needs a human
  to look at it, for two different reasons now (it failed, and — if the
  override path was used — it was never triaged either). Escalation
  therefore only ever removes `in_progress` and adds `blocked`; it never
  touches `review_label`. Because `in_progress` is always removed when
  `blocked` is added (both trees, see below), an escalated issue can
  carry at most `blocked` + `review_label` together — never
  `in-progress` + `blocked` + `needs-review` simultaneously.
- **Not on manual close without a merge.** `.github/workflows/issue-lifecycle.yml`
  only triggers on `pull_request: closed` and `issues: reopened` — a
  human closing an issue directly (wontfix, duplicate, etc.) fires
  neither. Any labels left on it are inert: Ralph's batch discovery
  always filters `--state open`, so a closed issue never re-enters
  consideration regardless of what labels it still carries. Leaving
  this path unautomated is a deliberate scope boundary, not a gap —
  adding an `issues: closed` handler purely for label hygiene on issues
  that can never be picked up again is future, optional work, not part
  of this fix.

## Files carrying this state machine

Both trees, kept in parity (grep for `add-label`/`remove-label` to
verify claim, review-swap, and escalation commands match this table):

- `claude/skills/chisel/SKILL.md` / `codex/skills/chisel/SKILL.md` —
  applies `review_label` at creation; verifies/creates all configured
  labels on first connected run.
- `claude/agents/cody.md` / `codex/agents/cody.toml` — claims
  (`in_progress`); on PR-open, swaps `in_progress` → `in_review` and
  removes `review_label` if configured.
- `claude/skills/ralph/SKILL.md` / `codex/skills/ralph/SKILL.md` —
  batch-discovery review gate (claude only — see note below); escalation
  swaps `in_progress` → `blocked`, never leaving both attached at once.
- `.github/workflows/issue-lifecycle.yml` — single shared file, not
  duplicated per tree; clears all three `state_labels` plus
  `review_label` on merge, and clears `in_review` on a non-merge PR
  close.

**Known asymmetry, out of scope here:** `codex/skills/ralph/SKILL.md`'s
batch discovery does not implement the `review_label` exclusion at all
(claude's does — see `claude/skills/ralph/SKILL.md`'s "Review gate").
That is a pre-existing gap distinct from the three defects this file's
history (issue #114) fixes, and both codex defects it does fix (escalation
leaving `in_progress` attached, and Chisel never verifying/creating
configured labels) are contingent on the pending decision about whether
the codex distribution is kept at all.
