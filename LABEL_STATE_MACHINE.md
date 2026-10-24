# Label State Machine

The canonical definition of what happens to GitHub issue labels across
the squad's lifecycle — Chisel creates issues, Cody claims and opens
PRs, Ralph orchestrates and escalates, and `.github/workflows/issue-lifecycle.yml`
reconciles state on PR close. Four label families are in play, three
configured under `chisel.state_labels` and one under `chisel.review_label`
in `chisel-config.json` (see `claude/skills/chisel/SKILL.md` for the
config shape):

- `review_label` (default `needs-review`) — connected mode only. Applied
  by Chisel to every issue (and its parent, if any) at creation. Means
  "a human has not yet triaged this issue"; Ralph's batch-discovery gate
  excludes anything still carrying it
  unless named explicitly. Ralph re-applies it (row L9) when an issue's
  review loop ends without approval, so the next `--parent` run skips it.
- `state_labels.in_progress` (default `in-progress`) — applied by Cody
  when it claims an issue.
- `state_labels.in_review` (default `in-review`) — applied by Cody when
  it opens a PR.
- `state_labels.blocked` (default `blocked`) — applied by Ralph when an
  issue escalates after exhausting its retry budget.

> **This document is not read by any skill or agent at runtime.** Like
> `PATH_RESOLUTION.md`, it exists so a human changing the lifecycle has
> the full picture and the rationale in one place. The table below is
> *performed* by `claude/hooks/squad-labels.sh` (verbs `ensure`, `claim`,
> `review`, `escalate`, `needs-review`; contract in `SCRIPT_CONTRACT.md`), and each
> script-performed row is asserted by a named test in
> `scripts/test-squad-labels.sh`: test names start with the row id
> (`L2 claim: exact argv`), detached cases with `D-`. `scripts/squad-lint.sh`
> (check 7) fails when a script-performed row has no test or a test has no
> row. Rows marked `not script-performed` are done by humans, by Chisel's
> own `gh issue create --label`, or by `issue-lifecycle.yml`, and need no test.

## The state machine

| Id | Step | Actor | Performed by | Mode | `review_label` | `in_progress` | `in_review` | `blocked` |
|---|---|---|---|---|---|---|---|---|
| L1 | Create (label definitions) | Chisel | `squad-labels.sh ensure` | connected | definition exists | definition exists | definition exists | definition exists |
| L2 | Claim | Cody | `squad-labels.sh claim` | connected | untouched | **+ add** | — | — |
| L3 | PR opens (review) | Cody | `squad-labels.sh review` | connected | **− remove** (if configured) | **− remove** | **+ add** | — |
| L4 | Escalate (3 failed attempts) | Ralph | `squad-labels.sh escalate` | connected | untouched | **− remove** | untouched | **+ add** |
| L5 | Create (apply `review_label` to the issue) | Chisel | not script-performed (Chisel `gh issue create --label`, batch 1b) | connected | **+ add** | — | — | — |
| L6 | Close via merge | `.github/workflows/issue-lifecycle.yml` | not script-performed | connected | **− remove** (idempotent) | **− remove** | **− remove** | **− remove** |
| L7 | PR closed without merging | `.github/workflows/issue-lifecycle.yml` | not script-performed | connected | untouched | untouched | **− remove** | untouched |
| L8 | Issue closed manually, no PR | — (human action) | not script-performed | connected | untouched | untouched | untouched | untouched |
| L9 | Out of review rounds, or second `INCOMPLETE` (PR open) | Ralph | `squad-labels.sh needs-review` | connected | **+ add** (exit 10 if not configured) | — | untouched (must be present, else exit 10) | — |
| D | Every step | Ralph / Cody | `squad-labels.sh` with `--handoff` (tests prefixed `D-`) | detached | n/a — `review_label` is a connected-only config field | simulated via handoff checklist line | simulated via handoff checklist line | simulated via handoff checklist line |

L1 ensures the label definitions exist in the repo; L5 is the separate act of
attaching `review_label` to a new issue, which Chisel still does itself.

Detached mode never calls `gh`, so nothing in this table applies beyond
"n/a" / "simulated": Ralph appends checklist lines
(`- [ ] Move <KEY> to In Progress` / `In Review` / `Blocked`) to the
batch handoff file, and the human replays them into whatever tracker
they actually use. `review_label` isn't part of the detached config
shape at all (see the Configuration flow in either Chisel SKILL.md) —
there is no pre-work review gate to model.

L9 re-applies `review_label` after L3 removed it, with a new meaning on top
of "not yet triaged": the Reven loop could not approve the PR, so a human must
look. The PR stays open and `in_review` stays. The label is removed again by
the human, or by L6 on merge. A later `review` (L3) re-run on such an issue
would strip it, but Ralph never re-runs `review` for an issue it has reviewed.

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
- **Batch discovery skips `blocked`.** Ralph's no-ID batch (scoped to one
  parent's sub-issues via `--parent`) excludes issues carrying `blocked`,
  so escalated work does not re-enter the next run; naming the issue
  explicitly overrides it.
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

- `claude/hooks/squad-labels.sh` — performs rows L1-L4, L9 and D.
- `scripts/test-squad-labels.sh` — one named test group per script-performed row.
- `claude/skills/chisel/SKILL.md`, `claude/agents/cody.md`,
  `claude/skills/ralph/SKILL.md` — invoke the script for their steps.
- `.github/workflows/issue-lifecycle.yml` — clears all three
  `state_labels` plus `review_label` on merge, and clears `in_review` on
  a non-merge PR close.

The Codex distribution was dropped on 2026-08-21 (#148), so the
asymmetries this file previously recorded between the two trees no
longer exist — `claude/` is the only tree.
