#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-stats.py. Plain bash 3.2; no bats.
# Usage: scripts/test-squad-stats.sh [path/to/squad-stats.py]
# Transcripts, vault and store all live in a temp dir; gh is a local fake.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="${1:-$REPO_ROOT/claude/hooks/squad-stats.py}"
[ -f "$SUT" ] || { echo "error: $SUT not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 required" >&2; exit 2; }
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-stats.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }
run() { OUT="$(python3 "$SUT" "$@" 2>"$TMPROOT/err")"; RC=$?; }

# The script must sit next to path-resolve.sh, as it does in the plugin hooks/ dir.
HOOKS="$TMPROOT/hooks"; mkdir -p "$HOOKS"
cp "$SUT" "$HOOKS/squad-stats.py"
cp "$REPO_ROOT/claude/hooks/path-resolve.sh" "$HOOKS/"
SUT="$HOOKS/squad-stats.py"

export SECOND_BRAIN_PATH="$TMPROOT/vault"; mkdir -p "$SECOND_BRAIN_PATH"
export CLAUDE_PROJECTS_DIR="$TMPROOT/projects"
export SQUAD_STATS_NOW="2026-10-15T00:00:00Z"
unset SQUAD_STATS_DIR CLAUDE_CONFIG_DIR
STORE="$SECOND_BRAIN_PATH/squad-stats"

APP="$TMPROOT/work/app"; mkdir -p "$APP"
git -C "$APP" init -q
printf '{"projects":{"%s":"app-display"}}\n' "$APP" > "$SECOND_BRAIN_PATH/lore-config.json"

# ---- fixtures ----------------------------------------------------------
P1="$CLAUDE_PROJECTS_DIR/-work-app"; mkdir -p "$P1/s1/subagents"
P2="$CLAUDE_PROJECTS_DIR/-work-other"; mkdir -p "$P2"
P3="$CLAUDE_PROJECTS_DIR/-work-third"; mkdir -p "$P3/s3/subagents"
U='"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s},"cache_read_input_tokens":%s,"output_tokens":%s}'
asst() {  # asst <ts> <id> <model> <in> <cw> <cw1h> <read> <out> <session> <cwd>
  printf '{"type":"assistant","timestamp":"%s","sessionId":"%s","cwd":"%s","message":{"id":"%s","model":"%s",'"$U"',"content":[{"type":"text","text":"x"}]}}\n' \
    "$1" "$9" "${10}" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}
{
  printf '{"type":"user","timestamp":"2026-10-14T10:00:00.000Z","sessionId":"s1","cwd":"%s","message":{"role":"user","content":"<command-name>/agent-squad:ralph</command-name>"}}\n' "$APP"
  asst 2026-10-14T10:01:00.000Z msg_1 claude-opus-5-5 100000 200000 50000 1000000 5000 s1 "$APP"
  asst 2026-10-14T10:01:00.500Z msg_1 claude-opus-5-5 100000 200000 50000 1000000 10000 s1 "$APP"
  printf '{"type":"user","timestamp":"2026-10-14T10:30:00.000Z","sessionId":"s1","cwd":"%s","message":{"role":"user","content":"<command-name>/clear</command-name>"}}\n' "$APP"
  asst 2026-10-14T10:31:00.000Z msg_2 claude-opus-5-5 10000 0 0 0 1000 s1 "$APP"
  printf '{"type":"assistant","timestamp":"2026-10-14T10:32:00.000Z","sessionId":"s1","message":{"id":"msg_syn","model":"<synthetic>","usage":{"input_tokens":5,"output_tokens":5}}}\n'
  printf '{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-14T10:40:00.000Z","sessionId":"s1","uuid":"h1","hookInfos":[{"command":"~/.claude/stop-check.sh","durationMs":55}],"hookErrors":[],"hookAdditionalContext":[],"preventedContinuation":false}\n'
} > "$P1/s1.jsonl"
asst 2026-10-14T10:10:00.000Z msg_c1 claude-sonnet-5-5 50000 0 0 0 100000 s1 "$APP" > "$P1/s1/subagents/agent-a1.jsonl"
echo '{"agentType":"cody"}' > "$P1/s1/subagents/agent-a1.meta.json"
printf '{"type":"assistant","timestamp":"2026-10-14T10:20:00.000Z","sessionId":"s1","message":{"id":"msg_r1","model":"claude-sonnet-5-5","usage":{"input_tokens":20000,"output_tokens":30000},"content":[{"type":"text","text":"Summary\\nVerdict: CHANGES REQUESTED\\nmore"}]}}\n' > "$P1/s1/subagents/agent-r1.jsonl"
echo '{"agentType":"reven"}' > "$P1/s1/subagents/agent-r1.meta.json"
{
  printf '{"type":"user","timestamp":"2026-10-14T10:59:00.000Z","sessionId":"s2","cwd":"/work/other","message":{"role":"user","content":"<command-name>/init</command-name>"}}\n'
  asst 2026-10-14T11:00:00.000Z msg_h1 claude-haiku-5-5 1500000 0 0 0 100000 s2 /work/other
  asst 2026-10-14T11:01:00.000Z msg_h2 claude-haiku-5-5 50000 0 0 0 10000 s2 /work/other
  asst 2026-10-14T11:02:00.000Z msg_u1 claude-unknown-9 10 0 0 0 10 s2 /work/other
  asst 2026-08-01T11:00:00.000Z msg_old claude-opus-5-5-20260101 1000000 0 0 0 0 s2 /work/other
} > "$P2/s2.jsonl"

