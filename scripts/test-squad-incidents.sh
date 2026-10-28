#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-incidents.sh. Plain bash 3.2; no bats.
# Usage: scripts/test-squad-incidents.sh [path/to/squad-incidents.sh]
# SQUAD_INCIDENTS_FILE always points at a temp file; the vault is never touched.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="${1:-$REPO_ROOT/claude/hooks/squad-incidents.sh}"
[ -f "$SUT" ] || { echo "error: $SUT not found" >&2; exit 2; }
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-incidents
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

N=0
newstore() { N=$((N+1)); export SQUAD_INCIDENTS_FILE="$TMPROOT/store$N.tsv"; : > "$SQUAD_INCIDENTS_FILE"; }
run() { OUT="$(bash "$SUT" "$@" 2>"$TMPROOT/err")"; RC=$?; }
rec() {  # rec <session> <kind> <reason> [dedupe]
  bash "$SUT" record --session "$1" --project p --source script --kind "$2" \
    --component squad-labels --exit 10 --reason "$3" --dedupe-id "${4:-}" >/dev/null 2>&1
}
rows() { wc -l < "$SQUAD_INCIDENTS_FILE" | tr -d ' '; }

# 1. token redaction + 120 cap
newstore
TOK="ghp_$(printf 'a%.0s' $(seq 1 36))"
rec s1 failure "bad token $TOK in $(printf 'x%.0s' $(seq 1 200))"
EX="$(awk -F'\t' '{print $9}' "$SQUAD_INCIDENTS_FILE")"
case "$EX" in *ghp_*) bad "token redacted" ;; *) ok "token redacted" ;; esac
[ "${#EX}" -le 120 ] && ok "excerpt <= 120" || bad "excerpt <= 120 (${#EX})"
check "9 columns" 9 "$(awk -F'\t' '{print NF}' "$SQUAD_INCIDENTS_FILE")"
rec s1 failure "$(printf 'a\tb\nc\rd')"
case "$(tail -n 1 "$SQUAD_INCIDENTS_FILE" | awk -F'\t' '{print NF}')" in 9) ok "tabs/newlines stripped" ;; *) bad "tabs/newlines stripped" ;; esac

# 2. dedupe
newstore
rec s1 failure "boom" X; rec s1 failure "boom" X
check "dedupe_id stored once" 1 "$(rows)"

# 3. recurring across sessions
newstore
rec s1 failure "label missing 12"; rec s2 failure "label missing 99"
run summary
check "summary exit 0" 0 "$RC"
case "$OUT" in *SESSIONS=2*) ok "SESSIONS=2" ;; *) bad "SESSIONS=2 ($OUT)" ;; esac
case "$OUT" in *RECURRING=1*) ok "RECURRING=1" ;; *) bad "RECURRING=1 ($OUT)" ;; esac
case "$OUT" in *COUNT=2*) ok "COUNT=2" ;; *) bad "COUNT=2" ;; esac
case "$OUT" in *LAST=*) ok "LAST present" ;; *) bad "LAST present" ;; esac
SIG="$(printf '%s\n' "$OUT" | sed -n 's/^SIGNATURE=//p')"

# 4. same session twice
newstore
rec s1 failure "boom"; rec s1 failure "boom"
run summary
case "$OUT" in *RECURRING=0*) ok "one session not recurring" ;; *) bad "one session not recurring ($OUT)" ;; esac

# 5. escalations
newstore
rec s1 escalation "stuck"; rec s2 escalation "stuck"; rec s3 escalation "stuck"
run summary
case "$OUT" in *ESCALATIONS=3*) ok "ESCALATIONS=3" ;; *) bad "ESCALATIONS=3 ($OUT)" ;; esac
case "$OUT" in *RECURRING=0*) ok "escalations not recurring" ;; *) bad "escalations not recurring" ;; esac

