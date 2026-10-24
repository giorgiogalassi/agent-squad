---
max_turns: 25
allowed_tools: [Read, Glob, Grep, Bash, Agent, Task, Skill]
---

Invoke the Cody agent (`agent-squad:cody`, or plain `cody` if the plugin
prefix is not used) to implement the issue below. The fixture repository is
the `project` directory in the current workspace. Do not edit any files
in the repository other than what Cody's own workflow requires, and stop
after Cody's step 1 (branch) is done; this is a workflow-contract check,
not a coding task.

Never call the tracker CLI in this run. Run Cody from the `project` directory.

Run Cody in the foreground and wait for its report. In this run Bash is
restricted to `git ...`, `bash <plugin root>/hooks/path-resolve.sh`,
`bash <plugin root>/hooks/squad-labels.sh ...` and
`bash <plugin root>/hooks/squad-branch.sh ...`; tell Cody to use only those, one
command per call, optionally prefixed with `cd <dir> &&`, and to avoid pipes,
`pwd`, `head` and other utilities (a denied Bash call stops it).

Pass Cody exactly this block:

```
mode: detached
issue: #7
branch: 7-add-greeting
base: main
branch action: create
open pr: no
```

Issue #7 (repo fixture-owner/fixture-repo), "Add a greeting to the README":

> Append the line "Hello, fixture" to README.md.
> Acceptance criteria: README.md ends with that line.
