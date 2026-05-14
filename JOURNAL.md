# Agent Squad — Design Journal

*From first sketch to MVP and final architecture*

Giorgio Galassi | 2025

---

## 1. Introduction

This document traces the full design process of the Agent Squad: a personal multi-agent development workflow built on Claude Code. It records every major decision, the reasoning behind it, the trade-offs accepted, and the problems that were found and resolved along the way.

The goal is not just to document the final architecture, but to preserve the thinking that produced it, so that future iterations have a clear foundation to build on.

---

## 2. Design Iterations

### Iteration 1: Initial Squad Definition

The starting point was a list of six roles that map directly to the stages of a software development cycle:

- **Archy**: architecture and solution design
- **Cody**: code writing in TDD mode
- **Qugh**: manual QA testing, separate from TDD
- **Reven**: code review
- **Oak**: documentation, kept updated throughout development
- **Sentry**: the watch tower orchestrating all others

> **Key decision:** keep one coding agent rather than splitting UI and logic agents. A single agent with modes preserves context coherence and allows reasoning about how logic impacts UI.

---

### Iteration 2: Adding Scout and Forge

Two critical gaps emerged: agents had no project context (they would start blind), and there was no structured brainstorming step before development began.

Scout was introduced as a context-snapshot skill, not an agent, because it performs a deterministic task: read the project structure and produce a compressed summary. No reasoning required.

Forge was introduced as a brainstorming skill to surface use cases, edge cases, and feasibility concerns before any code is written.

> **Key insight:** Scout does not need to be an agent. A skill is cheaper, faster, and more predictable for a purely mechanical task.

---

### Iteration 3: Formalizing the Flow

With the full squad defined, the orchestration flow was mapped for the first time. The sequence became:

1. You invoke `/forge`
2. Forge produces analysis
3. Sentry classifies severity
4. Archy (on HIGH) produces a PRD
5. Chisel converts PRD or analysis to Linear issues
6. Ralph loops Cody until the issue is resolved
7. Qugh and Reven review in parallel
8. Sentry reconciles feedback
9. Oak updates documentation

---

### Iteration 4: Severity Model

A three-level severity model was introduced to avoid applying the full pipeline to simple tasks:

| Severity | Criteria | Flow |
|----------|----------|------|
| **Low** | Isolated scope, no new dependencies | Forge (short) → Chisel (1 issue) → Ralph → Reven |
| **Medium** | New components within existing patterns | Forge → Chisel (N issues) → Ralph → Reven |
| **High** | New patterns, new dependencies, cross-module impact | Forge → Archy (Opus, PRD) → Chisel → Ralph → Reven |

---

### Iteration 5: Parallel Review and Agent Teams

Qugh and Reven were identified as naturally parallelizable: they work on the same PR independently, and their outputs are reconciled by Sentry afterward. Running them sequentially would add latency with no benefit.

The native `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` feature was chosen over third-party orchestrators to minimize external dependencies. The trade-off is that the feature is experimental, but failures will move toward greater stability rather than deprecation.

> **Key decision:** prefer native Claude Code primitives over third-party tools, even when experimental. External tools introduce an additional layer of dependency that may change on a different schedule.

---

### Iteration 6: Manual Review Gates

A validation exercise identified that without human checkpoints, errors in Archy output would silently propagate through Chisel to Ralph and Cody. Two explicit gates were added:

- **Gate 1:** PRD review before Chisel. The PRD is written to `.squad/prd/current.md` and you review it before invoking `/chisel`.
- **Gate 2:** Issues review before `/ralph`. You review the issues created in Linear before invoking Ralph.

Both gates are explicit commands, not passive notifications. Nothing proceeds until you act.

---

### Iteration 7: Oak Redesigned as a Daily Job

Running Oak after every single merge was identified as a noise problem: documentation would be updated for trivial fixes, producing low-value changes that made the docs harder to read over time.

Oak was redesigned as a daily job. It reads the full git log of the day, all merged PRs and closed issues, and updates documentation in a single coherent pass. This allows Oak to reason about multiple related changes together.

Oak is triggered via `/oak` or a cron schedule at end of day.

---

### Iteration 8: Forge Redesigned as Interactive Session

The original Forge was a skill that produced a document. This was insufficient because complex features require back-and-forth to surface hidden requirements. Forge was redesigned as an interactive session with:

- **Slot-based elicitation:** required slots (scope, acceptance criteria, constraints, edge cases) must be filled before Forge proposes to close.
- **Complexity field:** Forge produces a YAML output with a complexity field (low, medium, high) that you confirm before Sentry acts on it.
- **Adaptive behavior:** Forge asks fewer questions for simple inputs, more for complex ones. No flag required.

