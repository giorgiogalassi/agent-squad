#!/usr/bin/env bash
# Tests redaction and caps at `lore fold` (#425): line cap, per-source cap,
# local-only names, one fixture per redaction pattern, #401 derived outputs.
# Plain bash 3.2; fixture vaults only.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-redact TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1 (found [$2] in [$3])" ;; *) ok "$1" ;; esac; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
export SQUAD_INCIDENTS=off
LORE="$REPO_ROOT/claude/hooks/lore"

mkvault() {
  mkdir -p "$1/projects/p" "$1/projects/secret-client"
  git -C "$1" init -q
  git -C "$1" config user.name t; git -C "$1" config user.email t@t
  printf '# Status\n\n## Last checkpoint\n\n## Context refs\n- x\n' > "$1/projects/p/status.md"
  printf '# Status\n\n## Last checkpoint\n' > "$1/projects/secret-client/status.md"
  printf 'projects/secret-client/\n' >> "$1/.git/info/exclude"
  echo seed > "$1/seed.md"; git -C "$1" add -A; git -C "$1" commit -qm init
}
ev() { SECOND_BRAIN_PATH="$V" bash "$LORE" event "$@"; }
fold() { SECOND_BRAIN_PATH="$V" bash "$LORE" fold "$@"; }
LOG() { cat "$V/projects/p/.lore/session.log" 2>/dev/null; }

# --- 300-character cap ---
V="$TMP/v1"; mkvault "$V"
long="$(printf 'a%.0s' $(seq 1 500))"
ev --project p --source s --kind progress --line "$long" >/dev/null
fold >/dev/null 2>&1
got="$(cat "$V/projects/p/.lore/progress.txt")"
check "500-char line committed as 300" 300 "${#got}"
has "truncation marker present" "[truncated]" "$got"

# --- per-source cap ---
V="$TMP/v2"; mkvault "$V"
for i in $(seq 1 25); do ev --project p --source noisy --kind log --line "n$i" >/dev/null; done
ev --project p --source quiet --kind log --line "q1" >/dev/null
out="$(fold 2>&1)"
has "CAPPED=5" "CAPPED=5" "$out"
check "20 noisy lines applied" 20 "$(LOG | grep -c '\[noisy\]')"
has "newest kept" "n25" "$(LOG)"
check "oldest dropped" 0 "$(LOG | grep -c "\] n[1-5]$")"
has "other source untouched" "q1" "$(LOG)"

# --- local-only names ---
V="$TMP/v3"; mkvault "$V"
ev --project p --source s --kind log --line "worked on secret-client billing" >/dev/null
fold >/dev/null 2>&1
has "name replaced by local" "worked on local billing" "$(LOG)"
hasnt "name absent from the log" "secret-client" "$(LOG)"
check "name absent from tracked history" 0 "$(git -C "$V" log -p | grep -c 'secret-client billing')"

# --- one fixture per pattern ---
V="$TMP/v4"; mkvault "$V"
samples=(
  "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  "github_pat_11ABCDEFG0123456789_abcdefghijklmn"
  "sk-ant-api03-abcdefghijklmnop0123"
  "AKIAABCDEFGHIJKLMNOP"
  "Bearer abcdef0123456789xyz"
  "password=hunter2hunter2"
  "token=zzzzzzzz1234"
  "-----BEGIN RSA PRIVATE KEY-----"
  "-----BEGIN PRIVATE KEY-----"
)
for s in "${samples[@]}"; do ev --project p --source s --kind log --line "found $s here" >/dev/null; done
out="$(fold 2>&1)"
has "REDACTED counts every sample" "REDACTED=${#samples[@]}" "$out"
for s in "${samples[@]}"; do
  case "$(LOG)" in *"$s"*) bad "unmasked: $s" ;; *) ok "masked: ${s:0:14}" ;; esac
done
check "events still committed" "${#samples[@]}" "$(LOG | grep -c '\[REDACTED\]')"
V="$TMP/v5"; mkvault "$V"
ev --project p --source s --kind log --line "nothing secret, just tokens counted" >/dev/null
out="$(fold 2>&1)"
has "clean line: REDACTED=0" "REDACTED=0" "$out"

# --- #401: INDEX, stats, promotion carry no local-only name ---
V="$TMP/v6"; mkvault "$V"
printf '# Index\n\n| Project | Status | Updated | Link |\n|---|---|---|---|\n' > "$V/INDEX.md"
R="$TMP/r6"; mkdir -p "$R/secret-client"; git -C "$R/secret-client" init -q
printf '{"projects":{"%s":"secret-client"}}\n' "$(cd "$R/secret-client" && pwd -P)" > "$V/lore-config.json"
printf 'Last updated: 2026-11-01\n' >> "$V/projects/secret-client/status.md"
(cd "$R/secret-client" && SECOND_BRAIN_PATH="$V" bash "$REPO_ROOT/claude/hooks/lore-checkpoint.sh" >/dev/null 2>&1 </dev/null)
hasnt "INDEX.md has no local-only name" "secret-client" "$(cat "$V/INDEX.md")"
PROJ="$TMP/claude-projects/-x"; mkdir -p "$PROJ"
printf '{"type":"user","cwd":"%s","sessionId":"s1","timestamp":"2026-11-01T10:00:00Z","message":{"role":"user","content":"hi"}}\n' "$(cd "$R/secret-client" && pwd -P)" > "$PROJ/s1.jsonl"
printf '{"type":"assistant","cwd":"%s","sessionId":"s1","timestamp":"2026-11-01T10:00:01Z","message":{"id":"m1","model":"claude-sonnet-5-5","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":10,"output_tokens":5}}}\n' "$(cd "$R/secret-client" && pwd -P)" >> "$PROJ/s1.jsonl"
SENV=(env -i HOME="$TMP/h" PATH="$PATH" TMPDIR="$TMP" SECOND_BRAIN_PATH="$V" CLAUDE_PROJECTS_DIR="$TMP/claude-projects")
"${SENV[@]}" python3 -I "$REPO_ROOT/claude/hooks/squad-stats.py" collect >/dev/null 2>&1
st="$("${SENV[@]}" python3 -I "$REPO_ROOT/claude/hooks/squad-stats.py" report --days 400 2>&1)"
rep="$(cat "$V"/squad-stats/reports/*.md 2>/dev/null)"
has "report shows the project as local" "local" "$rep"
hasnt "stats stdout has no local-only name" "secret-client" "$st"
hasnt "stats report has no local-only name" "secret-client" "$rep"
rows="$(cat "$V"/squad-stats/*.tsv 2>/dev/null)"
has "store rows carry the public name" "s1	local" "$rows"
hasnt "stored stats rows have no local-only name" "secret-client" "$rows"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
