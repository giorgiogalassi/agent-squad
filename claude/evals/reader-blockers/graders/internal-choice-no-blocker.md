---
type: regex
target: last_message
pattern: "RUN B.{0,3000}?###\\s*Blockers\\s*\\n\\s*-?\\s*none\\b.{0,200}?RUN C"
flags: "is"
weight: 1
---
