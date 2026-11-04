# lore-client (example)

A minimal plugin that is not agent-squad and writes through the lore API only:
`"${LORE_BIN:-$HOME/.local/share/lore/bin/lore}" event ...`. It is an example
and a test fixture (`scripts/test-lore-client.sh`), outside `claude/`, and is not
part of the agent-squad marketplace.

- `agents/lore-client-worker.md` + `hooks/checkpoint.sh`: a SubagentStop hook
  that filters on its own agent and emits a `checkpoint` event.
- `skills/lore-client-note`: a Bash step that emits a `note` event.
- Mapping: `/lore start` (never the client itself) once per project.
- No shim installed: every call exits 0 and writes nothing.
