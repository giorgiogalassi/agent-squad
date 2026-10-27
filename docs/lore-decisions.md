# Recording decisions (vault rule)

Paste this into the vault `CLAUDE.md`:

> A session that records a decision calls `lore decide "<title>: <body>"`
> (add `--rule` for a project-wide review rule). When the decision replaces an
> earlier one it passes `--supersedes "<YYYY-MM-DD> <title>"`. Do not append to
> `projects/<name>/decisions.md` by hand.

## What enforces it

- `claude/hooks/lore-decide.sh` writes the entry (`## [YYYY-MM-DD] [rule] <title>`),
  applies both markers, archives fully superseded entries over 60 active, warns
  over 60 active or 15 active `[rule]` entries, and commits the vault.
- `claude/hooks/decisions-lint.sh` is the single implementation of the checks
  (`check`, `fix`, `render`; one `KEY=value` line per finding, SCRIPT_CONTRACT.md).
  The SessionEnd hook runs it on `decisions.md`:
  - an entry with `Supersedes:` whose target lacks the inverse marker gets it
    (deterministic, text is never rewritten or deleted);
  - a new entry citing an earlier `[YYYY-MM-DD]` of the same file without a
    `Supersedes:` / `Supersedes in part:` line is left in
    `projects/<name>/.decisions-lint`, which `lore-orient.sh` prints at the next
    SessionStart;
  - `- [YYYY-MM-DD]` bullet entries are counted (invisible to the decisions window).
- A later `lore check` (#333) calls `decisions-lint.sh check` for the same lines.

## Partial supersession

`Superseded in part by: [YYYY-MM-DD] <title>` (older entry) and
`Supersedes in part: [YYYY-MM-DD] <title>` (newer entry). The older entry stays
active and keeps loading; only a full `Superseded by:` line deactivates it.
