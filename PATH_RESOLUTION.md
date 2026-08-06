# Path Resolution

The algorithm behind `path-resolve.sh`, the shared utility every skill
and agent's "Path resolution protocol" (or equivalent "Resolve paths
before reading any file" / "Deduce candidate project name") calls as its
first step.

> **This document is not read by any skill or agent at runtime — the
> script is.** That distinction matters and is deliberate. Iteration 19
> (see `JOURNAL.md`) removed the squad's shared runtime-context files on
> the grounds that nothing in the runtime depended on them: skills stayed
> self-contained, so a file only humans read couldn't drift from what the
> runtime actually did, because the runtime didn't touch it. That
> principle is why this fix lives in a *script*, not a *skill* other
> skills invoke: a skill has no return-value semantics — "call the
> orient skill" means "load its prose into context and hope the model
> acts on it," which is exactly the kind of soft dependency Iteration 19
> rejected. A script has none of that ambiguity: every skill already runs
> Bash commands as a matter of course (`git rev-parse`, `date`, `mkdir
> -p`), so "run this script" is not a new category of instruction, and
> its output is unambiguous, parseable text, not advisory prose. This
> document exists purely so a human updating the algorithm has the
> rationale and the verification in one place — it is never the thing a
> skill loads.

## The bug

Every skill's path resolution protocol used to start from `git rev-parse
--show-toplevel` to find the project root, then look that path up in
`<vault>/lore-config.json`'s `projects` map (keyed by absolute CWD path),
or take its basename as a fallback project name.

That breaks the moment a skill runs inside a linked git worktree — which
Sidecar's worktrees are. `--show-toplevel` returns the *linked worktree's
own* directory, not the main repository's. Verified directly, in a
throwaway repo with one linked worktree:

```
main toplevel:   /tmp/wt-test/main
linked toplevel: /tmp/wt-test/linked
```

Different absolute path, different basename. A skill invoked from inside
a Sidecar worktree would fail the `lore-config.json` lookup entirely —
Seed's own protocol says what happens then: *"No vault mapping found for
this project. Run lore start first."* Worse, several skills fall back to
the CWD basename as the project name when no mapping exists, which means
`progress.txt`, `architecture.md`, `chisel-config.json`, and every other
vault file would silently read from and write to a namespace named after
the *branch* — fragmenting the very evidence trail Sidecar exists to
preserve.

## The fix

```bash
git rev-parse --path-format=absolute --git-common-dir
```

reliably returns the *main* repository's `.git` directory regardless of
which worktree the command runs from. Verified directly, same repo:

```
from MAIN:   /tmp/wt-test/main/.git
from LINKED: /tmp/wt-test/main/.git      # same answer, from the linked worktree
```

The project root is the parent of that path — correct uniformly, whether
the current directory is the main checkout or any linked worktree, no
conditional branching required. This is a native git primitive (`git
worktree` itself relies on the common-dir/git-dir split internally), not
a Sidecar-specific convention, so it's robust to worktrees created
outside Sidecar's own naming convention too.

`--path-format=absolute` requires git 2.31+ (released March 2021).
`path-resolve.sh` falls back to plain `git rev-parse --show-toplevel` if
the command fails, matching this project's existing "degrade gracefully,
don't hard-fail on a missing capability" convention (see Seed's "if a
file does not exist, continue without it").

## The script

`claude/hooks/path-resolve.sh` and `codex/hooks/path-resolve.sh` (kept
identical apart from a comment) implement the algorithm above plus the
`lore-config.json` lookup, and print three lines to stdout:

```
VAULT_PATH=<resolved vault path>
PROJECT_ROOT=<resolved project root, correct even inside a linked worktree>
DISPLAY_NAME=<mapped display name, or empty if none exists yet>
```

It reports facts, not policy. What a caller does with an empty
`DISPLAY_NAME` differs by skill — Seed stops and tells the user to run
`lore start`; Forge, Archy, Chisel, Ralph, and Sidecar fall back to the
basename of `PROJECT_ROOT` and continue; Lore is the one that creates the
mapping in the first place, so it reads `PROJECT_ROOT` and proceeds to
its own naming flow regardless. The script doesn't decide any of that —
every skill's own protocol still states its own policy inline, exactly
as before. Only the mechanical resolution step moved into the script.

Every skill and agent's protocol now reads:

> Run `~/.claude/hooks/path-resolve.sh` (Codex: `~/.codex/hooks/path-resolve.sh`)
> and read its three output lines: `VAULT_PATH`, `PROJECT_ROOT`,
> `DISPLAY_NAME`.

## What does NOT change

Actual git operations scoped to the current checkout — branch name,
diff, commit, push — stay relative to the real CWD (the worktree, when
running inside one). Only *vault/display-name resolution* uses the
recovered project root instead of the raw CWD. Two things that look like
this fix but deliberately aren't touched by it:

- Sidecar's own Phase 2 still uses `git -C <worktree-path> rev-parse
  --show-toplevel` to resolve the *worktree's own* absolute path for the
  `cd <worktree-path>` line it prints — correct as-is, not part of this
  fix.
- `lore-orient.sh`'s evidence section (`Branch: ...`, `Recent commits:
  ...`) intentionally uses the ambient working directory, not
  `PROJECT_ROOT` — a session's branch/commit evidence should reflect
  wherever it actually is, which may be a Sidecar worktree on a different
  branch than the main checkout. Only the vault lookup needed the
  common-dir fix; the evidence-gathering git calls were changed from `git
  -C "$ROOT"` to plain `git` for exactly this reason.

## Installing the script

`path-resolve.sh` is a required dependency now, not an optional hook —
every skill's first step calls it. It installs alongside `lore-orient.sh`
(which itself now calls it too, with a defensive inline fallback if it's
somehow missing — see the hook's own comments):

```bash
# Claude Code
cp claude/hooks/path-resolve.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/path-resolve.sh

# Codex
cp codex/hooks/path-resolve.sh ~/.codex/hooks/ && chmod +x ~/.codex/hooks/path-resolve.sh
```

See `README.md`'s Installation section for the full install sequence.

## Files carrying this fix

Both trees, kept in parity (grep for `path-resolve.sh` to verify):

- `claude/skills/{forge,archy,chisel,ralph,seed,sidecar}/SKILL.md` and
  the `codex/` equivalents
- `claude/agents/{cody,reven,lore}.md` and the `codex/` equivalents
  (`.toml` for Codex)
- `claude/hooks/lore-orient.sh` and `codex/hooks/lore-orient.sh`
- `claude/hooks/path-resolve.sh` and `codex/hooks/path-resolve.sh` — the
  actual implementation; everything else calls these two.
