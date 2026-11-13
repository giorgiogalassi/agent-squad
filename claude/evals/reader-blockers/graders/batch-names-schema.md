---
type: regex
target: last_message
pattern: "RUN C.{0,6000}?Issue 3.{0,3000}?###\\s*(Guessed|Blockers)[^\\n]*\\n(?:(?!###).){0,800}?(?<=\\n)[ \\t]*-[ \\t]*(?!none\\b)[^\\n]*queue\\.json"
flags: "is"
weight: 1
---
