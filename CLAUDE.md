Agent Squad runtime state lives in the vault at
`<vault>/projects/<name>/.squad/`, read on demand. Skills and agents are
self-contained; there is no shared runtime *prose* file to preload —
loading another skill's text into context has no return-value semantics
and is a soft, easily-skipped dependency, which is exactly what got
removed in Iteration 19. Path resolution is the one deliberate exception,
and it resolves the tension by being a *script*, not a shared skill or
doc: the SessionStart hook `hooks/squad-env.sh` runs the plugin's
`hooks/path-resolve.sh` once and exports eight values to `$CLAUDE_ENV_FILE`
(`SQUAD_VAULT_PATH`/`SQUAD_PROJECT_ROOT`/`SQUAD_DISPLAY_NAME`/`SQUAD_DIR`/`SQUAD_TRACKER_MODE`/`SQUAD_STATE_DIR`/`SQUAD_TRACKER_PROVIDER`/`SQUAD_VCS_PROVIDER`;
`SQUAD_TRACKER_MODE` is `detached` unless `chisel.mode` is provably `connected`;
the two providers come from `chisel.tracker`/`chisel.vcs`, default `github`, a non-name value falls back to `github`),
which every later Bash call in the session, subagents included, sees.
Each skill and agent carries one fallback line instead of a protocol block:
use those variables, and if `SQUAD_PROJECT_ROOT` is unset (headless
`claude -p`, the evals) run `${CLAUDE_PLUGIN_ROOT}/hooks/path-resolve.sh`
via Bash — an ordinary, unambiguous shell call, not a new category of soft
dependency. Hooks that run outside the session env (`worktree.sh`,
`lore-checkpoint.sh`, `squad-stats.py`) still call `path-resolve.sh`
directly. `PATH_RESOLUTION.md` at
the repo root documents the algorithm and its rationale but is itself
never read at runtime by anything — only `path-resolve.sh` is. If you
change how project-root resolution works, edit `path-resolve.sh`, then
update `PATH_RESOLUTION.md` to match.

Second-brain: a SessionStart hook auto-orients (it first folds pending writer
events, a vault commit when any are pending; the orientation itself is
read-only); run
`/lore start` (or `/seed`, which calls `lore map` first) on first contact
with a project. Lore owns first contact; Seed scans. The hooks handle each
session; `/lore start` also migrates a legacy `.squad/` and re-maps a moved
checkout. Other plugins write only through the `lore` shim (`lore event`,
SCRIPT_CONTRACT.md); `examples/lore-client/` proves that and is not shipped.
Command surface: `lore start [--local]`,
`lore prefer`, `lore recover` (no session-end command — status
is rebuilt by the SessionEnd hook or `lore recover`).

Only load squad and second-brain context for active project work.
Skip both for quick questions, one-off tasks, or anything unrelated
to the current project.

## Scope Boundaries

- **Global promotion**: When promoting items to global config (e.g.,
  `~/.claude/`), only promote squad-specific items such as skills and
  agents. Never promote `CLAUDE.md`, workspace-level config, or
  project-specific files unless the user explicitly requests it.
- **No workspace artifacts**: Do not create symlinks or `.squad/`
  directories inside the host project workspace. Vault-based state lives
  outside the workspace at `~/second-brain/` (or `$SECOND_BRAIN_PATH`).
  Per-project `.squad/` directories belong in the vault, not in the repo,
  unless the project is configured `context: repo` in `lore-config.json`
  (personal repos only); then `<PROJECT_ROOT>/.squad` holds
  `architecture.md`, `scout-cache.md`, `forge/` and `prd/` (the
  `SQUAD_DIR` line of `path-resolve.sh`), and everything else stays in the
  vault.
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

## Scripted steps

Script output and exit-code rules are in [SCRIPT_CONTRACT.md](SCRIPT_CONTRACT.md).
Once a step is scripted, the prose around the call holds only the
invocation, the keys it reads and the action per exit code. Never describe
what the script does, and never add an "if the script fails, run gh ..."
fallback.