> **Key decision:** complexity classification belongs to Forge, not to a second Sentry pass. Forge has full session context; Sentry would need to re-read everything. One source of truth is cleaner.

---

### Iteration 9: Unified YAML Output from Forge

Chisel was receiving three different input formats depending on severity. This made Chisel fragile: a format change in any upstream step would break it silently.

Forge now always produces a structured YAML output regardless of complexity. Archy enriches this YAML into a full PRD only on HIGH. Chisel always receives the same format. The contract is stable.

| Severity | Chisel Input | Source |
|----------|-------------|--------|
| Low / Medium | YAML from Forge | Forge directly |
| High | PRD from Archy | YAML passed to Archy, enriched to PRD |

---

### Iteration 10: Context Optimization

Three strategies were established to keep token usage manageable as the project grows:

- Scout output is cached via Claude Code native prompt caching. Cache is invalidated only on structural changes, not on source file edits.
- `CLAUDE.md` is kept under 200 lines with only essential information. Skills are loaded on-demand (progressive disclosure), not preloaded.
- Two separate context files: `architecture.md` for agents, and `decisions.md` for you to consult on-demand.

> **Research finding:** progressive disclosure across skills recovers approximately 15,000 tokens per session compared to loading everything into CLAUDE.md upfront.

---

### Iteration 11: Workflow Data Directory (.squad/)

All workflow data files (architecture.md, scout-cache.md, forge output, PRDs, Chisel config) were moved from `.claude/` to a dedicated `.squad/` directory. The `.claude/` directory retains only Claude Code configuration: CLAUDE.md, agents/, and skills/.

This separation makes the workflow data tool-agnostic. Both Claude Code and Codex can read and write `.squad/` files without knowing about each other's config conventions.

> **Key decision:** `.squad/` is the workflow data directory. It contains only generated and consumed artifacts, never tool configuration. Skill definitions remain in tool-specific locations because their frontmatter formats require manual adaptation per tool.

---

### Iteration 12: Platform-Specific Distributions

The repository originally treated Claude Code as the canonical source and documented Codex as an adaptation layer. That stopped matching the implementation once the definitions diverged enough that they could no longer be maintained as one shared tree.

The repo was split into two first-class distributions:

- `claude/` for Claude Code skills, agents, and example entrypoint files
- `codex/` for Codex skills, agents, and example entrypoint files

Both trees preserve the same workflow semantics and write to the same `.squad/` runtime files, but they differ in definition format, install paths, and orchestration mechanics. Those differences are documented explicitly in `PLATFORM_DIFFERENCES.md`.

> **Key decision:** treat Claude and Codex as parallel implementations of the same workflow, not as one canonical implementation plus a thin port. Shared behavior lives in the journal and `.squad/` contract; platform-specific mechanics live in their own trees.

---

### Iteration 13: Second Brain and Lore

Three gaps in the MVP became apparent after sustained multi-project use:

1. **Cross-session amnesia** — each session started cold, with no
   memory of what was decided or where work stopped, especially when
   switching between Claude Code and Codex mid-day.

2. **Cross-tool gap** — Claude Code native auto-memory is inaccessible
   to Codex and vice versa. No shared layer existed for companions on
   different tools working the same project.

3. **Preference drift** — architectural preferences discovered during
   HIGH-complexity features had no home. They lived in project-specific
   decisions but never graduated to global cross-tool knowledge.

**Solution: Lore agent + second-brain vault**

A new `~/second-brain/` directory (outside any repo) serves as a
tool-agnostic vault. Both Claude Code and Codex read from and write
to it via Lore using direct file tools — no MCP, no daemon, no
external dependencies. The vault is plain markdown, readable in any
editor, visualizable in Obsidian without Obsidian needing to run
for Lore to function.

The vault contains four layers:

- `INDEX.md` — orientation entry point, overwritten by every
  `lore start`. An output, not something you maintain manually.
- `projects/<n>/status.md` — structured resumption handoff,
  overwritten each session end
- `preferences/development.md` — global cross-tool preferences,
  capped at 100 lines with a curation step
- `experiences/YYYY-MM/` — append-only session logs, typed
  (session/decision/feature/bugfix/discovery), never loaded by default

**Why Lore is an agent not a skill**

Memory management requires judgment: deciding what is worth writing,
when a local preference has become global, when to curate vs append.
Skills are for deterministic tasks. Lore is not deterministic.

