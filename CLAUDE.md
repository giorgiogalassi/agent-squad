Agent Squad reads runtime context from `.squad/` on demand.
Squad conventions: read `SQUAD.md` before acting on any squad task.
Second-brain: invoke `lore start` when beginning squad session work.

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
