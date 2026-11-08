# Script contract

Every scripted squad verb (the label and branch scripts shipped next to
`path-resolve.sh` in the plugin's `hooks/` directory) follows this contract. Shared
code lives in `claude/hooks/squad-common.sh`, which scripts source.

## Stdout

Only lines matching `^[A-Z_]+=`. One `KEY=value` per line. Nothing else.

Value encoding: single line; `\` is escaped as `\\`; `=` after the first
`=` is literal and not escaped; newlines are forbidden (`squad_emit`
rejects them).

Every verb emits:

- `OUTCOME=applied|recorded-local|unchanged`
- `CHANGED=yes|no`

`applied` = performed on the tracker (connected). `recorded-local` =
written to the handoff file (detached). `unchanged` = already in the
requested state; `CHANGED=no`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success in either mode, including `recorded-local` and idempotent `unchanged` |
| 2 | Usage error |
| 10 | Precondition failed |
| 20 | Error: gh, git or network failure, or a refused write in detached mode |

Degraded success: exit 0 with a stderr notice when an optional tool is missing
(`vault-pr.sh finish` without `gh` pushes the branch and names the manual PR step).

gh and git exit codes are never passed through (gh's own 4 means auth
required; it surfaces as 20). Stderr carries one human-readable reason
line.

## Exception: `squad-incidents.sh record`

`record` writes nothing to stdout and always exits 0, even on its own I/O
errors, so failure paths in other scripts can call it safely. It is
best-effort capture, not a verb whose result callers act on. The other
verbs (`summary`, `resolve`) follow the contract above.

## The `lore` dispatcher

`claude/hooks/lore <verb>` follows the contract above. Verbs so far:

- `commit [--vault <dir>] [--project <name>] [--message <msg>] --paths <p>...`:
  the only code that commits to the vault (lint check 13). Runs under one lock
  shared by every checkout of the vault. Emits `OUTCOME=applied|unchanged` and
  `CHANGED=yes|no`. Exit 0 done or nothing to commit, 2 usage, 20 not a git
  repository, lock wait timed out (`LORE_LOCK_WAIT` seconds, default 60) or
  commit failed. A stale lock (dead pid, or older than 10 minutes) is broken
  with a stderr notice.
- `event --project <p> --source <s> --kind log|checkpoint|progress|note --line <text> [--key <k>] [--vault <dir>]`:
  writes one event file `<state>/inbox/<id>.ev` through a dot-prefixed temp file
  and `mv`. Emits `OUTCOME=applied`, `CHANGED=yes`, `ID=<id>`. Exit 0 written, 2
  usage (also an unknown kind), 10 no vault or unmapped project (nothing
  written), 20 write failure. The vault is `--vault` or `SECOND_BRAIN_PATH`.
- `fold [--project <p>] [--vault <dir>]`: claims the inbox events (`mv` to
  `inbox/.claimed-<pid>/`), takes the same lock as `commit`, applies them,
  snapshots the working-state files (`ralph-run.md`, `cody-checkpoint.env`,
  `progress.txt`) and commits once through the same committer internal. Without
  `--project` every project with an inbox is folded. Claims of dead pids are
  adopted by one atomic rename; recovery goes by event ID (an `applied`
  ledger written right after each effect), so no event is lost and none is applied
  twice except after a crash in the instant between an effect and its ledger
  line. Identical lines from distinct events are all kept. Emits
  `OUTCOME=applied|unchanged`, `CHANGED`, `APPLIED=<n>`, `QUARANTINED=<n>`.
  Exit 0 done or nothing to do, 2 usage, 10 no vault or unmapped project, 20 not
  a git repository, lock wait timed out or commit failed (claimed events stay
  for the next fold). Hook callers set a short `LORE_LOCK_WAIT`.

  Event file: `KEY=value` lines, one per line, `V=1`, `ID`, `SOURCE`,
  `KIND` (`log|checkpoint|progress|note`), optional `KEY`, `TS`
  (`YYYY-MM-DD HH:MM:SS`), `LINE`. Events apply in id order; within one fold the
  newest event per SOURCE+KIND+KEY wins. `log` appends `[TS] [SOURCE] LINE` to
  `session.log`; `progress` appends `LINE` to `progress.txt`; `checkpoint` adds
  `[TS] [SOURCE] LINE` to `status.md` `## Last checkpoint` (3 kept, newest
  first); `note` keeps one line per SOURCE+KEY, at most 10 per SOURCE, under
  `## Other sources`. Unparsable events and unknown kinds move to
  `inbox/quarantine/` with a `.why` file and are never committed. `inbox/` is
  listed in the vault's `.git/info/exclude`, with the rest of the local-only state
  (see "Local-only vault state" in PATH_RESOLUTION.md).
