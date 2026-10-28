---
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash]
---

This is a hook-contract check, not a coding task. The fixture repository is
the `project` directory in the current workspace, and `worktree` is a linked
git worktree of it on branch `fixture-wt`.

Simulate the SessionStart hook of a session that started inside the worktree:
run the plugin's orientation script once, from the `project` directory, with
the hook JSON on stdin (use the absolute path of `worktree` as `cwd`):

```
printf '{"source":"startup","cwd":"<absolute path of worktree>","session_id":"eval-orient-1"}' | bash <plugin root>/hooks/lore-orient.sh
```

In this run Bash is restricted to that one command shape and `git ...`; use
one command per call and no other utilities.

Your final answer must quote, verbatim from the script's JSON output, the
`sessionTitle` value and the line that starts with `Branch:` from the
`### Worktree session` block of `additionalContext`.
