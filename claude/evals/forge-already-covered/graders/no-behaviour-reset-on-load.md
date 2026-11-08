---
type: regex
target: last_message
pattern: "^(?!.*Kind:\\s*behaviour[^\\n]{0,200}(?:reset|default)[^\\n]{0,120}(?:load|reload|definitions)).*$"
flags: "is"
weight: 1
---
