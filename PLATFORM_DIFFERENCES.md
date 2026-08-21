# Platform Differences (historical)

This file used to document the semantic and technical differences between
two parallel distributions in this repo: `claude/` and a `codex/` tree that
implemented the same Agent Squad workflow for Codex.

On 2026-08-21 the repository owner decided to drop the Codex distribution
(#148). The `codex/` tree, its install instructions, and this file's
line-by-line comparison no longer have a subject — Agent Squad is a
single-platform (Claude Code) project now. The detailed comparison that
used to live here (Seed's invocation patterns, Ralph's orchestration model,
Forge's confirmation-tool difference, agent file formats, the Codex skill
install path, and the rest) is preserved in git history at this file's last
version before the deletion, not repeated here.

See `JOURNAL.md` for the full rationale behind maintaining two trees in the
first place, and the entry recording why that decision was reversed.
