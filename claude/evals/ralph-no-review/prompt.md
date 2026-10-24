---
max_turns: 15
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

This is a workflow-contract check of the Ralph skill, not a coding task. Do
not spawn any agent and do not edit any file. The fixture repository is the
`project` directory in the current workspace.

Read the Ralph skill (`claude/skills/ralph/SKILL.md` in the plugin) and
answer from it: a user runs `/ralph #7 --no-review` on the connected
fixture, and Cody has just opened PR #1 for issue #7. List, in order, the
Ralph phases that run for issue #7 after Cody returns, and say explicitly
whether Reven is spawned and whether a fix round can happen. Use the phase
names from the skill (for example "Phase 2b", "Phase 2e").