# s3: custom plugin command, then a custom skill via the Skill tool, then a custom agent.
{
  printf '{"type":"user","timestamp":"2026-10-14T12:00:00.000Z","sessionId":"s3","cwd":"/work/third","message":{"role":"user","content":"<command-name>/My-Plugin:deploy</command-name>"}}\n'
  asst 2026-10-14T12:01:00.000Z msg_d1 claude-opus-5-5 100000 0 0 0 0 s3 /work/third
  printf '{"type":"assistant","timestamp":"2026-10-14T12:02:00.000Z","sessionId":"s3","message":{"id":"msg_t1","model":"claude-opus-5-5","usage":{"input_tokens":100000,"output_tokens":0},"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"tokensave"}}]}}\n'
  asst 2026-10-14T12:03:00.000Z msg_t2 claude-opus-5-5 100000 0 0 0 0 s3 /work/third
  printf '{"type":"user","timestamp":"2026-10-14T12:05:00.000Z","sessionId":"s3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}\n'
  printf '{"type":"user","isMeta":true,"timestamp":"2026-10-14T12:06:00.000Z","sessionId":"s3","message":{"role":"user","content":"injected"}}\n'
  asst 2026-10-14T12:07:00.000Z msg_t3 claude-opus-5-5 100000 0 0 0 0 s3 /work/third
  printf '{"type":"user","timestamp":"2026-10-14T12:10:00.000Z","sessionId":"s3","message":{"role":"user","content":"next question"}}\n'
  asst 2026-10-14T12:11:00.000Z msg_t4 claude-opus-5-5 100000 0 0 0 0 s3 /work/third
} > "$P3/s3.jsonl"
asst 2026-10-14T12:04:00.000Z msg_m1 claude-sonnet-5-5 100000 0 0 0 0 s3 /work/third > "$P3/s3/subagents/agent-m1.jsonl"
echo '{"agentType":"my-reviewer"}' > "$P3/s3/subagents/agent-m1.meta.json"

# s4: vanilla session with an MCP server, a message split over two lines,
# and failed calls stopped by a hook, the classifier and the tool itself.
P4="$CLAUDE_PROJECTS_DIR/-work-fourth"; mkdir -p "$P4"
TU='{"type":"assistant","timestamp":"%s","sessionId":"s4","cwd":"/work/fourth","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":%s,"output_tokens":0},"content":[{"type":"tool_use","id":"%s","name":"%s","input":{}}]}}\n'
TR='{"type":"user","timestamp":"%s","sessionId":"s4","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":%s,"content":"%s"}]}}\n'
{
  printf "$TU" 2026-10-14T13:00:00.000Z msg_x1 1 u1 mcp__demo__lookup
  printf "$TU" 2026-10-14T13:00:00.100Z msg_x1 100000 u2 Grep
  printf "$TR" 2026-10-14T13:00:01.000Z u1 false "ok"
  printf "$TR" 2026-10-14T13:00:01.000Z u2 true "PreToolUse:Grep hook error: blocked, use demo lookup"
  printf "$TU" 2026-10-14T13:01:00.000Z msg_x2 100000 u3 Bash
  printf "$TR" 2026-10-14T13:01:01.000Z u3 true "Exit code 1: ~/.claude/hooks/path-resolve.sh not found"
  printf "$TU" 2026-10-14T13:02:00.000Z msg_x3 100000 u4 Edit
  printf "$TR" 2026-10-14T13:02:01.000Z u4 true "Permission for this action was denied by the Claude Code auto mode classifier. Reason: [x]"
} > "$P4/s4.jsonl"