**Why the vault is outside the repo**

The vault is personal and cross-project. Putting it inside any
project repo would pollute git history with personal memory entries
and couple a personal knowledge layer to a specific codebase.
Seed scaffolds the vault at first project initialization and writes
`.squad/lore-config.json` so all subsequent Lore invocations resolve
consistently.

**Why Lore diverges across platforms**

Claude Code has native auto-memory for project-local preferences.
Codex has no equivalent. Claude Lore defers project-local memory to
auto-memory and owns only the cross-tool layer. Codex Lore owns the
full stack. The user-facing interface (lore start, lore end,
lore prefer, lore recover) is identical across both platforms.

**Why no MCP**

Lore always knows exactly which file it needs. There is no search
problem to solve. Direct file reads are faster, cheaper, and have
zero manifest overhead. MCP servers for Obsidian preload tool
manifests of 7 to 1,212 tools on every request — cost without
benefit for Lore's access patterns.

**INDEX.md as output not input**

Early design treated INDEX.md as a file you maintain. Simulation
revealed this creates drift: the wrong project loads on session start
after a project switch. The fix was making INDEX.md a pure output —
every `lore start` deduces the project from git and overwrites
INDEX.md. You never touch it manually.

**Invocation is manual by design**

Automatic session-start triggers add complexity without proportionate
value. Manual invocation at natural boundaries is lower friction and
more reliable. The exception is the Cody incremental checkpoint —
written at PR open to ensure partial recovery is possible if the
session expires before `lore end`.

**Preference promotion discipline**

Preferences are only written to `development.md` via `lore prefer`,
called after a pattern has been validated by implementation — not
during planning. The trigger is Reven's APPROVED verdict on a HIGH
complexity feature. Planning reveals intent; merge validates it.

**Simulation findings**

Two simulation rounds identified five issues, all resolved:

1. Stale status body vs fresh Cody checkpoint — fixed by timestamp
   mismatch detection and inline recovery offer in lore start
2. No project argument on lore start — fixed by git-based deduction,
   INDEX.md always overwritten as a side effect
3. Session ends without lore end — fixed by recovery path and
   proactive offer when mismatch detected
4. Stale branch not detected — fixed by 7-day staleness check with
   lightweight git branch status
5. INDEX.md not reset after project switch — eliminated by making
   INDEX.md a pure output of lore start

**Community patterns incorporated**

- 100-line cap with periodic curation (file-based memory research)
- Filesystem-as-RAM mental model encoded in SQUAD.md
- Promotion rule: local → global only when pattern appears across
  2+ projects
- Type taxonomy on experience entries (session/decision/feature/
  bugfix/discovery) from claude-mem observation categorization
- <private> tag convention from claude-mem privacy control
- Instance namespacing for parallel sessions

**Context engineering patterns applied**

The vault read/write design maps to established context engineering
patterns:

- status.md as an anchored iterative summarization document —
  overwritten each session, never appended, compressed to ~400 tokens
- Context refs as JIT retrieval — files pre-selected at session end,
  auto-loaded at session start without prompting
- INDEX.md as index-first loading — one small file orients the
  companion before any content is loaded
- ACTION/CONTEXT signal markers in the Next section — minimal
  Context State Object eliminating prose parsing
- Compressed Done section preventing context rot from accumulated
  session history

The failure mode these patterns prevent is context rot — accumulated
stale content degrading companion orientation over time. The 400-token
cap on status.md and the compression discipline at lore end are the
primary defenses.

> **Promotion criterion:** when Sentry is active, Sentry calls
> `lore start` and `lore end` automatically at flow boundaries.
> Lore's internal behavior does not change — only who invokes it.

---

## 3. Final Architecture

### Squad Overview

| Name | Type | Model | Role |
|------|------|-------|------|
| **Scout** | Skill | n/a | Project context snapshot, cached, invalidated on structural changes |
| **Seed** | Skill | n/a | One-time project initialization. Produces `.squad/architecture.md` and `.squad/scout-cache.md`, ensures `.squad/` directories exist, and prepares shared runtime context. |
| **Forge** | Skill | n/a | Interactive brainstorming session, produces structured YAML with complexity field |
| **Chisel** | Skill | n/a | Converts YAML or PRD to Linear issues. Single input format, single output format |
| **Archy** | Skill | Opus or Sonnet | Architectural analysis, produces PRD from Forge YAML on HIGH complexity only |
| **Cody** | Agent | Sonnet | Assigns issue, creates branch, implements, opens PR. Invoked directly or by Ralph. |
| **Qugh** | Agent | Sonnet | QA behavioral testing, runs in parallel with Reven via Agent Teams |
| **Reven** | Agent | Sonnet | Code review, runs in parallel with Qugh via Agent Teams |
| **Lore** | Agent | Sonnet / gpt-5.4 | Second-brain memory: session orientation, status handoff, preference recording, git-based recovery. Filesystem only, no MCP. |
| **Oak** | Agent | Sonnet | Documentation, daily job reading full git log |
| **Ralph** | Loop | Sonnet | Agentic loop invoking Cody, max 3 retries, escalates on persistent failure |
| **Sentry** | Orchestrator | Sonnet | Reads complexity from YAML, routes to correct flow, reconciles feedback |

