# Agent Squad — Design Journal

*From first sketch to MVP and final architecture*

Giorgio Galassi | 2025–2026

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

- `claude/` for Claude Code skills and agents
- `codex/` for Codex skills and agents

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

**On "no dependencies" as a principle**

This is a heuristic, not a vow. The project already depends on Claude
Code, Codex, Linear, GitHub, git, gh, and jq. What it refuses is
dependencies whose cost exceeds their benefit for the current use
case: MCP (manifest overhead, no search problem to solve), agent
frameworks (a third runtime, tool-agnosticism lost), a daemon
(operational weight). Each was a specific cost-benefit call, re-run as
the inputs change, not a standing ban. The constraint also serves the
project's study purpose: building memory, orchestration, and recovery
from filesystem primitives is what produced the understanding the
constraint exists to teach. That value has a shelf life. As the
project's other purpose (shipping faster) starts to be taxed by
reimplementing infrastructure, the calculation tips. The honest
re-evaluation point is the same boundary as the framework question
(open point 5.10): at Sentry, with the harness need (5.11) as another
input. Stated as a rule: prefer primitives until a dependency's
benefit clearly exceeds its cost, re-evaluated at each major layer.
The failure mode to guard against is not impurity but substrate-churn:
swapping foundations before confirming the current one holds. Do not
adopt during validation.

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
- Filesystem-as-RAM mental model (context window = RAM, filesystem = disk)
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

### Iteration 14: Global Installation and Vault-First State

After sustained use it became clear that the squad-in-project model had three compounding problems:

1. **Noise** — squad files (skill definitions, `.squad/` directories, `lore-config.json`) appeared in `git status` of every host project, creating cognitive overhead and accidental commits.
2. **Duplication** — every new project required copying the same agent and skill definitions, meaning updates had to be propagated manually across all active projects.
3. **Config split** — `lore-config.json` lived inside `.squad/` in the project, coupling a user-level config to a per-project directory, while the vault it pointed to was outside every project. The config belonged with the vault, not with the project.

**Solution: global install + vault-first state**

Squad agents and skills now install once globally — `~/.claude/agents/` and `~/.claude/skills/` for Claude Code, `~/.codex/agents/` and `~/.agents/skills/` for Codex — and are immediately available in every project directory with no project-level files required.

All per-project operational state moves from `<project-root>/.squad/` to `<vault>/projects/<project-name>/.squad/`. The vault becomes the single source of truth for all squad memory. Host projects have zero squad footprint.

**`lore-config.json` redesign**

The config file moved from `<project>/.squad/lore-config.json` to `<vault>/lore-config.json`. The `vault_path` field was removed — it is redundant when the file is at the vault root. A new `projects` field maps absolute CWD paths to vault display names, replacing fragile basename-only derivation with an explicit, persistent mapping.

```json
{
  "projects": {
    "/absolute/path/to/project": "display-name"
  }
}
```

**Vault path resolution (simplified)**

With the config removed from projects, the vault path is resolved at runtime in two steps: `SECOND_BRAIN_PATH` env var if set, otherwise `~/second-brain/`. No stored config needed.

**Project name disambiguation**

On first encounter of a new CWD path, Lore derives the candidate name from `git rev-parse --show-toplevel` basename, checks whether a vault directory with that name already exists, and either creates it silently (no conflict) or prompts once for a display name (conflict). The CWD-to-name mapping is written to `lore-config.json` and never prompted again.

**Migration detection**

On `lore start`, if the current project has a `<project-root>/.squad/` directory and no vault mapping yet, Lore prompts once: "Found `.squad/` in this project. Move it to the vault? [Y/n]". On confirmation it moves the directory and removes the original. On decline it proceeds without migrating. No manual migration command required.

**Skill path resolution protocol**

All vault-aware skills (Forge, Archy, Chisel, Seed, Ralph) now share a common four-step resolution protocol at session start:
1. Vault path from `SECOND_BRAIN_PATH` or `~/second-brain/`
2. Project basename from `git rev-parse --show-toplevel`
3. Display name lookup from `<vault>/lore-config.json`
4. All `.squad/` paths resolve to `<vault>/projects/<display-name>/.squad/`

`Bash` is required in `allowed-tools` for any Claude skill that runs `git rev-parse`.

> **Key decision:** vault-first is absolute. No skill reads from `<project-root>/.squad/`. The vault is the only `.squad/` location, and the only path resolution that matters is the vault-relative one.

> **Post-merge correction (GG-18):** Reven reviewing main against the PRD found that `codex/agents/lore.toml` still wrote `session.log` to the project root (step 0, before vault resolution). The Claude version had been fixed correctly in GG-13. The Codex version required a follow-up fix to mirror the same deferral — writing to `<vault>/projects/<project-name>/.squad/session.log` after step 3 once the display name is resolved. This confirmed the value of running Reven against the full merged diff, not just individual PRs.

---

### Iteration 15: Decision Layer Correction and Contract Hardening

A full consistency review of the repository against its own design surfaced one architectural hole and several contract-level repairs.

**The decisions layer was structurally incomplete.** Claude Lore deferred project decisions to Claude Code auto-memory, which writes to `~/.claude/`, a location Codex cannot read. The consequence: decisions made during Claude Code sessions, the primary tool, never reached the vault's `decisions.md`. What was described as the cross-tool decisions log was in practice Codex-only. The fix reframes the relationship: auto-memory is a Claude-local cache, never the system of record. Both Lore variants now write vault `decisions.md` identically. The duplication cost is a few lines per session; the previous cost was a vault missing most of its decisions.

> **Key decision:** the vault is the system of record for anything that must survive a tool switch, even when a tool-native memory layer also captured it locally. Native memory is a cache.

**Contract hardening, in the same pass:**

- The vault path schema was unified to `<vault>/projects/<display-name>/.squad/` everywhere; half the definitions used a layout without the `projects/` segment, so files were written to one tree and read from another. the canonical schema is `<vault>/projects/<display-name>/.squad/`, restated inline in each self-contained definition (no single file is loaded at runtime to hold it).
- Cody and Reven received the path resolution protocol; both still read project-relative `.squad/` paths that stopped existing in Iteration 14.
- Seed no longer derives project names. It requires the `lore start` mapping in `lore-config.json` and stops if absent. Lore owns naming and conflict resolution; Seed consumes the mapping.
- Ralph's failure criteria were specified (open point 5.4): retryable vs immediate escalation vs not-a-failure, with identical consecutive errors escalating without burning remaining retries.
- The session log became fully instrumented: Forge, Archy, Chisel, Ralph, and Seed all append milestone lines, and `lore end` reads the log by default instead of requiring the path as an argument. The log is what survives `/clear` boundaries; a half-instrumented log was worse than none.
- `progress.txt` moved into the vault at `<vault>/projects/<name>/.squad/progress.txt`. Writing it to the project root violated the zero-footprint principle that Iteration 14 established.
- Chisel's input rule changed from "PRD produced in this session" (unverifiable after `/clear`) to pure existence: Chisel archives the PRD after consumption, so existence always means pending.
- Seed's `architecture.md` template gained a `## Data flow` section: collected data, storage and third parties, tracking and cookies, retention. Seed populates only evidence-backed candidates, marked `[unverified]`, and leaves the rest for manual completion. Archy and Reven consume it today; it is the designed input for a future Lex compliance agent, which was deliberately deferred with an explicit trigger in section 6 rather than built speculatively.
- The vault is recommended (not required) to be a private git repository: it is the single point of failure for all cross-project memory, and a repo adds history, backup, and multi-machine sync. When the repo exists, `lore end` and `lore recover` commit after their confirmed writes, commit only, never push: a backup that depends on remembering to commit reproduces the same human failure mode as forgetting `lore end`. `lore start` also refuses to register the vault itself as a project when a session is opened inside it.

---

### Iteration 16: Detached Tracker Mode and Trust Domains

The first attempt to use the squad outside personal projects surfaced a constraint the MVP had silently baked in: the workflow assumed agents hold write access to the tracker (Linear MCP) and the forge (`gh`). In a work environment with Jira and Bitbucket, where agents must not hold write access to company tools and may have no API access at all, every integration point broke.

The fix repeated the move that made the workflow Claude/Codex agnostic: the contract was already in files, so the tracker was demoted from a dependency to an adapter. The squad's value lives in the thinking layers (Forge's discovery, Archy's PRDs, Chisel's decomposition discipline, Cody's loop, Reven's review, Lore's memory), which never touched the tracker. Only three points did: issue creation, status updates, PR opening. All three degrade to "agent produces the artifact, human performs the write", which is the human-in-the-loop principle applied at a harder trust boundary.

**Design:** `chisel.mode` in `chisel-config.json` selects `connected` (previous behavior, default for backward compatibility) or `detached`. In detached mode Chisel writes a batch file with sequential local IDs (`SQ-1`, ...), the same `Blocked by:` dependency format, an optional local-to-tracker key mapping table, and a Jira-importable CSV alongside. Ralph executes from the batch file as the source of truth and converts every tracker action into a checklist line in a handoff file the user replays manually; the tracker becomes a company-facing mirror, the vault stays the operational truth. Cody skips the claim step, commits locally without pushing, and prints a paste-ready PR description. Reven diffs the local branch. Forge, Archy, Seed, and Lore are byte-identical across modes.

**Rejected alternative for the work vault:** a gitignored `work/` subdirectory inside the personal vault. Rejected for failing in both directions: the ignored side loses all the git protection Iteration 15 added, and the vault's global files defeat the isolation by construction, since `lore start` writes the active project name into INDEX.md and `lore prefer` writes into development.md, both committed and pushed to the personal remote. The adopted rule is one vault per trust domain, selected per context via `SECOND_BRAIN_PATH`, which existed since Iteration 13 precisely to make vault location an environment concern.

> **Key decision:** external tools are adapters, never dependencies. Any integration the squad has must degrade to a file the agent writes and an action the human performs, because the trust boundary of the environment, not the capability of the agent, decides where writes happen.

A side effect worth recording: detached mode also covers tracker MCP outages on personal projects, so the adapter built for the most restrictive environment improved resilience in the least restrictive one.

---

### Iteration 17: Chat-Native Interaction Model

Real use surfaced that several interaction patterns were borrowed from a CLI mental model that does not fit a chat interface.