# ---- usage errors and preconditions --------------------------------------
run; check "no verb exits 2" 2 "$RC"
run bogus; check "unknown verb exits 2" 2 "$RC"
run report --days x; check "bad --days exits 2" 2 "$RC"
SECOND_BRAIN_PATH="$TMPROOT/missing/vault" run collect
check "missing vault exits 10" 10 "$RC"

# ---- collect -------------------------------------------------------------
run collect
check "collect exit 0" 0 "$RC"
check "collect OUTCOME applied" applied "$(key OUTCOME)"
check "ROWS_ADDED 17 (dedup by id, synthetic skipped)" 17 "$(key ROWS_ADDED)"
check "VERDICTS_ADDED 1 (reven only)" 1 "$(key VERDICTS_ADDED)"
check "FILES_SCANNED 4" 4 "$(key FILES_SCANNED)"
check "STORE path" "$STORE" "$(key STORE)"
BAD="$(printf '%s\n' "$OUT" | grep -cvE '^[A-Z_]+=')"
check "stdout is KEY=value only" 0 "$BAD"
row() { awk -F'\t' -v id="$1" -v c="$2" '$12==id{print $c}' "$STORE/usage.tsv"; }
check "last line of a message wins" 10000 "$(row msg_1 11)"
check "cache write split 5m" 150000 "$(row msg_1 8)"
check "skill from namespaced command" ralph "$(row msg_1 5)"
check "/clear resets skill" "" "$(row msg_2 5)"
check "subagent inherits skill by time" ralph "$(row msg_c1 5)"
check "subagent agent type" cody "$(row msg_c1 4)"
check "project from lore-config" app-display "$(row msg_1 3)"
check "project fallback basename" other "$(row msg_h1 3)"
check "prompt built-in recorded" builtin:init "$(row msg_h1 5)"
check "custom plugin command keeps prefix" my-plugin:deploy "$(row msg_d1 5)"
check "Skill tool switches to a custom skill" tokensave "$(row msg_t2 5)"
check "custom agent type" my-reviewer "$(row msg_m1 4)"
check "tools gathered across lines of one message" "mcp__demo__lookup,Grep" "$(row msg_x1 13)"
check "usage from the last line of the message" 100000 "$(row msg_x1 7)"
check "hook block classified" "hook:Grep" "$(row msg_x1 14)"
check "tool failure classified" "error:Bash" "$(row msg_x2 14)"
check "classifier denial classified" "classifier:Edit" "$(row msg_x3 14)"
check "custom agent inherits custom skill" tokensave "$(row msg_m1 5)"
check "loaded skill survives tool results and injected messages" tokensave "$(row msg_t3 5)"
check "loaded skill ends at next user message, command resumes" my-plugin:deploy "$(row msg_t4 5)"

run collect
check "re-collect unchanged" unchanged "$(key OUTCOME)"
check "re-collect adds nothing" 0 "$(key ROWS_ADDED)"