# 6. resolve / reopen
newstore
rec s1 failure "label missing"; rec s2 failure "label missing"
run summary; SIG="$(printf '%s\n' "$OUT" | sed -n 's/^SIGNATURE=//p')"
run resolve --signature "$SIG" --ref PR-1
check "resolve exit 0" 0 "$RC"
run summary
case "$OUT" in *"SIGNATURE="*) bad "resolved hidden ($OUT)" ;; *) ok "resolved hidden" ;; esac
case "$OUT" in *RECURRING=0*) ok "resolved RECURRING=0" ;; *) bad "resolved RECURRING=0" ;; esac
rec s3 failure "label missing"
run summary
case "$OUT" in *"SIGNATURE=$SIG"*) ok "reopened by later occurrence" ;; *) bad "reopened ($OUT)" ;; esac

# 7. unwritable path
export SQUAD_INCIDENTS_FILE="$TMPROOT/nodir/deeper/x.tsv"
OUT="$(bash "$SUT" record --session s1 --project p --source script --kind failure --component c --exit 1 --reason r 2>&1)"; RC=$?
check "unwritable exit 0" 0 "$RC"; check "unwritable empty stdout" "" "$OUT"

# 8. off
newstore
SQUAD_INCIDENTS=off bash "$SUT" record --session s1 --project p --source script --kind failure --component c --exit 1 --reason r >/dev/null 2>&1
check "off leaves store unchanged" 0 "$(rows)"

# 9. usage error
run bogus; check "unknown verb exits 2" 2 "$RC"

# 10. dangling flag must not hang (guarded: background + kill, no `timeout` on macOS)
descendants() {  # descendants <pid> -> every transitive child pid, one per line
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done
}
guarded() {  # guarded <args...> -> sets OUT, RC (RC=124 on hang); kills the whole tree on hang
  local pid i=0 kids p
  bash "$SUT" "$@" >"$TMPROOT/gout" 2>/dev/null & pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    # cmd_record is a subshell: killing only $pid would orphan its child loop.
    kids="$(descendants "$pid")"
    for p in $kids; do kill -9 "$p" 2>/dev/null; done
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RC=124
    sleep 0.1
    for p in $kids; do
      if kill -0 "$p" 2>/dev/null; then bad "guarded call left survivor pid $p"; kill -9 "$p" 2>/dev/null; fi
    done
  else wait "$pid"; RC=$?; fi
  OUT="$(cat "$TMPROOT/gout")"
}
newstore
guarded record --kind failure --reason
check "record dangling flag exits 0" 0 "$RC"; check "record dangling flag empty stdout" "" "$OUT"
guarded resolve --signature
check "resolve dangling --signature exits 2" 2 "$RC"
guarded resolve --signature x --ref
check "resolve dangling --ref exits 2" 2 "$RC"
newstore
guarded record --session s1 --project p --source bogus --kind failure --component c --exit 1 --reason r
check "invalid source still exits 0" 0 "$RC"
check "invalid source dropped" "" "$(cut -f4 "$SQUAD_INCIDENTS_FILE")"

echo; # 3. local-only project (#351): name replaced by "local"; control keeps its name
V="$TMPROOT/vault"; mkdir -p "$V"; git -C "$V" init -q
mkdir -p "$V/projects/secretproj" "$V/projects/openproj"
touch "$V/projects/secretproj/status.md" "$V/projects/openproj/status.md"
printf 'projects/secretproj/\n' >> "$V/.git/info/exclude"
export SQUAD_INCIDENTS_FILE="$V/squad-incidents.tsv"; : > "$SQUAD_INCIDENTS_FILE"
for pr in secretproj openproj; do
  bash "$SUT" record --session s --project $pr --source script --kind failure \
    --component squad-labels --exit 10 --reason "boom" >/dev/null 2>&1
done
check "local-only project recorded as local" local "$(sed -n 1p "$SQUAD_INCIDENTS_FILE" | awk -F'\t' '{print $3}')"
check "non-excluded project keeps its name" openproj "$(sed -n 2p "$SQUAD_INCIDENTS_FILE" | awk -F'\t' '{print $3}')"
case "$(cat "$SQUAD_INCIDENTS_FILE")" in *secretproj*) bad "no local-only name in store" ;; *) ok "no local-only name in store" ;; esac

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
