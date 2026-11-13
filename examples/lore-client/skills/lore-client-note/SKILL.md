---
name: lore-client-note
description: Example skill of the lore-client plugin. Use when asked to "record a lore-client note": it writes one note event through the lore API from a Bash step.
allowed-tools: Bash
---

# lore-client note

Run this Bash step with the note text as the last argument; it writes one
`note` event (kept as one line per key under "Other sources" in the project's
status after the next fold):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lore-event.sh" note lore-client-note "<note text>"
```

First contact with a project is `/lore start` (from the lore command surface).
If the project is not mapped or the shim is missing, the step writes nothing
and exits 0; say so to the user and stop.