**The `lore start` naming collision.** `lore start` reads like a slash-command, but Lore is a subagent, and subagents are delegated to, not typed. A new session would fail to recognize `lore start` and report that lore is not a skill. The fix is a thin `/lore` skill wrapper (mirroring Ralph's relationship to Cody) whose only job is to delegate to the Lore agent with the subcommand. `/lore start`, `/lore end`, `/lore prefer`, `/lore recover` now resolve unambiguously. The wrapper does no work and owns no behavior; all logic stays in the agent. Codex needs no slash-command mechanic but gets a parallel skill for discovery.

**The "type done / press enter" friction.** Forge and Archy asked the user to type `done` to close a session, and Lore peppered the flow with `[Y/n]` prompts. In a chat there is no enter key, and a sentinel word costs a round-trip for no information. The deeper problem was that every confirmation looked identical, so the user could not tell a reversible write from a destructive one.

The fix is a two-tier confirmation convention, described inline in each affected definition since no shared file is loaded at runtime:

- **Tier 1, default-and-announce:** for reversible or low-stakes operations, state the action (show the content for a write) and proceed in the same turn; the user redirects by replying. Forge and Archy now close by default once required slots are filled, reopening only if the next message corrects or adds rather than accepts. Routine vault writes (status.md, INDEX.md, output.yaml, PRDs) are Tier 1, made safe to default by the vault-git history from Iteration 15.
- **Tier 2, wait-for-explicit-yes:** reserved for destructive or hard-to-verify operations: vault creation, project-name conflict resolution, overwriting a status.md the timestamp check flagged as stale, and recovery writes reconstructed from inferred evidence.

> **Key decision:** confirmation weight should track reversibility, not uniformity. The old model treated "is this YAML right?" and "create the vault?" identically; the tiers make low-stakes the silent default and reserve the interrupt for writes the user genuinely cannot undo or easily verify. Vault git is what makes most writes safely reversible, so Tier 1 is the rule and Tier 2 the exception.

---

### Iteration 18: Dependency-Aware Branching

The MVP gave every issue its own branch off main and opened a PR per issue. Real use, especially in detached mode, exposed this as wrong for decomposed features. When Chisel breaks one feature into an ordered `Blocked by:` chain, branch-per-issue produces N independent PRs against main for code that only makes sense together, and in detached mode the user, who opens the PRs manually, would have to re-derive the very ordering the dependency graph already encodes.

**Design:** Ralph already builds the `Blocked by:` graph to resolve execution order. A new Phase 1b reuses it to group issues by connected component. Each dependency chain becomes one feature branch named after its lead issue, with each issue committed sequentially as its own commit, and a single PR opened after the chain's last issue. Independent issues (no edges to other in-batch issues) keep their own branch and PR, because they genuinely are independent and stacking them would invent an ordering that does not exist.

Ralph passes each Cody invocation a `branch`, `base`, `branch action` (create vs continue), and `open pr` (yes only for the last issue on a branch). Cody checks out rather than recreates a continuing branch, commits every issue, and opens a PR only when told, with `--base` always set so a stacked branch never targets main by accident. Ralph's success handling now distinguishes a committed-only issue (non-last in a chain, left In Progress) from one that closes a branch (moves every issue on that branch to In Review, since one PR covers them all). The change is mode-independent: connected mode opens the PR, detached mode prints one paste-ready description covering the whole chain.

**Deferred:** splitting a large chain into a stack of dependent PRs (PR2 based on PR1, re-targeting each PR's base after the prior merges). This is a deliberate per-batch decision, not a default, and was deferred until Chisel's issue granularity is validated (open point 5.3). Building the stacking machinery before knowing whether chains grow large enough to need it would be the speculative work this project avoids elsewhere. The `--base` plumbing is in place so the mechanic can be added later without reworking Cody.

> **Key decision:** branch topology should mirror the dependency graph, not the issue count. One chain is one feature is one branch is one PR; independence on the graph is the only thing that justifies a separate branch. This keeps the human's manual steps in detached mode proportional to features, not to issues.

---

### Iteration 19: Removing the Unused Entrypoint and Reference Files

A review of the prompt surface asked what `claude/CLAUDE.md.example`, `codex/AGENTS.md.example`, and `SQUAD.md` were actually for. The answer was nothing, at runtime. Skills and agents are self-contained: each resolves its own paths and reads only the vault files it needs, and the README already states the workflow does not modify `CLAUDE.md` or `AGENTS.md`. The two example files existed only to inject "read SQUAD.md before acting" into a project entrypoint, a dependency the system does not have and a pattern Iteration 11 and 14 had already moved away from (CLAUDE.md stays minimal, carries no workflow logic). SQUAD.md itself was never loaded at runtime by any agent; it had drifted into being a second copy of material already in this journal and the README, and earlier patches had wrongly framed its canonical statements as an agent-facing contract when no agent reads them.

All three were removed. The canonical statements they carried (path schema, confirmation tiers, session-log contract, tracker modes, branching) live where they are actually enforced: inline in each self-contained definition, with their rationale in this journal. Nothing in the runtime depended on the deleted files; the only edits required were removing three dangling pointers (two example files, one "see SQUAD.md" note in Lore's rules, now stated inline).

> **Key decision:** documentation that claims to be loaded but is not is worse than no documentation, because it invites changes that have no effect and frames duplication as a single source of truth. The design history (this journal) and onboarding (README) are the two documents the project keeps; the definitions are self-describing, which is the property that let the files go.

---

### Iteration 20: SessionStart Auto-Orientation

Iteration 13 concluded that automatic session triggers add complexity without proportionate value and kept Lore invocation manual, with the lone exception of Cody's PR checkpoint for crash recovery. Hooks change that calculus for the read path specifically. Both Claude Code and Codex now expose a SessionStart hook whose stdout is injected into the session as context, which is a cheaper and more reliable way to orient than asking the model to remember to read the vault.

A read-only orientation script (`hooks/lore-orient.sh`, installed globally per tool) runs at session start. It resolves the vault and display name, prints the active project's status.md, and appends local evidence: current branch, recent commits, and the tails of progress.txt and session.log. It never writes, never blocks, and always exits zero, so a missing vault or a non-git directory degrades to silence rather than an error. The config mechanism differs by tool (Claude `settings.json`, Codex `config.toml`), documented in PLATFORM_DIFFERENCES; the script and its behavior are identical.

This deliberately automates only the read half of Lore. `lore start` remains the write and setup path: first-time naming, conflict resolution, migration, session-log reset, and the INDEX active-project update, none of which a read-only hook can or should do. The write path stays manual for the same reason `lore end` does not move to SessionEnd: SessionEnd cannot pause to confirm, which collides with the Tier 2 confirmation that vault overwrites require, and a script cannot do the synthesis a handoff needs.

The script injecting status.md alongside fresh git evidence is the read half of a reconstruction-first model. Because the durable evidence (commits, branches, progress.txt, session.log, Cody's checkpoints) is already on disk during the session, orientation survives a session that ended without `lore end`: the model reconciles a possibly-stale status.md against the evidence, and `lore recover` rebuilds it on demand. This is the groundwork for demoting `lore end` from a required ritual to optional polish, with the one residue that evidence cannot reconstruct being the substance of pure planning or decision sessions that leave no git trace.

> **Key decision:** automate the read path, keep the write path manual. Hooks make orientation deterministic and free, which is pure upside for a read-only inject. Writes stay behind explicit invocation because they need confirmation (Tier 2) and synthesis (a model), neither of which a SessionEnd hook provides.

---

### Iteration 21: Reconstruction-First Memory, Removing lore end

`lore end` was the one squad step that depended on memory rather than habit: it had to be run, and it required confirmation, and skipping it (which happened) left the vault stale. The question was whether anything it did could not be obtained another way. Working through it: status.md is reconstructable from durable evidence, decisions.md is already written by `lore prefer` at merge, the INDEX active-project update already happens on `lore start`, and every skill already persists its own artifact (Forge writes output.yaml, Archy the PRD). The only output unique to `lore end` was the `experiences/` narrative log, which by its Iteration 13 design is never loaded by default and has no retrieval path. Against the agent-memory literature, an episodic log earns its place only when it is queried; a write-only archive with no recall loop is storage without the mechanism that creates episodic value, and the recall-worthy substance already lives in commits, PRs, decisions.md, the Forge YAML, PRD alternatives sections, and this journal.

So `lore end` was removed entirely, and status.md became reconstruction-first. `lore start` now rebuilds status.md from evidence (git log, branch, progress.txt, session.log tails, Cody's checkpoint) when it is missing or stale, instead of trusting a possibly-old body, preserving the human-stated `## Blocked` section across the rebuild since it is not derivable from git. `lore recover` is retained as the explicit, careful form of the same reconstruction, folding in PR descriptions and confirming before writing. The status.md schema, previously owned by `lore end`, moved to a shared section both paths reference. A shared "Vault commit" rule replaced the per-section commit blocks, so `lore start`, `lore prefer`, and `lore recover` all commit after writing. The `experiences/` mechanism was deleted, including Seed's scaffolding of the directory.

What this costs: a session that produces no commit, no decision, and no artifact, the pure-discovery case, now leaves no trace. For a solo developer that residue is acceptable, and `lore prefer` or a one-line decisions.md note captures it when it matters. What it buys: the vault stays current with zero end-of-session ritual. Combined with Iteration 20's SessionStart hook, the full loop now keeps memory live through durable artifacts written during work and reconstruction at the next start, with no command to forget.

> **Key decision:** a memory step that depends on being remembered is a bug. Move the synthesis to where it is needed (session start, by reconstruction) rather than where it is easily skipped (session end, by ritual). Persist durable evidence continuously; rebuild the summary cache on demand. Delete the archival log that nothing reads rather than automate writing it.

The user-facing command surface is now `lore start`, `lore prefer`, `lore recover`. The `/lore` wrapper and both agent definitions were updated to match.

---

### Iteration 22: Sidecar — Worktree-Backed Fix Sessions

Sustained use surfaced a gap the MVP flow had no answer for: "this UI
piece is wrong" on a branch that already exists. The only available path
was re-running the full pipeline — Forge for a discovery session that had
nothing left to discover, Chisel to explain the fix wasn't a new tracked
issue but belonged on a specific branch, then Ralph again — or bypassing
the squad entirely and talking straight to the codebase. The first option
is ceremony sized for a batch of tracker issues, paid in full for a
one-line change. The second is faster but leaves nothing in the vault:
no evidence of the work, breaking the premise the whole second-brain
layer is built on.

Two designs were considered before landing on the final one. The first
kept the same skill sequence but had Ralph itself hold a branch open
after execution so the user could return to it. This was rejected: it
would have bent Ralph's contract — dependency graph, retry/escalation
counters, batch reporting — around a case that needs none of that, and
"batch mode" versus "someone is now typing at me interactively" would
have become two behaviors wearing one name. The second, adopted design is
a new, small companion skill, Sidecar, that sits next to Ralph rather
than inside it and requires an existing branch as its only input.

Sidecar takes a branch name, resolves its base (from an open PR if one
exists, else the last progress.txt mention, else `main`), and opens a
`git worktree` for it inside the project directory — not in the vault.
This is a deliberate, narrow exception to the zero-footprint principle
from Iteration 14: a worktree is a real, disposable working copy needed
to run and test the branch, not squad state, so it does not belong in
`~/second-brain/` and does not violate the rule that host projects carry
zero squad footprint. It is git-ignored in the host project and removed
when the session closes.

Orientation reads the diff against the resolved base, not a full re-read
of prior planning docs — progress.txt is a terse Ralph log and the
original Chisel batch reflects intent, not what actually shipped; the
diff is ground truth, and Cody is instructed to read the PR body or
progress.txt itself, on demand, only if the diff doesn't explain enough
for a given fix. Each fix the user describes becomes one Cody invocation
in the worktree (`branch action: continue`, `open pr: no`), mirroring how
Ralph already invokes Cody per issue rather than inventing an open-ended
persistent chat session — Cody keeps its existing `maxTurns` contract
unchanged. A single `working_directory` field was added to Cody's own
definition (both trees) so it runs its git and shell commands inside the
worktree instead of the resolved project root, and skips the branch
checkout step entirely: the worktree is already on the right branch by
construction, and checking out something else inside it would corrupt it.

The evidence problem is solved by writing at teardown, not per turn.
Cody still writes only its usual single `status.md` checkpoint, at PR
open — no change to that contract. Sidecar itself, mirroring Ralph's
existing division of responsibility (Ralph writes progress.txt, not
Cody), appends exactly one line summarizing the whole session, not one
per fix: at this stage the issues are small enough that a session-level
summary is sufficient, and a line per chat turn would flood
`progress.txt` with noise Ralph's own batches never produce. Reven is
never invoked automatically — consistent with how it is invoked
everywhere else in the squad, manually, when the user is ready.

> **Key decision:** a workspace artifact is not automatically a
> zero-footprint violation — the rule is about squad *state*, not about
> ordinary git mechanics. A worktree is scoped, disposable, and
> git-ignored, so it can live inside the project without compromising the
> principle that state belongs in the vault. Separately: when a new
> interaction pattern doesn't fit an existing skill's contract, add a
> sibling skill rather than growing the existing one two behaviors deep.

**Addendum — worktree path convention:** the first draft placed worktrees
at `.worktrees/` on both trees, a Sidecar-invented path. Checking against
Claude Code's own documentation before shipping surfaced that
`.claude/worktrees/<name>/` is already Claude Code's native default for
`--worktree`, `EnterWorktree`, and subagent `isolation: worktree`, and
its own docs explicitly recommend git-ignoring exactly that path. Sidecar
was moved to match it: `.claude/worktrees/` on the Claude tree, so it
lands where Claude Code users already expect worktree content (and often
where it's already git-ignored), and `.codex/worktrees/` on the Codex
tree for consistency between distributions — noted as a parity choice,
not a confirmed native Codex convention, since no equivalent documented
default was found there. A second design question this raised — whether
Sidecar should delegate to Claude Code's native `EnterWorktree` tool or
`isolation: worktree` subagent frontmatter instead of hand-rolled `git
worktree` commands — was deliberately not taken: both are Claude-only,
and adopting either would widen the Claude/Codex behavioral gap beyond
the "delegation mechanism only" difference the rest of the squad holds
to (see `PLATFORM_DIFFERENCES.md`). Sidecar keeps portable git commands
on both trees; revisit only if Codex ships an equivalent native primitive.

---

### Iteration 23: Path Resolution Broke Inside Worktrees

Every skill and agent resolves which vault project it's talking to from
`git rev-parse --show-toplevel`, then looks that path up in
`lore-config.json`'s `projects` map, or falls back to its basename as the
project name. That protocol predates Sidecar and was never re-examined
against it. It's wrong inside a linked worktree, and the wrongness is
silent, not a crash.

Verified directly rather than assumed: a small throwaway repo with one
linked worktree showed `--show-toplevel` returning the *linked worktree's
own* directory, not the main repository's — different absolute path,
different basename. Since every skill's vault lookup is keyed on exactly
that path, a skill invoked from inside a Sidecar worktree would miss the
`lore-config.json` mapping entirely. Seed's own protocol names the
failure mode: *"No vault mapping found for this project."* Worse, several
skills fall back to the CWD basename when the mapping misses, so
`progress.txt`, `architecture.md`, `chisel-config.json` — the whole
`.squad/` tree — would silently read from and write to a namespace named
after the *branch* instead of the project, fragmenting the evidence trail
Sidecar exists to preserve. The bug sat exactly at the seam between two
things built independently: the path protocol assumed one working
directory per project, and Sidecar's whole premise is more than one.

The fix, also verified directly rather than assumed: `git rev-parse
--path-format=absolute --git-common-dir` returns the *main* repository's
`.git` directory regardless of which worktree it runs from — confirmed
identical output from both the main checkout and the linked worktree in
the same test repo. The project root is the parent of that path, correct
uniformly, no conditional branching on "am I in a worktree" required.
This is a native git primitive, not a Sidecar-specific convention, so it
holds for worktrees created outside Sidecar's own naming scheme too.
`--path-format=absolute` needs git 2.31+; every site falls back to plain
`--show-toplevel` if the command fails, matching the project's existing
degrade-gracefully convention (Seed already does this for missing files).

The fix touches every skill and agent — 18 files across both trees, plus
the two `lore-orient.sh` hooks, which needed the real shell logic
patched, not just prose, since they run unattended at SessionStart.
Rather than edit 18 near-identical copies from memory, `PATH_RESOLUTION.md`
was added at the repo root as the algorithm's single canonical source —
with one explicit condition attached to it: it is never read at runtime
by any skill or agent. Iteration 19 deliberately removed the squad's
shared runtime-context files on the grounds that nothing in the runtime
depended on them, and that principle isn't reversed here. `PATH_RESOLUTION.md`
is a maintainer's reference, not a preload; the fix still lives, inlined
and verbatim, in every skill's own "Path resolution protocol" section,
exactly as the architecture requires. Grepping both trees for
`--path-format=absolute --git-common-dir` after this change confirmed
all 18 files plus both hooks carry the identical fix.

> **Key decision:** a single canonical source and a self-contained
> runtime are not in tension — the tension only exists if the canonical
> source gets loaded. Keeping `PATH_RESOLUTION.md` maintainer-only and
> propagating its text by hand (or by a future lint script diffing
> against it) gets the "one place to update" property the multiplying
> file count demanded, without reopening the shared-runtime-file question
> Iteration 19 already settled.

**Addendum — a script, not a skill:** hand-propagating the fix across 18
files raised an obvious follow-up: could a dedicated "orientation skill"
that every other skill invokes replace the copy-paste entirely? Tempting,
and rejected, for a reason more specific than Iteration 19's general
principle. Skills have no return-value semantics — "invoke the orient
skill" means loading its prose into context and hoping the model acts on
it before continuing, not a function call with a result handed back.
Nothing enforces that a three-line deterministic computation actually
gets delegated rather than pattern-matched inline from training data, and
even when it is invoked, it costs a full skill-load (frontmatter, trigger
matching, the works) for a `git rev-parse` and a `jq` lookup. That is
the same soft, easily-skipped dependency Iteration 19 removed, just
relocated rather than eliminated.

A shared *script* has none of that ambiguity, and the project already had
a working precedent for one: `lore-orient.sh`, real shared logic every
session already runs at `SessionStart`, not prose copied per-file. So
`path-resolve.sh` was added at `claude/hooks/` and `codex/hooks/` —
resolves `VAULT_PATH`, `PROJECT_ROOT`, `DISPLAY_NAME` via the
`git-common-dir` fix above, prints three `KEY=VALUE` lines, nothing else.
Deliberately mechanism only, not policy: what a skill does with an empty
`DISPLAY_NAME` still varies (Seed stops, most others fall back to a
basename, Lore creates the mapping) and stays inline, per skill, exactly
as before. Every one of the 18 files' path resolution protocol was
rewritten to call the script as step one instead of re-deriving the
algorithm; `PATH_RESOLUTION.md` now documents the script's algorithm and
rationale rather than holding text to be copied, and is itself still
never read at runtime by anything — only the script is. `path-resolve.sh`
also absorbed `lore-orient.sh`'s own inline copy of the same resolution
logic (with a defensive inline fallback if it's ever missing), so the
hook stopped carrying a third copy of an algorithm now implemented once.

One more bug surfaced while wiring this in, caught by testing rather than
assuming the refactor was safe: `lore-orient.sh`'s evidence section
reported `Branch:` and `Recent commits:` via `git -C "$ROOT"`, where
`$ROOT` was about to become *always* the main project root. Fine before
worktrees existed; wrong now, since a session orienting from inside a
Sidecar worktree would report the main checkout's branch instead of its
own. Fixed by dropping `-C "$ROOT"` from those two calls so they use the
ambient working directory — the vault lookup needs the recovered project
root, but evidence should reflect wherever the session actually is.

> **Key decision:** the deciding factor between "shared skill" and
> "shared script" isn't purity, it's whether the runtime can be trusted
> to actually use the shared thing. A script is something every skill
> already unconditionally executes as an ordinary Bash step; a sibling
> skill is something a model may or may not choose to invoke. Route
> mechanism through whichever one the runtime can't accidentally skip.

---

### Iteration 24: Dropping the Codex Distribution

Iteration 12 committed to two parallel trees — `claude/` and `codex/` —
on the theory that they were "parallel implementations of the same
workflow," not one canonical tree plus a thin port. In practice, parity
was maintained by prose discipline (grep both trees, mirror every
change) rather than anything mechanical, and it slipped. By the time
this decision landed, the `codex/` tree carried real, unfixed defects
tracked as separate issues — NEW-15 and NEW-18a/b/c in its Sidecar
skill, a missing path-resolution protocol in its Reven skill (Iteration
23's fix never reached it), and stale `tracker:` selectors in its Ralph
skill. Those defects, and the issues describing them (#121–#128), were
never implemented; they were deliberately sequenced last in a Ralph
batch specifically so they could be cancelled outright if this decision
landed, rather than fixed in a tree about to be deleted.

On 2026-08-21 the repository owner decided to drop Codex as a supported
platform and maintain Claude Code only (#148). The rationale: dual
distribution never paid for itself. Codex was actually used far less
than Claude Code, so its tree accumulated drift and unfixed defects
between the rare sessions that touched it, while every Claude-side
change still carried the tax of "did I remember to mirror this" —
exactly the soft, easily-skipped-dependency failure mode Iteration 19
rejected for in-session prose, just relocated to cross-session
maintenance discipline instead of eliminated. A tree nobody was
reliably keeping in parity was providing the appearance of portability
without the substance of it.

The fix is a straight deletion, worked outward from the tree itself:
`codex/` is gone, along with every document that assumed its existence
— `CLAUDE.md`'s "Squad Distribution" mandate to mirror every change and
grep both trees, `README.md`'s Codex install instructions and repo-tree
entries, `PATH_RESOLUTION.md`'s Codex hook paths and dual-tree file
list, and the Codex install commands in `PLATFORM_DIFFERENCES.md`
itself. `PLATFORM_DIFFERENCES.md` — whose entire subject was the
claude-vs-codex comparison — is kept rather than deleted outright, but
reduced to a short historical pointer at git history for anyone who
needs the detailed comparison later; deleting it outright would have
orphaned the several other documents (including this journal) that
still reference it by name, and a pointer costs nothing to maintain
going forward. This entry is that record: unlike `PLATFORM_DIFFERENCES.md`,
this journal is never rewritten to erase what Iteration 12 through 23
actually did — Codex existed, had a real design rationale, and is being
retired deliberately, not quietly.

> **Key decision:** parity discipline maintained by prose instruction
> across two trees is the same category of soft dependency this journal
> has rejected in every other context (shared skill preloads in
> Iteration 19, a shared orient-skill in Iteration 23's addendum). The
> fix there was routing mechanism through something the runtime cannot
> skip. Here, with no shared runtime primitive available to make
> cross-tree parity mechanical, the fix is to stop needing it: one tree,
> reliably maintained, beats two trees where only one is.

---

### Iteration 25: Challenge — Stress-Testing Before Committing

Both Forge and ad-hoc conversation had a gap: a plan or a piece of
writing could go straight from proposed to acted-on with no adversarial
pass in between. Reven reviews code after it is written; nothing
pushed back on an idea before that. Challenge (#153) fills that gap as
a pair — a stateless `challenge` agent plus a thin `/challenge` skill —
rather than a single component, for the same reason Lore's start
skill is a thin wrapper around the Lore agent: an agent invoked via
`Task` returns a structured result the caller can act on, while loading
another skill's prose into context has no return-value semantics (the
soft-dependency failure mode Iteration 19 already rejected). The skill's
one job is assembling a self-contained brief — Challenge cannot see the
caller's conversation, so nothing not put in the brief exists for it.

**Explicit-ask triggers only.** `/challenge` fires on a direct ask —
"challenge this," "push back," "poke holes," "what do you think about
it?" — never automatically on every plan or draft. An agent that
second-guesses unprompted is friction, not judgment; the user decides
when a proposal is worth stress-testing.

**Challenge first, hold.** When a request bundles a change with a
challenge ask ("split slides 4–6 into two sections, what do you
think?"), the skill shows the challenge result and waits rather than
applying the change first and asking after the fact — a challenge that
runs after the fact cannot change the outcome. An explicit override
("just do it") ends the discussion without re-litigating.

**Web search only for checkable claims.** Challenge searches when a
point rests on a checkable factual or empirical claim (a statistic, a
library's documented behavior, precedent), and cites a source for every
claim it treats as evidence. It never searches to challenge a
taste-based point — tone, structure, wording — since those have no
factual answer to look up; an empty or contradictory search is reported
as unverified, never quietly dropped or fabricated.

**Model and scope.** Challenge runs on `opus`, consistent with Archy's
similarly judgment-heavy architectural analysis, not the `sonnet` used
by execution-focused agents like Cody. It is deliberately scoped as
non-development-agnostic: the brief format (proposal, goal, excerpt)
and the four angles (counter-arguments, probing questions, pre-mortem,
alternatives) apply identically to a code change, a PRD, or a speech
draft, so the same agent serves `/challenge` standalone and Forge's
challenge step without a code-specific mode.

**Stateless by design.** Like the `challenge` agent it wraps, the skill
never runs `path-resolve.sh` and never touches the vault or `.squad/`
state — every invocation is a self-contained brief in, a structured
verdict out, with no record kept that a challenge happened. This keeps
`/challenge` usable from any directory, squad project or not, with
nothing to reconcile or clean up later. A challenge history is a
deliberate future addition if a project ever wants one, not an implicit
side effect of this design.

**Forge integration.** `/forge` now always runs a challenge step before
a draft scope closes — via `Task`, never by loading the skill's prose —
with no `--no-challenge` escape hatch: the cost of one extra round is
small next to the cost of chiseling a weak plan into issues. The
challenge round is an ordinary Forge round for every other purpose
(the user can still revise scope in response to it); it is a required
gate, not a follow-up.

> **Key decision:** an agent-plus-thin-skill pair for return-value
> semantics, explicit-ask triggers rather than automatic invocation,
> challenge-first-and-hold over challenge-after-applying, web search
> reserved for checkable claims only, `opus` for judgment quality, and
> full statelessness so the same agent serves standalone use and the
> Forge gate without a vault dependency.

---

### Iteration 26: Moving the Forge Challenge to the Opening

A real session (visual-check planning) showed the pre-close challenge
step from Iteration 25 landing too late: it overturned two round-1
answers and burned the last of the four rounds, leaving eight findings
stranded in `open_questions` with no round left to resolve them through
questions. A standalone `/challenge` run on the same raw idea, done
before any rounds started, had already surfaced nearly all the same
material. The value of a challenge is in shaping the questions the user
answers, not in critiquing a plan that is already fully baked; putting
it before the rounds lets its findings become part of the questions
themselves instead of a rushed extra round competing for a shrinking
cap.

**Opening challenge, plus a lighter delta check.** `/forge` now
delegates to the `challenge` agent twice instead of once: an **opening
challenge** on the user's raw input, right after reading
`architecture.md` and before any question is asked, and a **delta
check** right before the close gate, scoped only to decisions made
during the rounds that were not in the raw input (for example, a
credentials-in-vault issue that only surfaces once the rounds get
there). The delta check is deliberately thin — no `AskUserQuestion`
call, no reopening of an earlier answer — because by that point the
user has already committed to those decisions; its findings go straight
to `open_questions` and `notes` for Cody or Archy to see.

**Findings attach to questions, they don't become questions.** The
opening challenge's findings are held, keyed to the question they bear
on, and fold into that question's options once the question dependency
protocol determines it is a root — never asked as separate bolted-on
questions of their own. This keeps the two mechanisms cleanly layered:
the dependency protocol still decides which questions are roots; the
challenge only decides what a root's options look like once it is one.
A `reconsider` verdict is the one exception that creates a question
outright — a proposal judged not to serve the goal needs a root
question on its direction regardless of what else is open. Ordering
under `AskUserQuestion`'s four-question limit puts `reconsider`-derived
questions first, then required-slot-changing findings, then the rest;
overflow waits for the next round as an ordinary root rather than being
dropped to `open_questions`.

**Neither step counts toward the round cap.** The four-round cap and
the session log's `rounds` count still mean exactly what they meant
before — the number of `AskUserQuestion` calls — so a fully-specified
input can still close with `rounds: 0` even with the opening challenge
run in full (the delta check has nothing to examine then and is
skipped).

**Trivial-input skip, defined concretely.** Iteration 25 had no
skip at all; this iteration adds one, scoped narrowly: the input names a
single file or module, introduces no new dependency, requires no
design or architectural decision, and every required slot's value is
already stated or trivially inferable from the input. All four must
hold, not just a subjective "looks simple" — a wrong call is visible in
`notes` (`challenge skipped: trivial input`) so the reader can run
`/challenge` manually if the skip turns out to have been wrong. There is
still no user-facing `--no-challenge` flag; this is Forge's own
heuristic, not an escape hatch the user can reach for.

**`--trace` prints attachment, not just rounds and holds.** Since
`--trace` already exists to make the dependency protocol's reasoning
visible rather than silently correct, extending it to print which held
finding attached to which question (`attached: <finding> → <question>`)
was the consistent choice — the alternative (leaving attachment
invisible even in trace mode) would have made the one part of this
change most likely to look wrong in practice the one part `--trace`
couldn't show.

> **Key decision:** challenge moves from a single pre-close gate to an
> opening challenge plus a lighter pre-close delta check; challenge
> findings attach to questions rather than spawning their own; a
> concretely-worded trivial-input skip replaces the old
> always-runs-no-matter-what stance; and `--trace` reports finding
> attachment for the same transparency reason it already reports rounds
> and holds.

---

### Iteration 27: Shrinking Sidecar to Open and Close

Sidecar ran twice against 27 Forge and 18 Ralph runs. Its worktree and
dependency mechanics proved valuable (native worktrees do not populate
`node_modules`), but the Cody-per-fix loop was the wrong granularity for
iterative fixes: three cold starts for "a bit more padding". In practice
the user opens a separate session per worktree, which already gives
session-level isolation while keeping the conversational thread.
Sub-agent isolation suits wide throwaway work, not conversation.

**Open and close only.** `/sidecar <branch>` keeps branch/base
resolution, `worktree.sh create` and `deps`, the staleness report, and
the orientation block, then stops. The automatic fix loop is gone;
"hand this to Cody" spawns Cody once with `working_directory`, `branch`,
`base`, `open pr: no`. Sync and teardown language are unchanged, but
with no Cody call to do it, Sidecar now commits, pushes, and opens the
PR itself at sync or close, and writes the `status.md` checkpoint. The
`progress.txt` line now counts commits instead of fixes. `worktree.sh`
is untouched.

> **Key decision:** Sidecar is a worktree opener and closer, not a fix
> loop; Cody is an explicit one-shot opt-in rather than the default
> per-fix executor.

---

### Iteration 28: Seed Owns First Contact

After #170 the SessionStart hook orients and the SessionEnd hook
rebuilds `status.md`, so `lore start` no longer earns a place in a
normal session. Yet docs and hook hints still presented it as the
opener, and Seed refused to run until it had recorded the vault mapping.

**Seed owns first contact.** Seed now resolves the display name with
Lore's rule (no conflict: silent; conflict: prompt once, default
`<name>-2`), creates `projects/<name>/`, and records the mapping in
`lore-config.json`. A legacy in-repo `.squad/` is not migrated by Seed;
it points to `lore start`. `lore start` keeps steps 1-6 (vault, naming,
session log, migration, INDEX) as setup and repair; reconstruction lives
in `lore recover`. `lore-orient.sh` says "run /seed" when the mapping is
missing and prints nothing about `lore start` otherwise. The auto-load of
`## Context refs` that `lore start` steps 7-11 used to do moved into
`lore-orient.sh` (read-only; 5 refs, 60 lines each, 2400 chars total).

> **Key decision:** keep the name `lore start`, no rename to `lore init`.
> A rename needs an alias release and touches every reference for a
> wording gain; the docs now say what it is for.

---

### Iteration 29: Deterministic script layer and two-tier harness

Three problems converged. The label state machine existed in three
hand-synced copies (the `LABEL_STATE_MACHINE.md` table, the agent prose,
and the lifecycle workflow), and every copy drifted at least once.
Prose procedures had already broken in Iteration 23, when a path rule
copied into many definitions behaved differently in a worktree. And the
only harness, `golden-check.sh`, was informational: it printed a diff and
gated nothing, so a regression surfaced in a live session instead of a
check.

**Design:** scripts are the pattern, and prose keeps only the call.
Batch 1a scoped the move to labels and branch create/continue so the
contract could be settled once on two small cases.

- *Mode by script, default detached.* `path-resolve.sh` gained a fifth
  line, `TRACKER_MODE`, which is `connected` only when `chisel.mode` is
  provably `connected`; a missing file, missing `jq` or any doubt yields
  `detached`. Mode is never a model-supplied flag, because detached is a
  privacy and safety property and a model must not be able to talk itself
  out of it.
- *One shared guard.* `squad-common.sh` holds `squad_gh_write`, the only
  mutating `gh` path, which refuses in detached mode, plus
  `squad_record_local`, `squad_emit` and `squad_fail`. `squad-labels.sh`
  (ensure, claim, review, escalate; `--handoff` for the detached line)
  makes zero `gh` calls in detached mode. `squad-branch.sh` (create,
  continue) makes none at all, works inside worktrees, and never uses
  `-f`, stash or reset.
- *Output contract.* `SCRIPT_CONTRACT.md` fixes stdout as `KEY=value`
  lines (`^[A-Z_]+=`), `OUTCOME` and `CHANGED` keys, exit codes 0, 2, 10
  and 20, no pass-through of `gh` or `git` codes, and idempotency. The
  detached happy path exits 0 with `OUTCOME=recorded-local` rather than a
  distinct non-zero code: a model reads non-zero as failure and reaches
  for raw `gh`, which is the exact behavior the guard exists to prevent.
- *Tier 1, a bash gate.* `scripts/gh-shim/gh` and
  `scripts/fixtures/make-fixture.sh` back `scripts/test-*.sh` (path
  resolve, gh shim, common, labels, branch, and three lint suites). They
  run with `/bin/bash` 3.2 through two workflows: `hook-tests.yml`
  (path-resolve, gh-shim, common, labels, branch, worktree) on ubuntu and
  macOS, and `squad-lint.yml` (lint, `test-squad-lint-gh.sh`,
  `test-squad-lint-labels.sh`, `test-squad-lint-hooks.sh`) on ubuntu
  only. They replace `golden-check.sh`, now deleted.
- *Lint as allowlist.* `squad-lint.sh` check 6 allows a fixed set of
  `gh` read forms (with `<!-- lint:gh-ok -->` for deliberate exceptions
  and `scripts/lint-allowlist-1b.txt` for entries tagged `retires: 1b`)
  rather than denying a list of write forms, since a denylist fails open
  on the next unknown write. Check 7 ties each `LABEL_STATE_MACHINE.md`
  row id (L1-L8, D) to a test name; check 8 verifies that every
  `~/.claude/hooks/*.sh` the prose references exists.
- *Tier 2, advisory evals.* `claude/evals/` holds three cases
  (connected claim, detached claim, worktree continue) graded by
  zero-cost checks, run by `plugin-eval.yml` on dispatch or a same-repo
  `eval` label with `--threshold 0`. `claude plugin eval` cannot be the
  gate: every run calls a real model (the CLI defaults to 3 runs times 2 arms;
  the repo configures neither, and the README invocation passes
  `--ablation none` for one arm),
  results are non-deterministic and graders cannot be custom. So bash
  gates and the evals report. Findings: the sandbox can write
  `$HOME/second-brain`, the `agent-squad:` plugin prefix is harmless, and
  the macOS `xcrun` git shim fails inside the eval sandbox.
- *Eval-only packaging.* `claude/.claude-plugin/plugin.json` is name-only
  with no `hooks.json`, so loading `claude/` as a plugin cannot double
  fire hooks next to the copy install. CI runs `claude plugin validate
  claude/` without `--strict`, because a name-only manifest warns (the
  #213 trade-off).
- *Fix-round outcomes.* `squad_gh_write` sends `gh` stdout to stderr so
  only `KEY=value` lines reach stdout; the contract also lists library
  return codes (`squad_record_local` 1 = unchanged, library-only).
- *Labels script hardening.* `squad-labels.sh` reads label names only from
  `chisel-config.json`, without `jq`; a missing config in connected mode is
  exit 20. `review`'s unchanged branch also requires `review_label` gone.
  `escalate` posts the comment before the label swap, so a retry may
  duplicate the comment but never loses it. `claim` while `blocked` is
  exit 10.
- *Branch base resolution.* `squad-branch.sh` resolves `origin/<base>`,
  then local `<base>`, and emits `BASE_REF`. Detached mode tolerates a
  missing `origin` or a failed fetch, so local-only stacks keep working;
  this is the detached-mode privacy property, the squad never needs a
  remote. Connected mode still exits 20 on fetch failure.
- *Ralph detached claim.* Ralph now has an explicit detached `claim` call
  site in Phase 2a.
- *Eval workflow.* `plugin-eval.yml` scopes the API key to the eval step,
  uses a concurrency group, and guards on the `labeled` event for the
  `eval` label; results are ignored via `claude/evals/.gitignore`. The
  detached-claim `handoff-line` grader is expected to fail until it is
  re-pointed at Ralph's handoff line.

Fixes: #233 made the `squad_emit` key check locale-safe on bash 3.2.

Known gap, documented rather than hidden: Cody's prose still skips the
claim in detached mode, although `squad-labels.sh claim --handoff`
exists; Ralph produces the detached In-Progress line at dispatch (Phase
2a). The detached-claim eval reports this until its grader is re-pointed. Also, `docs/flow.png` lags
`flow.html` (the golden-check node was removed in #213), and the
installed `~/.claude` copies must be re-synced after merge.

The batch was a linear stack of PRs (#222-#231) because the issue graph
had diamonds (#214 needed #211 and #212; #220 needed #213, #217 and
#219), and stacking each issue on its latest blocker would have dropped
blockers (open point 5.12).

**Deferred:** run state (`ralph-run.md`) and PR open/update scripts,
Chisel issue creation and Sidecar `gh pr create` (batch 1b). Later
batches: a verification contract with model and effort routing per
issue, an automatic Reven-to-Cody fix round with review findings feeding
`decisions.md`, parallel execution of independent chains in worktrees,
and folding Archy into Forge.

> **Key decision:** whatever must be deterministic moves out of prose into
> a script with a fixed output contract, and the tracker mode is resolved
> by that script and defaults to detached. Prose holds only the call; a
> bash gate decides pass or fail, and the model-run evals only advise.

**Fix (#234):** `lore-orient.sh` emitted `additionalContext` at the top
level, which Claude Code ignores for SessionStart, so the user saw the
orientation and the model never did. It is now nested under
`hookSpecificOutput` (with `hookEventName: "SessionStart"`) in both the
`jq` and the manual-escape branches; `systemMessage` stays for the UI and
the msg-only paths are unchanged. `scripts/test-lore-orient.sh` guards
both shapes. The installed `~/.claude/hooks` copy needs a re-sync.

---

### Iteration 30: Stats, the start of the monitoring arc

**Problem:** the squad runs every day and nothing says what it costs or
how often its PRs land without manual fixing. Every tuning decision so
far (turn budgets, model choice, the Forge challenge) was made on feel.

**Change:** `/stats` and `claude/hooks/squad-stats.py`. `collect` imports
Claude Code transcripts (main thread plus `subagents/`) into normalized
rows in `<vault>/squad-stats/usage.tsv`, one per API message, deduped by
message id, with the active squad skill attributed by time and the agent
type taken from the subagent meta file. Reven verdicts land in
`verdicts.tsv`. `report` aggregates the window and, in connected mode,
reads the PRs recorded in `progress.txt` with `gh pr view`.

Scope is all of Claude Code, not only the squad: every skill, command
and agent is recorded under its own name (other plugins keep their
prefix), and each session is classified squad, custom or vanilla. The
reason is comparison: to know whether a squad skill or a token-saving
tool pays off, there has to be a baseline of sessions without it.

> **Key decision:** importer and report are separate layers joined only by
> the normalized rows. Transcripts are the first source because they
> already exist and need no setup; OpenTelemetry becomes a second
> importer when batch import is no longer enough (live cost during a run,
> several machines). The report does not change when it lands.

Tools in the middle (MCP servers, hooks) are measured by technology,
never by product: tool calls by name, MCP servers parsed from the
`mcp__<server>__` prefix, failed calls classified by who stopped them.
A new server or hook shows up in the report without a code change. Who
stopped a call comes from the structured `permissionDecision` Claude
Code writes on the tool-result line (decision, source, reason type);
matching the result text is only a fallback for older transcripts,
because a hook that denies with its own reason leaves no marker in the
text. Hook runs come from Claude Code's `<event>_hook_summary` records
and `hook_*` attachments, so hook duration and injected context are
measured too.

Improvement is measured per unit of work, never as cost alone: the last
28 days against the 28 before, with the unit count beside every change
and no change shown below 10 units per period.

**Deliberately not measured yet:** "your commits on top of Cody's PR".
Cody commits under the user's git identity, so authorship cannot separate
them; commits after the PR opened is the stand-in (rework proxy). A
commit trailer from Cody would make it exact, a later step.

**Open point:** the KPIs are not fixed. The skill logs the questions the
user asks about each report in `questions.md`; after a month the
recurring ones become the KPI set and the rest of the report gets cut.

---

### Iteration 31: Squad doctor, install freshness

**Problem:** hooks, agents and skills are consumed from `~/.claude`, not
from the checkout, so a merged change does nothing until reinstalled. An
earlier spec was written against a `~/.claude` 27 commits behind main.

**Decision (plugin gate, resolved 2026-10-15):** the user chose to build
doctor for the manual `cp` install. Plugin distribution stays undecided;
if a native plugin install ships, doctor is redundant and gets removed.

**Change:** `claude/hooks/squad-doctor.sh` (report-only, `STALE=N`,
`STALE_FILE=`, `ORPHAN_FILE=`) hashes `~/.claude/{agents,skills,hooks}`
against the repo recorded in `~/.claude/.agent-squad-source` (written by
the README install step). Orphans come from git history of `claude/`, so
files the repo never shipped are never flagged. Missing record, repo or
install directory is silent. `lore-orient.sh` adds one Signals line when
N>0. Hooks absent from the install are not counted (some are optional).

**Superseded by Iteration 35:** the native plugin install removed doctor.

### Iteration 35: Native plugin, copy install and doctor removed

**Problem:** the squad was installed by copying `claude/{agents,skills,hooks}`
into `~/.claude/` and wiring hooks by hand in `settings.json`. A merged
change did nothing until reinstalled, and Iteration 31 added squad doctor
only to detect that drift. Claude Code now ships plugins with a hooks
manifest (parent #292, this change #293).

**Decision (2026-10, #293):** `claude/` is the plugin. Doctor is removed, as
Iteration 31 said it would be once a native install shipped. The vault stays
tool-neutral and unchanged (scope boundary of #292); only packaging moves.

**Change:**
- `claude/.claude-plugin/plugin.json` carries name, version, description;
  `claude/hooks/hooks.json` registers `lore-orient.sh` (SessionStart,
  matcher `startup|clear|compact`) and `lore-checkpoint.sh` (SessionEnd)
  via `${CLAUDE_PLUGIN_ROOT}/hooks/`; a repo-root
  `.claude-plugin/marketplace.json` makes the checkout a local marketplace.
- Skills and agents call scripts as `${CLAUDE_PLUGIN_ROOT}/hooks/<script>`
  instead of `~/.claude/hooks/<script>`. The path-resolution step is still
  a script call; exporting it once is the follow-up (#294).
- Version bumps are automatic and post-merge: `plugin-version.yml` applies a
  label-driven semver rule (`breaking-change` major, `enhancement` minor, `bug`
  patch, else none) via `scripts/plugin-version-bump.sh`, so PRs never edit
  `plugin.json` and parallel PRs cannot conflict on it. `main` is under a
  ruleset (PR required, no bypass), so the workflow opens and self-merges a
  one-line `chore/plugin-v<X.Y.Z>` PR instead of pushing; a guard workflow
  rejects hand edits of `version`.
- Removed: the README `cp` block, `.agent-squad-source`, the settings.json
  snippets, `squad-doctor.sh`, `test-squad-doctor.sh`, the doctor signal in
  `lore-orient.sh`. The eval scaffold no longer copies hooks into `$HOME`.
- `squad-lint.sh` check 8 now resolves `${CLAUDE_PLUGIN_ROOT}/hooks/<x>`
  and rejects `~/.claude/hooks/`; new check 9 validates the manifest,
  the scripts `hooks.json` registers, and bans the frontmatter keys plugin
  subagents ignore (`hooks`, `mcpServers`, `permissionMode`,
  `initialPrompt`). CI runs `claude plugin validate ... --strict`.

**Caveats recorded:** `allowed-tools` pre-approves tools for the invoking
turn and does not restrict the rest; `/stats` already accepts the bare and
the `agent-squad:` prefixed names. Not changed here: the root `CLAUDE.md`
still names `~/.claude/hooks/path-resolve.sh` (owner edit, see the PR), and
Sidecar and `worktree.sh` stay until #295.

### Iteration 36: Async checkpoints (#296)

**Problem:** `lore-checkpoint.sh` carried ~150 lines (detach, lock, 90 s
alarm) to fit the 1.5 s SessionEnd budget, and Cody's checkpoint and
`progress.txt` lines depended on prose that a stalled run skips.

**Change:** SessionEnd is registered `"async": true`, so the rebuild runs
inline and the detach, lock and alarm code is gone (staleness rule, headless
rebuild, `## Blocked` preservation, by-path vault commit and `--note` stay).
New `cody-checkpoint.sh` is an async `SubagentStop` hook (matcher `cody`, in
the plugin manifest because plugin subagents ignore frontmatter hooks): from
branch, HEAD and open PR it writes the checkpoint line and, for a PR, the
`progress.txt` line, and leaves `cody-checkpoint.env` for Ralph 2b, whose
classification is unchanged. Cody's prose checkpoint step is removed. Addendum:
a worktree session ending dirty records `uncommitted work on <branch>: N
files`, and `lore-orient.sh` lists dirty linked worktrees after a kill.

**Not done:** the optional Reven verdict recording in `verdicts.tsv` stays
with report-time parsing.


---

### Iteration 37: Sidecar retired, worktrees move into hooks (#295)

**Supersedes:** Iteration 22 (Sidecar, the worktree skill) and Iteration 27
(Sidecar shrunk to open and close). Iteration 22 declined native worktrees
because they were Claude-only; that reason ended with Iteration 24.

**Problem:** Sidecar hand-rolled, in prose, what Claude Code now does
natively (`claude -w <name> -n <ticket>`, a keep/remove prompt on exit, the
session starting inside the worktree so the project's own SessionStart hooks
fire there). What native does not do is attach to an existing branch, clone
`node_modules`, compare lockfiles, or refuse removal over uncommitted tracked
work; those were the parts of the skill worth keeping.

**Change:** `claude/skills/sidecar/` is deleted. `worktree.sh` gains
`hook-create` (WorktreeCreate: JSON `{name, cwd}` on stdin; attaches an
existing local or origin branch, else creates; copies the `.worktreeinclude`
files, clones dependencies, prints only the path; failures go to stderr with a
non-zero exit) and `hook-remove` (WorktreeRemove: same refusal rule as before,
now naming the manual command). `lore-orient.sh` prints the orientation block
inside a linked worktree (base from open PR, `progress.txt`, or `main`; diff
stat; dependency lines stored by `hook-create`), emits `sessionTitle` = the
branch, and records the starting HEAD under
`<vault>/projects/<name>/.squad/sessions/<session-id>`. `lore-checkpoint.sh`
counts commits from that record and appends one `progress.txt` line, with
`Notes:` taken from the commit subjects (no model call). The temp suffix for
cloned trees is now `*.wt-tmp`.

**Verified by the spike on #292 (Claude Code 2.1.312):** WorktreeCreate fires
before SessionStart and SessionStart still gets `CLAUDE_ENV_FILE`; attaching
an existing branch from the hook works. **Corrected caveat:** isolation is
advisory, a `cd` into the main checkout was not refused; nothing in the hooks
or docs relies on it. **Not verified:** the keep/remove exit prompt on a
hook-created worktree (interactive only).

---

### Iteration 32: Incident capture and a stricter Cody

**Problem:** three failures on one day (2026-10-14) were noticed only by
the user reading a session: an auto-mode denial of an `allowed-tools`
edit, Cody skipping its claim so `squad-labels.sh review` exited 10, and
Lore refusing a yes the invoking session relayed on the user's behalf.
Nothing recorded them, so a failure that recurred looked new each time.
In the same days Cody kept writing tests after the code (Iteration 1
already described it as TDD) and could still create branches with raw
`git checkout -b` outside its first step.

**Incident store (#240, #241-#244).** `squad-incidents.sh` keeps one
global append-only store at `<vault>/squad-incidents.tsv` with `record`,
`summary` and `resolve`. Capture is deterministic and allowlist-only,
from three sources:

- *At the source.* `squad_incident` in `squad-common.sh` records the
  failures worth knowing about where they happen: gh and git operation
  failures, setup bugs, the review-without-claim precondition, and Ralph
  escalations as their own kind. Usage errors, detached refusals and
  routine preconditions are deliberately not recorded. Recording is
  silent and always exits 0, so it can never change a script's stdout or
  exit code (the one exception in `SCRIPT_CONTRACT.md`).
- *From transcripts.* SessionEnd spawns a detached pass
  (`lore-checkpoint.sh --incidents`) that scans the main transcript and
  its subagent transcripts for auto-mode classifier denials, attributes
  them to a squad component (subagent `agentType`, or squad paths in the
  tool input), and dedupes on the tool-use id. User rejections are
  excluded. Foreground cost is about 90 ms against the 1.5 s SessionEnd
  budget.
- *At orientation.* `lore-orient.sh` adds one Signals line when
  `summary` reports recurring incidents. Healing is pull, not push: the
  user decides whether a recurring incident becomes an issue.

Fixes: #249 made the orient test seed its own incident store despite
`SQUAD_INCIDENTS=off`.

The relayed-yes failure is out of v1 capture; it was fixed directly
instead (#236): the `/lore` entrypoint shows Tier 2 proposals to the
user and resumes Lore with the reply quoted as `User confirmed:`, which
Lore's Tier 2 rule now accepts.

**Test-first Cody (#238).** Chisel puts given/when/then test specs in
every issue (copied, derived, asked, or left as an open point), and marks
docs, config and layout issues `exempt`. Cody writes the tests, sees them
fail, implements until green, and never edits a failing test to make it
pass. A missing test runner, open specs or still-red tests are now
escalations in Ralph, not silent skips. The heavier design (a
`squad-test.sh` script and a separate failing-test commit as proof of the
red step) was dropped: the squad has to work in any project, and the red
step is accepted as unprovable.

**One branch path (#250).** `cody.md` states once that `squad-branch.sh`
is the only way to create or switch branches, including fix rounds and
recovery. It was first proposed as a `lore prefer` entry and rejected
there: a rule that governs one agent's tool use belongs in that agent's
prompt, not in a global preference every agent reads.

> **Key decision:** failures are data. Record them deterministically where
> they happen, never let recording change behavior, and surface only the
> recurring ones. Whether a failure becomes work stays a human call.

---

### Iteration 33: Rules, scope and ownership in memory

**Problem:** the memory layer had grown without scope. Ralph injected
only the last 20 active `decisions.md` entries, so on a long-lived
project (27 active entries) the oldest, which were the project-wide
rules, silently stopped reaching Cody and Reven while recent
ticket-scoped details stayed in. `lore prefer` wrote every rule to both
`development.md` and the project's `decisions.md`, so project-only rules
became global and global rules were duplicated per project. Forge ranked
`development.md` in its authority order but never read it. And
duplication showed up in almost every batch because no issue said which
lib owns a new shared concept, so Cody knowingly wrote twins and Reven
caught them afterwards.

**Change:**

- *`[rule]` markers (#257).* A `## [date] [rule] <title>` entry in
  `decisions.md` is always loaded by Forge, Ralph, Cody and Reven, with a
  cap of 15 active rules and a one-line overflow warning. Untagged
  entries keep the last-20 window. Forge now reads `development.md`.
- *One rule, one file (#256).* `lore prefer` classifies a rule as global
  or project-only, asks one question when unsure (`--global` and
  `--project` skip it), and writes exactly one place: a line in
  `development.md`, or a `[rule]` entry in `decisions.md`. When it cannot
  ask, it defaults to project-only, never global.
- *Owners (#255).* Chisel adds an `Owner:` line for each new shared
  concept and appends it to an `## Owners` map in `architecture.md`,
  which Seed preserves on refresh. Cody gets a stop rule: when a twin is
  needed and the dependency rules prevent importing the original, it
  escalates with `ESCALATION: ownership` instead of duplicating. A Cody
  self-review step was rejected: it would be a mini-Reven grading its own
  work. Reven stays the only verifier.
- *Checkpoint on other branches (#254).* A main-checkout session that
  worked on linked worktrees through absolute paths left `status.md`
  untouched, because staleness only looked at the current branch. The
  SessionEnd check now fires when any local branch has a commit after
  `Last updated`, and the rebuild evidence lists recently touched local
  branches.

> **Key decision:** memory needs scope as much as it needs storage. A
> rule's reach (one project or all) and its loading (always, or by
> recency) are explicit properties of the entry, not side effects of
> which file it landed in or how old it is. Ownership is decided in the
> analysis, where it is cheap, not discovered in review, where it costs a
> fix round.

---

### Iteration 34: Reven applies the rules and reads the neighbourhood

**Problem:** two gaps in the review loop. `/stats` reported 1 Reven
verdict in 30 days against 48 merged PRs, because the importer read only
text blocks while Reven delivers its verdict through the
`SubagentHandback` tool (63 of 65 transcripts on disk). And on a real
47-file PR, Reven covered 2 of 13 findings a team review bot raised,
after nine `[rule]` entries describing six of the misses had been added:
the rules were loaded and nothing applied them.

**Change:**

- *Verdict capture (#264).* `squad-stats.py` also matches the verdict in
  `SubagentHandback` inputs, keyed by tool-use id so re-running `collect`
  backfills without duplicates. `Bash` inputs (the `gh pr comment`
  bodies) are ignored because they repeat the handback.
- *Rule pass (#265).* After reading the diff, Reven checks every loaded
  `[rule]` and reports a `## Rules` section (fired, not applicable, not
  checked). An active `[rule]` can now back a blocking finding, as
  `architecture.md` can. Files the rules talk about are triaged first and
  `maxTurns` went from 20 to 40.
- *Neighbourhood (#265).* Reven reads the parent story, linked and cited
  issues and their comments, the API spec when one is discoverable, and
  the repo's own review rulebook when `CLAUDE.md` or the README points to
  one. A finding whose truth depends on the backend, data or intent goes
  under Observations as a question, never as a blocking issue: the
  motivating PR had a blocking finding built on exactly such a premise.

Follow-ups from the same comparison are open as #268-#273 (listener
tracing, an `INCOMPLETE` verdict, model choice by diff size, tracker
reads independent of `chisel.mode`).

> **Key decision:** a loaded rule is not an applied rule. Every rule the
> reviewer is given must be accounted for in its output, and the metric
> that says whether the reviewer works has to read where the verdict
> actually is.

---

## 3. Final Architecture

This section describes the repository as it stands after Iteration 34.
Components that were designed but are not active are listed in section 4
("What is out of the MVP") and section 6, not here.

### Squad Overview

| Name | Type | Model | Role |
|------|------|-------|------|
| **Seed** | Skill | session | First contact: records the vault mapping, writes `architecture.md` (with `## Data flow` and `## Owners`) and `scout-cache.md` (the former Scout snapshot). |
| **Forge** | Skill | session | Interactive discovery with an opening challenge and a delta check; writes `forge/output.yaml` with a complexity field. |
| **Archy** | Skill | session | HIGH complexity only: enriches the Forge YAML into a PRD. |
| **Chisel** | Skill | session | Turns YAML or PRD into tracker issues with test specs and `Owner:` lines. Connected: GitHub issues. Detached: a local batch file, handoff and Jira-importable CSV. |
| **Ralph** | Skill (loop) | session | Runs issues in dependency order through Cody, one stacked branch and PR per issue; persists run state in `ralph-run.md`; classifies failures as retry or escalation. |
| **Cody** | Agent | sonnet | Implements one issue test-first on a branch created only through `squad-branch.sh`; escalates on open specs, missing runner or ownership conflicts. |
| **Reven** | Agent + skill | sonnet | Reviews a PR against its base, applies loaded `[rule]` entries, reads the issue neighbourhood. |
| **Challenge** | Agent + skill | opus | Stateless stress test of a proposal; standalone and inside Forge. |
| **Lore** | Agent + skill | sonnet | Vault memory: `lore start` (setup and repair), `lore prefer` (one rule, one file), `lore recover`. |
| **Sidecar** | Skill | session | Opens and closes a worktree on an existing branch; Cody only on explicit opt-in. |
| **Stats** | Skill | session | Imports Claude Code transcripts and reports cost, usage and outcomes for every session kind. |

Hooks and scripts (`claude/hooks/`): `path-resolve.sh` (vault, project,
tracker mode), `squad-common.sh`, `squad-labels.sh`, `squad-branch.sh`,
`squad-incidents.sh`, `worktree.sh`, `squad-doctor.sh`, `squad-stats.py`,
`chisel-config-validate.py`, and the session hooks `lore-orient.sh`
(SessionStart, read-only) and `lore-checkpoint.sh` (SessionEnd: status
rebuild and the incident transcript pass).

---

### Full Flow

```
/seed           First contact. Vault mapping, architecture.md, scout-cache.md.
SessionStart    lore-orient.sh injects status, evidence, Context refs and Signals.
/forge          Opening challenge, rounds, delta check -> forge/output.yaml.
/archy          (HIGH only) YAML -> prd/current.md. You review.
/chisel         YAML or PRD -> tracker issues (connected) or batch file (detached). You review.
/ralph          Cody per issue in dependency order, retries and escalations.
Cody            Test-first implementation, commit, PR (connected) or paste-ready description (detached).
Reven           Review against the PR's base. You decide the merge.
SessionEnd      lore-checkpoint.sh rebuilds a stale status.md and records denials.

/sidecar <branch>   Worktree on an existing branch, open and close.
/challenge          Any time, any content.
/stats              Weekly, at least.
```

---

### File Structure

With `context: repo` in `lore-config.json`, `architecture.md`,
`scout-cache.md`, `forge/` and `prd/` live in `<PROJECT_ROOT>/.squad`
instead; everything else stays in the vault.

| File | Purpose |
|------|---------|
| `<vault>/projects/<project>/.squad/forge/output.yaml` | Forge output. Archived to `forge/archive/` once Chisel consumes it. |
| `<vault>/projects/<project>/.squad/architecture.md` | Stack, patterns, conventions, data flow, owners. Written by Seed, `## Owners` extended by Chisel. |
| `<vault>/projects/<project>/.squad/scout-cache.md` | Project snapshot. Replaced on each Seed run. |
| `<vault>/projects/<project>/.squad/prd/current.md` | Active PRD, archived by Chisel after consumption. |
| `<vault>/projects/<project>/.squad/chisel-config.json` | Tracker mode and labels. `connected` only when set explicitly. |
| `<vault>/projects/<project>/.squad/issues/` | Detached-mode batch files, handoff checklists, CSV. |
| `<vault>/projects/<project>/.squad/progress.txt` | Ralph and Sidecar log, one line per issue or session. |
| `<vault>/projects/<project>/.squad/session.log` | Per-project session log, tailed by `lore-orient.sh`. |
| `<vault>/projects/<project>/.squad/ralph-run.md` | Ralph run state for resume. |
| `<vault>/projects/<project>/status.md` | Resumption handoff, reconstructed from evidence. |
| `<vault>/projects/<project>/decisions.md` | Project decisions. `[rule]` entries always loaded (cap 15); untagged entries by last-20 window. |
| `<vault>/preferences/development.md` | Global rules only, one line each. |
| `<vault>/squad-incidents.tsv` | Global incident store. |
| `<vault>/squad-stats/` | Normalized usage and verdict rows, reports, `questions.md`. |
| `<vault>/lore-config.json` | Absolute CWD paths to vault display names; optional `context: repo`. |
| `claude/agents/`, `claude/skills/`, `claude/hooks/` | Definitions and scripts, installed into `~/.claude/`. |
| `SCRIPT_CONTRACT.md`, `LABEL_STATE_MACHINE.md`, `PATH_RESOLUTION.md` | Maintainer references; never read at runtime. |
| `scripts/test-*.sh`, `claude/evals/` | Tier-1 bash gate and tier-2 advisory plugin evals. |

---


## 4. MVP Configuration

### What is in the MVP

| Component | Role in MVP |
|-----------|-------------|
| **Forge** | Interactive session to structure your idea into YAML before any code is written. |
| **Archy** | Produces a full PRD on HIGH complexity. You review and iterate via `/archy` before proceeding. |
| **Chisel** | Converts YAML or PRD to tracker issues (GitHub in connected mode, a local batch file in detached mode). You review issues before proceeding. |
| **Cody** | Writes code. Assigns the issue, creates a branch, implements, and opens the PR. |
| **Reven** | Reviews every PR. You invoke Reven manually after Cody opens the PR. |
| **Ralph** | Agentic loop. Invokes Cody per issue, manages retries (max 3), escalates on persistent failure. |
| **Sidecar** | Companion entry point for fixes on an existing branch. Opens a worktree, invokes Cody once per fix, tears down and writes one summary line on close. Does not touch Forge/Archy/Chisel/Ralph. |
| **Seed** | Initializes project context. Run once per project, then again after significant structural changes. |
| **Lore** | Manages second-brain vault. `lore start` is setup/repair only (naming, migration, re-mapping); `lore prefer` records preferences; `lore recover` rebuilds status explicitly. No session-end command. |

### What is out of the MVP

- **Sentry:** the orchestrator. You handle routing manually. Add when the flow becomes complex enough to justify automation.
- **Qugh:** QA behavioral testing. You handle manual testing. Add when Reven alone misses behavioral issues.
- **Oak:** daily documentation job. Add when documentation starts drifting noticeably from the codebase.
- **Agent Teams:** parallel Qugh and Reven. Add when both are active.
- **Lex:** legal and compliance audit, GDPR baseline. Add when a project approaches production with real users. Reads the `## Data flow` section of `architecture.md` scaffolded by Seed.

### MVP Flow

```
/seed           Initialize context. /clear after.
/forge <idea>   Forge runs session, Scout provides context, you confirm complexity.
                → HIGH: /archy → review PRD → /chisel
                → LOW/MED: /chisel directly
/chisel         Creates tracker issues. You review.
/ralph          Loops Cody per issue in dependency order.
                Cody opens PR → you invoke Reven.
                Reven requests changes → feedback to Cody → repeat.
Merge.

/sidecar <branch>   Alternate entry point, bypasses everything above.
                     Worktree on an existing branch, Cody per fix, close.
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

> **Resolved (2026-06-12):** failure classification written into both Ralph skills (section 2b). Retryable: build/compile failure, test failure introduced by the changes, type errors, unresolvable lint errors, transient PR-creation errors. Immediate escalation: identical error across two consecutive attempts, ambiguity requiring a human decision, auth or environment failures, loop symptoms. Not counted as failures: absent test suite, pre-existing failures on main (noted in progress.txt and the PR body). Cody's manual-PR fallback when `gh` is unavailable counts as success.

> **Update (Iteration 29):** label transitions and branch create/continue are now scripts with the exit-code contract in `SCRIPT_CONTRACT.md` (0 success, 2 usage error, 10 precondition failed, 20 gh/git/network error or refused detached write). Ralph's retry decision for these steps reads the exit code instead of parsing prose; run state and PR scripts are batch 1b.

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

### 5.10 ADK and the framework-substrate question

Open question: does adopting an agent framework (Google ADK, or a comparable runtime) give upside over the current textual-agent model, where an agent is a prompt definition interpreted by Claude Code or Codex and orchestration is itself a prompt?

Findings so far, from evaluation rather than implementation:

- ADK is a code-first framework. Agents are code objects, orchestration is a compiled graph-based workflow runtime (deterministic routing, fan-out/fan-in, retry, loops, human-in-the-loop), state is structured sessions, observability and eval are first-class, and agents deploy to cloud infrastructure. It is model-agnostic through adapters, though it leans toward Gemini and Google Cloud.
- The squad already implements most of what a framework provides, as prompt-discipline rather than code. Ralph is a workflow runtime (dependency graph, retry, escalate, loop). The vault is sessions plus memory. session.log is tracing. The confirmation tiers are human-in-the-loop. Adopting a framework would mostly reimplement this discipline on a third runtime that is neither Claude Code nor Codex, breaking the tool-agnosticism of Iteration 12 and reintroducing the dependency class rejected for MCP.
- The decision boundary for choosing a framework over textual agents: deterministic guaranteed orchestration over probabilistic, unattended production scale over interactive solo, first-class observability and eval over hand-rolled, structural concurrency over occasional independence. The current use case sits on the textual side of all four.
- For a Claude-primary developer the apples-to-apples comparison is not ADK but Anthropic's Claude Agent SDK, which keeps the model family and avoids Gemini and Vertex gravity. ADK is the cross-vendor reference point, not the natural adoption target.

> **Action:** do not adopt a framework before Sentry exists. The framework question is really the Sentry build-vs-adopt decision: when Sentry needs real parallel orchestration, eval, and observability instead of hand-rolled prompt logic, evaluate implementing it on the Claude Agent SDK (primary candidate) or ADK (cross-vendor option) against continuing in prompts. Until then a framework is premature. If a spike is wanted sooner, prototype one read-only role such as Reven on the Claude Agent SDK as an isolated experiment, never on the hot path, to gather evidence without committing the substrate.

### 5.11 Test harness

Open question: how should the squad be validated, given a growing set of patches none of which has been confirmed by a real run? A harness is the scaffolding that lets the squad run against known cases and tells you mechanically whether it behaved, as opposed to noticing in a live session that something feels off (which is how the GG-18 path bug slipped through).

The harness spectrum, cheapest first:

- **Observability (already built).** session.log, progress.txt, and the vault git history are a manual harness: after a batch you can read retries per issue, Reven's first-pass verdict, and whether reconstruction produced an accurate status.md. The only cheap enhancement worth making is a read-only script that summarizes a session from these artifacts so review is fast.
- **Fixtures.** One or two throwaway repos (connected and detached) with a deliberately designed issue set: a dependency chain, a cycle that must halt, an issue that must fail and escalate. Re-running the squad against the same fixture after each patch surfaces behavior drift. No scorer needed; the result is read by eye. This is the layer most likely to earn its place.
- **Assertions.** Encoding invariants as automated checks ("escalate after 3 retries", "a cycle halts", "reconstruction preserves ## Blocked"). This is the real harness and where cost and dependency-creep live (golden-file comparison is brittle; LLM-as-judge adds a model on every run). Gate it behind evidence that manual fixture-running is too slow or error-prone.

> **Partially closed (Iteration 29):** the assertions layer now exists in two tiers. Tier 1 is a deterministic bash gate: `scripts/test-squad-labels.sh`, `scripts/test-squad-branch.sh`, `scripts/test-squad-common.sh`, `scripts/test-path-resolve.sh`, `scripts/test-gh-shim.sh` and the lint suites run against a `gh` shim and fixture repos (`hook-tests.yml` on ubuntu and macOS, `squad-lint.yml` on ubuntu only), plus `squad-lint.sh` checks 6-8. Tier 2 is `claude/evals/`, three advisory `claude plugin eval` cases for what prose does. Still open: fixtures for Ralph-level scenarios (cycle halts, escalation after retries), a verification contract per issue, and reconstruction assertions.

> **Action:** build nothing up front. The first real batch after merge is the first harness run, manual. If reading logs by hand suffices, do nothing. If you re-run the same scenarios and squint at output, build the fixtures. If you repeat correctness mistakes a check could catch, add assertions for those specific cases. The harness grows from observed pain, not design. Note: a framework's eval and observability tooling (open point 5.10) overlaps this; if the harness need grows past the observability layer, fold it into the Sentry-time build-vs-adopt decision rather than building both.

### 5.12 Ralph stacking rule with diamond dependencies

Ralph stacks each issue's branch on its latest blocker. That is lossless for a chain but wrong for a diamond: when an issue has two blockers that are not themselves ordered (#214 needed #211 and #212; #220 needed #213, #217 and #219), the branch contains only one of them and silently drops the others. Batch 1a avoided the problem by running a linear stack in topological order.

> **Action:** specify the rule in Ralph for multi-blocker issues: stack on a merge of all blockers, or fall back to a linear stack when the graph has diamonds, and make Ralph report which it chose. Decide before parallel chains (later batch) make linearizing unavailable.

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

### Add Lex when:
- A project is approaching production deployment with real users, especially EU users.
- The product collects or processes personal data: forms, analytics, authentication, payments.

> Lex reads the `## Data flow` section of `architecture.md` and produces a prioritized, evidence-based compliance checklist (GDPR as baseline, since the controller is EU-based regardless of visitor origin). It falls back to targeted source reading only when the section is missing or sparse. Do not build Lex before the trigger fires: the `## Data flow` section already has standalone value for Archy and Reven, and a speculative agent contradicts the discipline this section exists to enforce.

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

Canonical definitions live in `claude/`, the sole distribution tree since
Iteration 24 dropped the parallel Codex tree:

```
claude/
  skills/
    forge/SKILL.md
    archy/SKILL.md
    chisel/SKILL.md
    seed/SKILL.md
    ralph/SKILL.md
    sidecar/SKILL.md
    reven/SKILL.md
    lore/SKILL.md
    challenge/SKILL.md
    stats/SKILL.md
  agents/
    cody.md
    reven.md
    lore.md
    challenge.md
  hooks/
    path-resolve.sh
    worktree.sh
    lore-orient.sh
    chisel-config-validate.py
    squad-common.sh
    squad-labels.sh
    squad-branch.sh
    squad-stats.py
  evals/
    connected-claim, detached-claim, worktree-continue
  .claude-plugin/plugin.json   (plugin manifest)
  hooks/hooks.json             (SessionStart, SessionEnd registration)
```

`PLATFORM_DIFFERENCES.md` is kept only as a short historical note; it no
longer documents an active second tree.
