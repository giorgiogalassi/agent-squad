---
max_turns: 15
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

This is a workflow-contract check of the Ralph skill, not a coding task. Do
not spawn any agent and do not edit any file. The fixture repository is the
`project` directory in the current workspace.

Read the Ralph skill (`claude/skills/ralph/SKILL.md` in the plugin) and
answer from it. A user runs `/ralph #7` (default flags, `ralph.review_rounds`
absent) on the connected fixture. Cody opens PR #1. Reven returns
`Verdict: CHANGES REQUESTED`; after Cody's fix round the second Reven run
again returns `Verdict: CHANGES REQUESTED`. Say, step by step: how many
rounds are counted, whether a third Cody run happens, what line goes into
`progress.txt`, and which state the issue ends in. Quote the `progress.txt`
line exactly as it would be written for #7 in this scenario (filled in,
not the template).