# ---- report, detached ------------------------------------------------------
( cd "$APP" && python3 "$SUT" report --days 30 ) > "$TMPROOT/out" 2>"$TMPROOT/err"; RC=$?
OUT="$(cat "$TMPROOT/out")"
check "report exit 0" 0 "$RC"
check "COST_USD (window excludes old row, haiku tiers)" 7.86 "$(key COST_USD)"
check "SESSIONS" 4 "$(key SESSIONS)"
check "SQUAD_SESSIONS" 1 "$(key SQUAD_SESSIONS)"
check "CUSTOM_SESSIONS" 1 "$(key CUSTOM_SESSIONS)"
check "VANILLA_SESSIONS (MCP alone is not custom)" 2 "$(key VANILLA_SESSIONS)"
check "SQUAD_COST_USD (whole squad sessions)" 3.45 "$(key SQUAD_COST_USD)"
check "CUSTOM_COST_USD" 2.20 "$(key CUSTOM_COST_USD)"
check "VANILLA_COST_USD" 2.21 "$(key VANILLA_COST_USD)"
check "CACHE_HIT_PCT" 26 "$(key CACHE_HIT_PCT)"
check "TOP_SKILL" ralph "$(key TOP_SKILL)"
check "VERDICTS" 1 "$(key VERDICTS)"
check "QUALITY detached" skipped-detached "$(key QUALITY)"
check "UNPRICED_MODELS" claude-unknown-9 "$(key UNPRICED_MODELS)"
REPORT="$(key REPORT)"
[ -f "$REPORT" ] && ok "report file written" || bad "report file written ($REPORT)"
grep -q "CHANGES REQUESTED | 1 | 100%" "$REPORT" && ok "verdict table" || bad "verdict table"
check "TOOL_CALLS" 5 "$(key TOOL_CALLS)"
check "TOOL_FAILED" 3 "$(key TOOL_FAILED)"
check "HOOK_BLOCKS" 1 "$(key HOOK_BLOCKS)"
check "MCP_SERVERS" demo "$(key MCP_SERVERS)"
grep -q "| demo | 1 | 1 / 3 | \$1.20 / \$2.22 |" "$REPORT" && ok "MCP with/without row" || bad "MCP with/without row"
grep -q "| 2.0 / 0.0 |" "$REPORT" && ok "blocked calls per session" || bad "blocked calls per session"
grep -q "^| Grep | 1 | 20% | 1 | 1 | 1 | 0 | 0 | 0 | 0 |" "$REPORT" && ok "tool table" || bad "tool table"
grep -q "^| stop-check.sh | stop | 1 | 1 | 55 | 0 | 0 | 0 |" "$REPORT" && ok "hooks section" || bad "hooks section"
grep -q "^## By Claude Code version" "$REPORT" && ok "version section" || bad "version section"
grep -q "^| Cost per session | lower | n/a |" "$REPORT" && ok "trend: no previous period" || bad "trend: no previous period"
HTML="$(key HTML)"
check "HTML next to the Markdown report" "${REPORT%.md}.html" "$HTML"
grep -q "<svg" "$HTML" && ok "HTML has charts" || bad "HTML has charts"
grep -q "<td class=\"\">tokensave</td>" "$HTML" && ok "HTML has the tables" || bad "HTML has the tables"
grep -Eq "(src|href)=\"https?:" "$HTML" && bad "HTML is self-contained" || ok "HTML is self-contained"
grep -q "| ralph | yes | 1 |" "$REPORT" && ok "skill table, squad flag" || bad "skill table, squad flag"
grep -q "| tokensave | no | 1 |" "$REPORT" && ok "custom skill listed" || bad "custom skill listed"
grep -q "| my-reviewer | no | 1 |" "$REPORT" && ok "custom agent listed" || bad "custom agent listed"
grep -q "| vanilla | 2 | \$2.21 |" "$REPORT" && ok "vanilla kind row" || bad "vanilla kind row"
grep -q "^| 2026-W42 | 4 |" "$REPORT" && ok "weekly trend row" || bad "weekly trend row"

PRICES='{"unknown-9":[1000000,0,0,0,1000000]}'
printf '%s' "$PRICES" > "$STORE/prices.json"
( cd "$APP" && python3 "$SUT" report ) > "$TMPROOT/out" 2>/dev/null; OUT="$(cat "$TMPROOT/out")"
check "prices.json override" 27.86 "$(key COST_USD)"
rm -f "$STORE/prices.json"

