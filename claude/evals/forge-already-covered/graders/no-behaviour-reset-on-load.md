---
type: regex
target: last_message
pattern: "^(?!.*Kind:\\s*behaviour[^\\n]{0,200}(?:(?:reset|default)[^\\n]{0,120}(?:load|reload|definitions)|sort[^\\n]{0,120}attribute[^\\n]{0,80}(?:missing|deleted)(?![^\\n]*(?:load|reload|definitions)))).*$"
flags: "is"
weight: 1
---
