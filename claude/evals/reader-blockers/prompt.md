---
max_turns: 15
allowed_tools: [Read, Glob, Grep, Agent]
---

This is a contract check of the reader agent, not a coding task. Do not
edit any file. The fixture repository is the `project` directory in the
current workspace; it contains no config schema, no parser and no other
code relevant to the issues below.

Spawn the `reader` agent three times, one brief per run, and paste each
run's output verbatim under the label "RUN A", "RUN B" and "RUN C".

RUN A. Excerpt (single issue, key 1): "Add a field to the config so users
can tune the retry behaviour."

RUN B. Excerpt (single issue, key 1): "Make the script print the string
`done` as its last line. Use whatever loop style you prefer to walk the
list of names inside the script."

RUN C. Excerpt (batch of two). Issue 2: "Create `queue.json` with the
fields `id` (string) and `due` (ISO date), written by `enqueue.sh`." Issue
3: "Add `drain.sh`, which reads `queue.json` and prints each entry."

Each brief has Proposal and Goal lines you write yourself in one sentence.
