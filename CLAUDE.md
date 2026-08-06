Agent Squad runtime state lives in the vault at
`<vault>/projects/<name>/.squad/`, read on demand. Skills and agents are
self-contained; there is no shared runtime *prose* file to preload —
loading another skill's text into context has no return-value semantics
and is a soft, easily-skipped dependency, which is exactly what got
removed in Iteration 19. Path resolution is the one deliberate exception,
and it resolves the tension by being a *script*, not a shared skill or
doc: every skill and agent's "Path resolution protocol" runs
`~/.claude/hooks/path-resolve.sh` (Codex: `~/.codex/hooks/path-resolve.sh`)
via Bash as its first step and reads three output lines
(`VAULT_PATH`/`PROJECT_ROOT`/`DISPLAY_NAME`) — an ordinary, unambiguous
shell call each skill already makes dozens of per session, not a new
category of soft dependency. `PATH_RESOLUTION.md` at the repo root
documents the algorithm and its rationale but is itself never read at
runtime by anything — only `path-resolve.sh` is. If you change how
project-root resolution works, edit `path-resolve.sh` (both trees), then
update `PATH_RESOLUTION.md` to match.

Second-brain: a SessionStart hook auto-orients (read-only); run
`/lore start` when beginning real squad work to handle naming,
migration, and session-log reset. Command surface: `lore start`,
`lore prefer`, `lore recover` (no session-end command — status
reconstructs on the next start).

Only load squad and second-brain context for active project work.
Skip both for quick questions, one-off tasks, or anything unrelated
to the current project.

## Squad Distribution

This project maintains parallel distributions in `claude/` AND `codex/`.
Any change to skills, agents, or workflows must be applied to both
directories unless the task is explicitly scoped to one distribution.

Before declaring a refactor or update complete, always grep both `claude/`
and `codex/` to confirm the change has been mirrored. Leaving one
distribution out of sync is a defect.

## Scope Boundaries

- **Global promotion**: When promoting items to global config (e.g.,
  `~/.claude/` or `~/.codex/`), only promote squad-specific items such as
  skills and agents. Never promote `CLAUDE.md`, workspace-level config, or
  project-specific files unless the user explicitly requests it.
- **No workspace artifacts**: Do not create symlinks or `.squad/`
  directories inside the host project workspace. Vault-based state lives
  outside the workspace at `~/second-brain/` (or `$SECOND_BRAIN_PATH`).
  Per-project `.squad/` directories belong in the vault, not in the repo.
- **Skipped phases**: When a prior phase (e.g., forge) concluded to skip a
  step, do not re-invoke that step automatically. Confirm with the user
  before invoking any phase that was previously marked as skipped or
  unnecessary.

## Environment Preflight

- **gh auth check**: Before any PR-creation step, verify that `gh auth
  status` succeeds and that `gh` is available on PATH. Surface the issue
  immediately rather than completing all branch work first and failing only
  at the push/PR step.
- **Sub-agent permissions**: Sub-agents that need to post comments, edit
  files, or call GitHub APIs must be granted the required tool permissions
  (Edit, Bash, mcp__github) up front at invocation time. Do not assume
  inherited permissions are sufficient.