# Native permissionDecision: a hook's own denial reason carries no marker
# in the text; the structured decision on the result line classifies it.
PD='{"type":"user","timestamp":"2026-10-14T14:00:01.000Z","sessionId":"s5","permissionDecision":%s,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":"%s"}]}}'
{
  printf '%s\n' '{"type":"assistant","timestamp":"2026-10-14T14:00:00.000Z","sessionId":"s5","cwd":"/work/fifth","version":"2.1.300","message":{"id":"msg_y1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":0},"content":[{"type":"tool_use","id":"y1","name":"Grep","input":{}},{"type":"tool_use","id":"y2","name":"Bash","input":{}}]}}'
  printf "$PD\n" '{"decision":"reject","source":"hook","reasonType":"hook"}' y1 "Use demo_lookup instead of grep"
  printf "$PD\n" '{"decision":"reject","source":"config","reasonType":"rule"}' y2 "Permission to use Bash with command rm has been denied."
} > "$CLAUDE_PROJECTS_DIR/-work-fourth/s5.jsonl"
# The same message copied into a second transcript without its version
# (a resumed session): blanks are filled from the other copy.
sed 's/,"version":"2.1.300"//' "$CLAUDE_PROJECTS_DIR/-work-fourth/s5.jsonl" > "$CLAUDE_PROJECTS_DIR/-work-fourth/a-s5-copy.jsonl"
python3 "$SUT" collect >/dev/null 2>&1
check "hook denial from permissionDecision" "hook:Grep,policy:Bash" "$(row msg_y1 14)"
check "Claude Code version recorded" 2.1.300 "$(row msg_y1 15)"

