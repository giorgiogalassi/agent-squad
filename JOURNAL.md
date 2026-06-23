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

## 3. Final Architecture

### Squad Overview

| Name | Type | Model | Role |
|------|------|-------|------|
| **Scout** | Skill | n/a | Project context snapshot, cached, invalidated on structural changes |
| **Seed** | Skill | n/a | One-time project initialization. Produces `architecture.md` and `scout-cache.md` in `<vault>/projects/<project>/.squad/`, ensures vault directories exist, and scaffolds second-brain project files. |
| **Forge** | Skill | n/a | Interactive brainstorming session, produces structured YAML with complexity field |
| **Chisel** | Skill | n/a | Converts YAML or PRD to Linear issues. Single input format, single output format |
| **Archy** | Skill | Opus or Sonnet | Architectural analysis, produces PRD from Forge YAML on HIGH complexity only |
| **Cody** | Agent | Sonnet | Assigns issue, creates branch, implements, opens PR. Invoked directly or by Ralph. |
| **Qugh** | Agent | Sonnet | QA behavioral testing, runs in parallel with Reven via Agent Teams |
| **Reven** | Agent | Sonnet | Code review, runs in parallel with Qugh via Agent Teams |
| **Lore** | Agent | Sonnet / gpt-5.4 | Second-brain memory: session orientation, status handoff, preference recording, git-based recovery. Filesystem only, no MCP. |
| **Oak** | Agent | Sonnet | Documentation, daily job reading full git log |
| **Ralph** | Loop | Sonnet | Agentic loop invoking Cody, max 3 retries, escalates on persistent failure. Groups issues into one branch per dependency chain. |
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
| `<vault>/projects/<project>/.squad/forge/output.yaml` | YAML produced by Forge. Read by Sentry, Chisel, and Archy. Overwritten each session. |
| `<vault>/projects/<project>/.squad/architecture.md` | Stack, patterns, conventions, data flow. Written by Seed. Read by Forge, Archy, Cody, Reven; data flow is Lex's future input. |
| `<vault>/projects/<project>/.squad/scout-cache.md` | Project snapshot. Written by Seed. Replaced entirely on each Seed run. |
| `<vault>/projects/<project>/.squad/decisions.md` | Business assumptions and domain constraints. Read by you, not agents. |
| `<vault>/projects/<project>/.squad/prd/current.md` | Active PRD. Archived by Chisel after consumption. |
| `<vault>/projects/<project>/.squad/prd/archive/` | Past PRDs. Never loaded automatically. |
| `<vault>/projects/<project>/.squad/chisel-config.json` | Linear team, project, label, status. Written on first Chisel run. |
| `<vault>/projects/<project>/.squad/progress.txt` | Ralph's per-issue batch memory. Appended by Ralph, read by Cody. |
| `<vault>/projects/<project>/.squad/issues/` | Detached-mode batch files (local issue IDs, key mapping, Jira-importable CSV) and handoff checklists. |
| `<vault>/lore-config.json` | Maps absolute CWD paths to vault display names. Written by Lore on first project encounter. |
| `claude/skills/` | Claude-specific skill definitions to copy into `~/.claude/skills/`. |
| `claude/agents/` | Claude-specific agent definitions to copy into `~/.claude/agents/`. |
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
| **Lore** | Manages second-brain vault. `lore start` orients and reconstructs status; `lore prefer` records preferences; `lore recover` rebuilds status explicitly. No session-end command. |

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

> **Resolved (2026-06-12):** failure classification written into both Ralph skills (section 2b). Retryable: build/compile failure, test failure introduced by the changes, type errors, unresolvable lint errors, transient PR-creation errors. Immediate escalation: identical error across two consecutive attempts, ambiguity requiring a human decision, auth or environment failures, loop symptoms. Not counted as failures: absent test suite, pre-existing failures on main (noted in progress.txt and the PR body). Cody's manual-PR fallback when `gh` is unavailable counts as success.

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