- `push [--vault <dir>]`: pushes each `lore/*` session branch of the vault and
  opens or updates its PR (wraps `squad_vault_finish`). Started detached by
  SessionEnd and retried by SessionStart; never run it where a wait matters.
  The vault lock is held only around the local worktree-drop step, never across
  the network. Emits `OUTCOME=applied|unchanged|failed` and `CHANGED=yes|no`.
  `unchanged` also for a local-only vault (`"vault_main": "local-only"`, or no
  `origin`), which never calls gh. Exit 0 done or nothing to push, 2 usage, 20
  not a git repository or a push or PR failure (`OUTCOME=failed`). Every run
  writes `<git-common-dir>/lore-push-status` with the keys `AT=<epoch>`,
  `OUTCOME=applied|unchanged|failed` and `REASON=<one line, empty unless failed>`;
  the next SessionStart orientation shows a `failed` status and retries.
- `map [--root <dir>] [--name <n>] [--local] [--create-vault] [--adopt]`: first contact; never
  prompts. Resolves vault and root, creates `projects/<name>/` and records the mapping
  through `lore-map.sh set` (committed through `commit`). Emits `OUTCOME=applied|unchanged`,
  `CHANGED`, `NAME`, `TARGET=tracked|local`, `ROOT` (and `TRACKED_FILES`). Exit 0 done,
  2 usage or the root is the vault, 10 a human must decide (`NEED=vault|name|migrate|jq`,
  `SUGGESTED=<name>-2` with `name`; nothing written) or the commit was refused (vault off its
  default branch), 20 resolution or I/O failure. `--create-vault` creates the vault with
  `"state_dir": ".lore"`. Every `NEED` check runs before anything is created, so an exit 10
  leaves the vault untouched. `--adopt --name <existing>` re-attaches an existing
  `projects/<name>/` (moved checkout). A mapping whose root no longer exists on disk is stale and
  is replaced (`REPLACED=<old root>`); when the old root still exists, exit 10 `NEED=owner` +
  `OWNER=<root>`, nothing written. Exit 2 when the folder does not exist.
- `project [--root <dir>]`: read-only lookup for clients that must not do first contact. Same
  resolution as `map`; writes nothing and creates no worktree. Emits `NAME`, `ROOT`. Exit 0 mapped,
  2 usage or the folder does not exist, 10 not mapped (`NEED=map`; run `/lore start`), 20 resolution failure.
- `version`: emits `VERSION=<plugin version>` (`unknown` when not found), exit 0.

### The shim and the client calling convention

`claude/hooks/squad-env.sh` (SessionStart) installs a shim at
`${XDG_DATA_HOME:-$HOME/.local/share}/lore/bin/lore`: a few lines carrying
`LORE_PLUGIN_DIR=` and `LORE_VERSION=` before an `exec` of the plugin's
`claude/hooks/lore`. It is replaced with a temp file and `mv`, only when the
running plugin's version (from `plugin.json`) is the same or newer than the
installed one, so an older plugin never downgrades it. It is not added to
PATH; the session env exports `LORE_BIN` (the shim path) and `LORE_STATE_DIR`.

If the plugin directory the shim points at is gone, `lore event` still exits 0
silently (the client contract); every other verb prints `lore: plugin not found
at <dir>` to stderr and exits 20. The newest SessionStart wins between a dev
checkout and the released plugin at the same version (same version replaces);
an older dev checkout never replaces a newer shim. `LORE_BIN` is not exported
when neither `XDG_DATA_HOME` nor `HOME` is set.