# ---- report, connected with fake gh ---------------------------------------
SQ="$SECOND_BRAIN_PATH/projects/app-display/.squad"; mkdir -p "$SQ"
echo '{"chisel":{"mode":"connected"}}' > "$SQ/chisel-config.json"
cat > "$SQ/progress.txt" <<'EOF'
[#12] 2026-10-14 committed on 12-x (base: main). Added table.
[#13] 2026-10-14 resolved. PR: #41 (base: main). Migration.
[#14] 2026-10-14 resolved. PR: #42 (base: main). Other.
[#9] 2026-07-01 resolved. PR: #30 (base: main). Too old.
EOF
FAKE="$TMPROOT/fakegh"; mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "pr view 41 "*) echo '{"number":41,"state":"MERGED","createdAt":"2026-10-14T10:00:00Z","mergedAt":"2026-10-14T16:00:00Z","commits":[{"committedDate":"2026-10-14T09:00:00Z"},{"committedDate":"2026-10-14T12:00:00Z"}]}' ;;
  "pr view 42 "*) echo '{"number":42,"state":"OPEN","createdAt":"2026-10-14T10:00:00Z","mergedAt":null,"commits":[{"committedDate":"2026-10-14T09:00:00Z"}]}' ;;
  *) echo "unexpected" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE/gh"
export GH_LOG="$TMPROOT/gh.log"; : > "$GH_LOG"
( cd "$APP" && PATH="$FAKE:$PATH" python3 "$SUT" report ) > "$TMPROOT/out" 2>"$TMPROOT/err"; RC=$?
OUT="$(cat "$TMPROOT/out")"
check "connected exit 0" 0 "$RC"
check "QUALITY github" github "$(key QUALITY)"
check "PRS_TOTAL (window filter on progress date)" 2 "$(key PRS_TOTAL)"
check "PRS_MERGED" 1 "$(key PRS_MERGED)"
check "only read calls to gh" 0 "$(grep -cv '^pr view ' "$GH_LOG")"
REPORT="$(key REPORT)"
grep -q "| Median hours to merge | 6.0 |" "$REPORT" && ok "median hours" || bad "median hours"
grep -q "(rework proxy) | 1 (50%) |" "$REPORT" && ok "rework proxy" || bad "rework proxy"
grep -q "per merged PR (project) | \$3.39 |" "$REPORT" && ok "cost per merged PR" || bad "cost per merged PR"

cat > "$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
echo "boom: auth required" >&2; exit 4
EOF
( cd "$APP" && PATH="$FAKE:$PATH" python3 "$SUT" report ) > "$TMPROOT/out" 2>"$TMPROOT/err"; RC=$?
OUT="$(cat "$TMPROOT/out")"
check "gh failure is not fatal" 0 "$RC"
check "QUALITY gh-error" gh-error "$(key QUALITY)"

# ---- Reven verdicts delivered through SubagentHandback ---------------------
export SQUAD_STATS_DIR="$TMPROOT/vstore"; mkdir -p "$SQUAD_STATS_DIR"
export CLAUDE_PROJECTS_DIR="$TMPROOT/vprojects"; mkdir -p "$CLAUDE_PROJECTS_DIR/-v/sv/subagents"
VD="$CLAUDE_PROJECTS_DIR/-v/sv/subagents"
asst 2026-10-14T09:00:00.000Z msg_vm claude-opus-5-5 1 0 0 0 0 sv /v > "$CLAUDE_PROJECTS_DIR/-v/sv.jsonl"
# text-only verdict
printf '{"type":"assistant","timestamp":"2026-10-14T10:00:00.000Z","sessionId":"sv","message":{"id":"msg_vt","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1000000},"content":[{"type":"text","text":"Verdict: COMMENT\\nx"}]}}\n' > "$VD/agent-t.jsonl"
echo '{"agentType":"reven"}' > "$VD/agent-t.meta.json"
python3 "$SUT" collect >/dev/null 2>&1
check "text verdict row" 1 "$(grep -c ':verdict' "$SQUAD_STATS_DIR/verdicts.tsv")"
# handback-only verdict, text+handback of one review, Bash-only (gh pr comment)
printf '{"type":"assistant","timestamp":"2026-10-14T10:05:00.000Z","sessionId":"sv","message":{"id":"msg_vh","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"toolu_h1","name":"SubagentHandback","input":{"message":"Review\\nVerdict: APPROVED\\nok"}}]}}\n' > "$VD/agent-h.jsonl"
echo '{"agentType":"reven"}' > "$VD/agent-h.meta.json"
{
  printf '{"type":"assistant","timestamp":"2026-10-14T10:10:00.000Z","sessionId":"sv","message":{"id":"msg_vb1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"Verdict: CHANGES REQUESTED"}]}}\n'
  printf '{"type":"assistant","timestamp":"2026-10-14T10:11:00.000Z","sessionId":"sv","message":{"id":"msg_vb2","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"toolu_b1","name":"SubagentHandback","input":{"message":"Verdict: CHANGES REQUESTED"}}]}}\n'
} > "$VD/agent-b.jsonl"
echo '{"agentType":"reven"}' > "$VD/agent-b.meta.json"
printf '{"type":"assistant","timestamp":"2026-10-14T10:15:00.000Z","sessionId":"sv","message":{"id":"msg_vx","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"toolu_x1","name":"Bash","input":{"command":"gh pr comment 1 --body \\"Verdict: APPROVED\\""}}]}}\n' > "$VD/agent-x.jsonl"
echo '{"agentType":"reven"}' > "$VD/agent-x.meta.json"
python3 "$SUT" collect >/dev/null 2>&1
check "backfill adds only the missing rows" 3 "$(grep -c ':verdict' "$SQUAD_STATS_DIR/verdicts.tsv")"
check "handback-only verdict recorded" 1 "$(grep -c 'APPROVED.toolu_h1:verdict' "$SQUAD_STATS_DIR/verdicts.tsv")"
check "review with text and handback counted once" 1 "$(grep -c 'CHANGES REQUESTED' "$SQUAD_STATS_DIR/verdicts.tsv")"
printf '{"type":"assistant","timestamp":"2026-10-14T10:20:00.000Z","sessionId":"sv","message":{"id":"msg_vi","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"toolu_i1","name":"SubagentHandback","input":{"message":"Review\\nVerdict: INCOMPLETE\\nx"}}]}}\n' > "$VD/agent-i.jsonl"
echo '{"agentType":"reven"}' > "$VD/agent-i.meta.json"
python3 "$SUT" collect >/dev/null 2>&1
check "INCOMPLETE verdict recorded" 1 "$(grep -c 'INCOMPLETE.toolu_i1:verdict' "$SQUAD_STATS_DIR/verdicts.tsv")"
check "Bash input yields no row" 0 "$(grep -c 'toolu_x1' "$SQUAD_STATS_DIR/verdicts.tsv")"
python3 "$SUT" collect >/dev/null 2>&1
check "re-collect does not duplicate verdicts" 4 "$(grep -c ':verdict' "$SQUAD_STATS_DIR/verdicts.tsv")"

# verdict rows carry the model; old 5-column rows read as "unknown"; per-model report row
check "verdict row carries the message model" claude-opus-5-5 "$(awk -F'\t' '$5 == "msg_vt:verdict" {print $6}' "$SQUAD_STATS_DIR/verdicts.tsv")"
printf '2026-10-14T10:20:00.000Z\tsv\tv\tAPPROVED\told_msg:verdict\n' >> "$SQUAD_STATS_DIR/verdicts.tsv"
# a non-Reven agent on the same model must not count towards the per-model cost
printf '{"type":"assistant","timestamp":"2026-10-14T10:25:00.000Z","sessionId":"sv","message":{"id":"msg_vc","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":1000000},"content":[{"type":"text","text":"x"}]}}\n' > "$VD/agent-c.jsonl"
echo '{"agentType":"cody"}' > "$VD/agent-c.meta.json"
python3 "$SUT" collect >/dev/null 2>&1
( cd "$TMPROOT" && python3 "$SUT" report --days 30 ) > "$TMPROOT/out" 2>/dev/null; OUT="$(cat "$TMPROOT/out")"
REPORT="$(key REPORT)"
grep -q "^| claude-opus-5-5 | 4 | 1 | 1 | 1 | 1 | \$20.00 |" "$REPORT" && ok "per-model row: counts, INCOMPLETE column, Reven-only cost" || bad "per-model row: counts, INCOMPLETE column, Reven-only cost"
grep -q "^| unknown | 1 | 1 | 0 | 0 | 0 | \$0.00 |" "$REPORT" && ok "old 5-column verdict shows as unknown" || bad "old 5-column verdict shows as unknown"

# ---- trend: 12 sessions per period, last period 20% cheaper per session ----
export SQUAD_STATS_DIR="$TMPROOT/trendstore"; mkdir -p "$SQUAD_STATS_DIR"
export CLAUDE_PROJECTS_DIR="$TMPROOT/trendprojects"; mkdir -p "$CLAUDE_PROJECTS_DIR/-t"
i=0
while [ $i -lt 12 ]; do
  d=$(printf '%02d' $((i + 1)))
  asst "2026-08-${d}T10:00:00.000Z" "p$i" claude-opus-5-5 250000 0 0 0 0 "tp$i" /t > "$CLAUDE_PROJECTS_DIR/-t/tp$i.jsonl"
  asst "2026-09-${d}T10:00:00.000Z" "l$i" claude-opus-5-5 200000 0 0 0 0 "tl$i" /t > "$CLAUDE_PROJECTS_DIR/-t/tl$i.jsonl"
  i=$((i + 1))
done
asst 2026-09-05T11:00:00.000Z q1 claude-opus-5-5 1 0 0 0 0 tq /t > "$CLAUDE_PROJECTS_DIR/-t/tq.jsonl"
printf '{"type":"user","timestamp":"2026-09-05T10:59:00.000Z","sessionId":"tq","cwd":"/t","message":{"role":"user","content":"<command-name>/ralph</command-name>"}}\n' >> "$CLAUDE_PROJECTS_DIR/-t/tq.jsonl"
asst 2026-08-05T11:00:00.000Z q0 claude-opus-5-5 1 0 0 0 0 tq0 /t > "$CLAUDE_PROJECTS_DIR/-t/tq0.jsonl"
printf '{"type":"user","timestamp":"2026-08-05T10:59:00.000Z","sessionId":"tq0","cwd":"/t","message":{"role":"user","content":"<command-name>/ralph</command-name>"}}\n' >> "$CLAUDE_PROJECTS_DIR/-t/tq0.jsonl"
python3 "$SUT" collect >/dev/null 2>&1
( cd "$TMPROOT" && SQUAD_STATS_NOW=2026-09-20T00:00:00Z python3 "$SUT" report ) > "$TMPROOT/out" 2>/dev/null; OUT="$(cat "$TMPROOT/out")"
REPORT="$(key REPORT)"
check "TREND_COST_PER_SESSION (a tiny 13th session each)" "-20%" "$(key TREND_COST_PER_SESSION)"
check "TREND_SESSIONS (prev/last)" "13/13" "$(key TREND_SESSIONS)"
grep -q "^| Cost per session | lower | \$0.92 | \$0.74 | -20% | 13 / 13 |" "$REPORT" && ok "trend row" || bad "trend row"
grep -q "^| Cost per vanilla session | lower | \$1.00 | \$0.80 | -20% | 12 / 12 |" "$REPORT" && ok "trend row per kind" || bad "trend row per kind"
grep -q "^| Cost per squad session | lower | \$0.00 | \$0.00 | too few units | 1 / 1 |" "$REPORT" && ok "trend: too few units" || bad "trend: too few units"
grep -q "^| Squad cost per merged PR | lower | n/a | n/a | n/a | 0 / 0 |" "$REPORT" && ok "trend: n/a without PRs" || bad "trend: n/a without PRs"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
