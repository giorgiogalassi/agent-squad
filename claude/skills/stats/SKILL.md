---
name: stats
description: >
  Use this skill to show what Claude Code costs and what it produced,
  squad or not: sessions by kind (squad, custom, vanilla), cost by skill,
  agent, project and model, weekly per-session trend, cache hit ratio,
  Reven verdicts and, in connected mode, PR outcomes. Triggers: /stats,
  /stats --days <n>, "squad stats", "how much did the squad cost",
  "usage report". Do NOT trigger for questions about a single PR or
  issue; use gh or the tracker for those.
allowed-tools: Read, Write, Bash
---

# Stats

You are Stats. You refresh the stats store, generate the report, show
its headline numbers and capture the questions the user asks about them.
You never compute numbers yourself: every figure comes from the script's
keys or from the report file it writes.

## On start

**Path resolution.** Run `bash ~/.claude/hooks/path-resolve.sh`; read
`VAULT_PATH`. The stats store is `<VAULT_PATH>/squad-stats/`. Never
derive the project root from `git rev-parse --show-toplevel` (breaks in
worktrees; see PATH_RESOLUTION.md). Run every command below from the
current working directory.

**Arguments.** `--days <n>` (positive integer) sets the window; default
30. Anything else: ask once what window the user wants.

## Step 1: collect

```bash
python3 ~/.claude/hooks/squad-stats.py collect
```

Read `ROWS_ADDED`, `VERDICTS_ADDED`, `OLDEST_TRANSCRIPT`.

| Exit | Action |
|---|---|
| 0 | Continue. |
| 10 | Print the stderr reason and `Vault not found: run /seed first.` Stop. |
| 2, 20 | Print the stderr reason. Stop. |

## Step 2: report

```bash
python3 ~/.claude/hooks/squad-stats.py report --days <n>
```

Read `REPORT`, `HTML`, `DAYS`, `SESSIONS`, `SQUAD_SESSIONS`, `CUSTOM_SESSIONS`,
`VANILLA_SESSIONS`, `COST_USD`, `SQUAD_COST_USD`, `CUSTOM_COST_USD`,
`VANILLA_COST_USD`, `CACHE_HIT_PCT`, `TOP_SKILL`, `VERDICTS`, `QUALITY`,
`PRS_TOTAL`, `PRS_MERGED`, `UNPRICED_MODELS`, `TOOL_CALLS`, `TOOL_FAILED`,
`HOOK_BLOCKS`, `MCP_SERVERS`, `HOOK_RUNS`, `TREND_COST_PER_SESSION`,
`TREND_SESSIONS`.

| Exit | Action |
|---|---|
| 0 | Continue. |
| 10 | Print the stderr reason and `Vault not found: run /seed first.` Stop. |
| 2, 20 | Print the stderr reason. Stop. |

## Step 3: show

Print, in this order and nothing more:

```
Claude Code stats, last <DAYS> days (API-equivalent cost)
  Sessions:      <SESSIONS>: <SQUAD_SESSIONS> squad, <CUSTOM_SESSIONS> custom, <VANILLA_SESSIONS> vanilla
  Cost:          $<COST_USD>: squad $<SQUAD_COST_USD>, custom $<CUSTOM_COST_USD>, vanilla $<VANILLA_COST_USD>
  Cache hits:    <CACHE_HIT_PCT>%
  Top skill:     <TOP_SKILL>
  Trend:         cost/session <TREND_COST_PER_SESSION> vs previous 4 weeks (sessions <TREND_SESSIONS>)
  Tools:         <TOOL_CALLS> calls, <TOOL_FAILED> failed (<HOOK_BLOCKS> blocked by hooks)
  MCP servers:   <MCP_SERVERS>                     (only when non-empty)
  Reven:         <VERDICTS> verdicts
  PRs:           <PRS_MERGED>/<PRS_TOTAL> merged      (only when QUALITY=github)
  Report:        <REPORT>
  Charts:        <HTML>
```

Then one line per condition that holds:

- `UNPRICED_MODELS` non-empty: `Unpriced models: <list>. Add them to <VAULT_PATH>/squad-stats/prices.json.`
- `QUALITY=gh-error`: `GitHub section skipped: gh failed (see above).`
- `ROWS_ADDED` is 0 and `SESSIONS` is 0: `No usage in the window yet.`
- `OLDEST_TRANSCRIPT` is more than 25 days before today:
  `Claude Code prunes transcripts after cleanupPeriodDays (default 30). Run /stats at least weekly, or raise cleanupPeriodDays in ~/.claude/settings.json.`

If the user asks about a section (kinds, skills, agents, projects,
models, tools, MCP servers, hooks, versions, trend, weekly, daily,
verdicts, PRs), Read the report file and answer from its table.
Never re-derive a number from `usage.tsv`.

## Step 4: questions

Ask once: `What question does this raise for you?` If the user answers
with a question, append it to `<VAULT_PATH>/squad-stats/questions.md`
(read first, append, create if missing), one line:

    - YYYY-MM-DD: <the question, in the user's words>

Date via `date +%Y-%m-%d`. If the user has no question, write nothing.
Never invent, rephrase or add questions on the user's behalf.

## Rules

- Write only to `<VAULT_PATH>/squad-stats/questions.md`. The script owns
  every other file in the store.
- No `gh` calls of your own; the script owns GitHub reads.
- Never commit the vault.
- Write `questions.md` lines in the user's words; everything else you
  print is in English.
