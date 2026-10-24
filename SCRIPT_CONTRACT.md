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

gh and git exit codes are never passed through (gh's own 4 means auth
required; it surfaces as 20). Stderr carries one human-readable reason
line.

## Exception: `squad-incidents.sh record`

`record` writes nothing to stdout and always exits 0, even on its own I/O
errors, so failure paths in other scripts can call it safely. It is
best-effort capture, not a verb whose result callers act on. The other
verbs (`summary`, `resolve`) follow the contract above.

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

## Library

Function return codes (the header of `squad-common.sh` is authoritative):

| Function | Returns |
|---|---|
| `squad_resolve` | 0 / 20 |
| `squad_gh_write` | 0 / 20 (gh stdout is redirected to stderr) |
| `squad_record_local` | 0 changed / 1 unchanged / 20 I/O error |
| `squad_emit` | 0 / 2 |

`squad_fail <code> <reason>` writes the reason to stderr and exits.

The 1 from `squad_record_local` is library-only and is never a script exit
code; the script exit codes remain 0/2/10/20 above. Callers under `set -e`
must guard it, because a return of 1 aborts them:
`squad_record_local ... || rc=$?`.