Clients (other plugins' hooks, headless runs) call it as below. A missing shim
means do nothing: exit 0, write nothing.

```bash
LORE="${LORE_BIN:-$HOME/.local/share/lore/bin/lore}"
[ -x "$LORE" ] || exit 0
"$LORE" <verb> ...
```

## Exception: `squad-stats.py report`

A `gh` failure while reading PR outcomes does not exit 20: the report is
written without its GitHub section, `QUALITY=gh-error` is emitted and the
exit code is 0. The report is still useful without that section. `collect`
and every other failure follow the contract above.

## Idempotency

Re-running an applied transition exits 0 with `OUTCOME=unchanged`.
Re-recording an existing checklist line exits 0 with `unchanged` and adds
no duplicate.

## Mode and `--handoff`

Scripts resolve mode by running `path-resolve.sh` (`TRACKER_MODE`), never
by re-parsing config. In detached mode scripts make zero `gh` calls,
reads included, and `squad_gh_write` refuses with 20. `--handoff <path>`
is required in detached mode and ignored in connected mode.

## Facades

`hooks/squad-tracker.sh` and `hooks/squad-vcs.sh` follow this contract: stdout
is `KEY=VALUE` lines (list verbs repeat a block, blocks separated by a blank
line), exit 0 ok / 2 usage / 10 precondition or unsupported verb / 20
failure. Documented stdout exceptions: `squad-vcs.sh pr-data` (one JSON
object), `description-get` (the PR body verbatim), `diff` (a unified diff) and
`pr-list` (display lines). Adapters live in `hooks/tracker/<provider>.sh` and
`hooks/vcs/<provider>.sh`; see the README, "Tracker and VCS facades".

An adapter that does not load (no such provider file) is a failure (20) for
`squad-tracker.sh` and `squad-labels.sh` state transitions, never a fallback to
the GitHub label machine. An adapter defining `tracker_set_state` (Jira) owns
`claim`, `set-state` and the `squad-labels.sh` verbs; a transition it cannot make
exits 10 with `REASON=` on stdout (no mapping, or no live transition to the
status).

Write policy (#400): a write verb that the project's `chisel.writes.<facade>`
list does not name (or, without the key, that the provider default excludes) is
refused by the facade before any adapter runs: stdout `REASON=policy: <verb> not
allowed on <project>`, exit 20. `squad-pr-desc.sh apply` in that case writes the
handoff file (`--issue`, `--handoff`), emits `OUTCOME=refused` and exits 20.
`squad-labels.sh` on `escalate` without `comment` still moves the labels and
emits `COMMENT=skipped` and the `REASON`. Callers treat the refusal as a normal
failure to record, never retry it, and continue.

## Library

Function return codes (the header of `squad-common.sh` is authoritative):

| Function | Returns |
|---|---|
| `squad_resolve` | 0 / 20 |
| `squad_tracker`, `squad_vcs` | the verb'"'"'s own code: 0 / 2 / 10 (also: verb unsupported by the provider) / 20 |
| `squad_provider_write`, `squad_write_guard` | 0 / 20 (the CLI'"'"'s stdout is redirected to stderr; detached mode refuses with 20) |
| `squad_policy_check`, `squad_policy_allows` | 0 / 20 (`check` prints `REASON=policy: ...`); `allows` is silent, 0 or 1 |
| `squad_gh_write` | 0 / 20, the github adapter'"'"'s raw-argv write path |
| `squad_record_local` | 0 changed / 1 unchanged / 20 I/O error |
| `squad_emit` | 0 / 2 |

`squad_fail <code> <reason>` writes the reason to stderr and exits.

The 1 from `squad_record_local` is library-only and is never a script exit
code; the script exit codes remain 0/2/10/20 above. Callers under `set -e`
must guard it, because a return of 1 aborts them:
`squad_record_local ... || rc=$?`.
