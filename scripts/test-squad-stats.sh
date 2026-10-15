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
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }
run() { OUT="$(python3 "$SUT" "$@" 2>"$TMPROOT/err")"; RC=$?; }

# The script must sit next to path-resolve.sh, as it does in ~/.claude/hooks.
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
check "ROWS_ADDED 14 (dedup by id, synthetic skipped)" 14 "$(key ROWS_ADDED)"
check "VERDICTS_ADDED 1 (reven only)" 1 "$(key VERDICTS_ADDED)"
check "FILES_SCANNED 3" 3 "$(key FILES_SCANNED)"
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
check "COST_USD (window excludes old row, haiku tiers)" 6.66 "$(key COST_USD)"
check "SESSIONS" 3 "$(key SESSIONS)"
check "SQUAD_SESSIONS" 1 "$(key SQUAD_SESSIONS)"
check "CUSTOM_SESSIONS" 1 "$(key CUSTOM_SESSIONS)"
check "VANILLA_SESSIONS" 1 "$(key VANILLA_SESSIONS)"
check "SQUAD_COST_USD (whole squad sessions)" 3.45 "$(key SQUAD_COST_USD)"
check "CUSTOM_COST_USD" 2.20 "$(key CUSTOM_COST_USD)"
check "VANILLA_COST_USD" 1.01 "$(key VANILLA_COST_USD)"
check "CACHE_HIT_PCT" 28 "$(key CACHE_HIT_PCT)"
check "TOP_SKILL" ralph "$(key TOP_SKILL)"
check "VERDICTS" 1 "$(key VERDICTS)"
check "QUALITY detached" skipped-detached "$(key QUALITY)"
check "UNPRICED_MODELS" claude-unknown-9 "$(key UNPRICED_MODELS)"
REPORT="$(key REPORT)"
[ -f "$REPORT" ] && ok "report file written" || bad "report file written ($REPORT)"
grep -q "CHANGES REQUESTED | 1 | 100%" "$REPORT" && ok "verdict table" || bad "verdict table"
grep -q "| ralph | yes | 1 |" "$REPORT" && ok "skill table, squad flag" || bad "skill table, squad flag"
grep -q "| tokensave | no | 1 |" "$REPORT" && ok "custom skill listed" || bad "custom skill listed"
grep -q "| my-reviewer | no | 1 |" "$REPORT" && ok "custom agent listed" || bad "custom agent listed"
grep -q "| vanilla | 1 | \$1.01 |" "$REPORT" && ok "vanilla kind row" || bad "vanilla kind row"
grep -q "^| 2026-W42 | 3 |" "$REPORT" && ok "weekly trend row" || bad "weekly trend row"

PRICES='{"unknown-9":[1000000,0,0,0,1000000]}'
printf '%s' "$PRICES" > "$STORE/prices.json"
( cd "$APP" && python3 "$SUT" report ) > "$TMPROOT/out" 2>/dev/null; OUT="$(cat "$TMPROOT/out")"
check "prices.json override" 26.66 "$(key COST_USD)"
rm -f "$STORE/prices.json"

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

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