---

### Full Flow

```
0. /seed        Initialize .squad/ context files and directories. Run /clear after.
1. /forge       Interactive session → .squad/forge/output.yaml
2. Sentry       Reads complexity, routes accordingly
3. /archy       (HIGH only) Reads YAML → .squad/prd/current.md. You review.
4. /chisel      Reads YAML or PRD → creates Linear issues. You review.
5. /ralph       Invokes Cody per issue in dependency order, manages retries.
6. Cody         Assigns issue, creates branch, implements, opens PR.
7. Sentry       Spawns Qugh + Reven in parallel (Agent Teams).
8. Sentry       Reconciles feedback → merge or resume Cody loop.
9. /oak         End of day. Reads git log, updates documentation.
```

---

### File Structure

| File | Purpose |
|------|---------|
| `.squad/forge/output.yaml` | YAML produced by Forge. Read by Sentry, Chisel, and Archy. Overwritten each session. |
| `.squad/architecture.md` | Stack, patterns, conventions. Written by Seed. Read by Forge, Archy, Cody, Reven. |
| `.squad/scout-cache.md` | Project snapshot. Written by Seed. Replaced entirely on each Seed run. |
| `.squad/decisions.md` | Business assumptions and domain constraints. Read by you, not agents. |
| `.squad/prd/current.md` | Active PRD. Archived by Chisel after consumption. |
| `.squad/prd/archive/` | Past PRDs. Never loaded automatically. |
| `.squad/chisel-config.json` | Linear team, project, label, status. Written on first Chisel run. |
| `claude/CLAUDE.md.example` | Example Claude project entrypoint. Optional; not required by the workflow. |
| `claude/skills/` | Claude-specific skill definitions to copy into `~/.claude/skills/`. |
| `claude/agents/` | Claude-specific agent definitions to copy into `~/.claude/agents/`. |
| `codex/AGENTS.md.example` | Example Codex project entrypoint. Optional; not required by the workflow. |
| `codex/skills/` | Codex-specific skill definitions to copy into `~/.agents/skills/`. |
| `codex/agents/` | Codex-specific custom agent definitions to copy into `~/.codex/agents/`. |

---

## 4. MVP Configuration

### What is in the MVP

| Component | Role in MVP |
|-----------|-------------|
| **Forge** | Interactive session to structure your idea into YAML before any code is written. |
| **Archy** | Produces a full PRD on HIGH complexity. You review and iterate via `/archy` before proceeding. |
| **Chisel** | Converts YAML or PRD to Linear issues. You review issues before proceeding. |
| **Cody** | Writes code. Assigns the issue, creates a branch, implements, and opens the PR. |
| **Reven** | Reviews every PR. You invoke Reven manually after Cody opens the PR. |
| **Ralph** | Agentic loop. Invokes Cody per issue, manages retries (max 3), escalates on persistent failure. |
| **Seed** | Initializes project context. Run once per project, then again after significant structural changes. |
| **Lore** | Manages second-brain vault. Invoke manually at session start/end and via `lore prefer` after HIGH-complexity merges. |

### What is out of the MVP

- **Sentry:** the orchestrator. You handle routing manually. Add when the flow becomes complex enough to justify automation.
- **Qugh:** QA behavioral testing. You handle manual testing. Add when Reven alone misses behavioral issues.
- **Oak:** daily documentation job. Add when documentation starts drifting noticeably from the codebase.
- **Agent Teams:** parallel Qugh and Reven. Add when both are active.

### MVP Flow

```
/seed           Initialize context. /clear after.
/forge <idea>   Forge runs session, Scout provides context, you confirm complexity.
                → HIGH: /archy → review PRD → /chisel
                → LOW/MED: /chisel directly
/chisel         Creates Linear issues. You review.
/ralph          Loops Cody per issue in dependency order.
                Cody opens PR → you invoke Reven.
                Reven requests changes → feedback to Cody → repeat.
Merge.
```

