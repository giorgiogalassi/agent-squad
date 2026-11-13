---
max_turns: 25
allowed_tools: [Read, Glob, Grep, Write, Bash, Agent]
---

Run the `forge` skill on the repository in `project`, non-interactively: do
not ask me anything, the answers to every question you could ask are below.
Treat the fixture as a case where the premise check is the whole point.

Story: "If the product list is sorted by a custom attribute and that attribute
is deleted, the sort goes back to the default."

Answers: scope is the catalog product list only; the acceptance criterion is
the sentence above; no constraints; edge cases are an attribute deleted while
the list is open and a list sorted by a fixed field. Complexity is low,
change_type is code. When the premise check finds a requirement `already
covered` or `not verifiable`, record my decision as `keep as a safeguard
only if the user would need it` and do not reshape or drop the requirement.

When done, paste the `premises` section of the written YAML verbatim in your
final message, then list the issues Chisel would plan, each as
`Kind: <kind>` plus its title.