---

## 5. Open Points

### 5.1 Sentry severity guardrail calibration

Sentry is configured to warn when a `/forge` description appears too complex for LOW severity. The threshold has never been tested against real inputs.

> **Action:** after two weeks of MVP usage, review how often the guardrail fires and whether it fires on cases that actually warranted escalation.

### 5.2 Forge slot completeness vs session length

Forge asks questions until all required slots are filled. On complex features this can produce long sessions. There is no mechanism to detect when the user wants to move faster.

> **Action:** monitor session length in practice. If sessions consistently run long, consider making some slots optional or adding a `/quick` modifier.

### 5.3 Chisel issue granularity

The granularity of issues produced by Chisel from a MEDIUM complexity YAML has not been validated.

> **Action:** after ten MED-complexity features, review issue size. Adjust Chisel prompting if Cody consistently asks clarifying questions or if issues feel trivially small.

### 5.4 Ralph retry criteria

The definition of a failed attempt has not been fully specified. Does a test failure count? A linting error?

> **Action:** define explicit failure criteria before relying on Ralph heavily. Proposed: build failure = retry, test failure = retry, type error = retry, infinite loop detected = escalate immediately.

### 5.5 decisions.md maintenance discipline

`decisions.md` value depends entirely on keeping it updated. There is no automated mechanism to prompt updates after significant decisions.

> **Action:** habit of updating `.squad/decisions.md` at the end of every HIGH-complexity feature. Consider an Oak prompt to suggest updates when it detects new patterns in merged PRDs.

### 5.6 Agent Teams experimental stability

`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is experimental. Its behavior, API, and token costs may change.

> **Action:** monitor Claude Code release notes before activating Qugh.

### 5.7 Oak documentation quality

Oak output quality depends heavily on commit message and PR description quality.

> **Action:** establish a commit message convention and PR description template before activating Oak.

### 5.8 Seed coverage of code-only conventions

Seed reads config files but not source files. Conventions that exist only in code will not appear in `architecture.md` after a Seed run.

> **Action:** after each `/seed` run, review `.squad/architecture.md` and manually add any conventions Seed missed.

### 5.9 PR assignment and branch protection

Cody opens PRs and Reven posts review comments using the same GitHub account (`gh` CLI auth). GitHub has no technical block on approving and merging your own PRs in this configuration.

The assumption breaks if branch protection rules require review from someone other than the PR author.

> **Action:** if branch protection with required external reviewers is added, evaluate whether a bot account for Cody is worth the overhead.

---

## 6. When to Add the Next Agent Layer

### Add Sentry when:
- You are routing tasks to agents manually and making the same routing decision repeatedly.
- Ralph is active and you need automated reconciliation of Qugh and Reven feedback.

> Sentry makes sense only after Ralph is well-established. Without Sentry, you are still the orchestrator for routing decisions.

### Add Qugh when:
- Reven approves PRs that later turn out to have behavioral bugs that tests did not catch.
- You are spending more than 15 minutes per PR on manual testing of UI or API behavior.

> Qugh is not a substitute for automated tests. Fix missing test coverage first.

### Add Oak when:
- `.squad/architecture.md` is drifting from the actual codebase and you are not updating it manually.
- New contributors (or future you) are confused by outdated documentation more than once per month.

> Oak is not worth the token cost if documentation quality is already acceptable.

### Re-run Seed when:
- You add a new major dependency that changes how code is written.
- You change framework or restructure the top-level folder layout.
- Cody or Reven start making assumptions that contradict your actual stack.

### Add Agent Teams (parallel Qugh and Reven) when:
- Both Qugh and Reven are active and sequential execution is adding more than 20 minutes of latency per PR.
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` has reached a stable state.

> Do not activate Agent Teams until both Qugh and Reven are individually calibrated.

---

## 7. Skill and Agent Definitions

Canonical definitions live in the platform-specific trees of this repository:

```
claude/
  skills/
    forge/SKILL.md
    archy/SKILL.md
    chisel/SKILL.md
    seed/SKILL.md
    ralph/SKILL.md
  agents/
    cody.md
    reven.md
codex/
  skills/
    forge/SKILL.md
    archy/SKILL.md
    chisel/SKILL.md
    seed/SKILL.md
    ralph/SKILL.md
  agents/
    cody.toml
    reven.toml
```

For exact format and behavior differences between the two trees, see `PLATFORM_DIFFERENCES.md`.
