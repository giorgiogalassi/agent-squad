#!/usr/bin/env bash
# Tests `lore event` and `lore fold` (#423): inbox write contract, one-commit
# idempotent fold, concurrency, dead-pid adoption, quarantine, note replacement.
# Plain bash 3.2; fixture vaults only.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-fold TMP
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
export SQUAD_INCIDENTS=off
LORE="$REPO_ROOT/claude/hooks/lore"

mkvault() {  # mkvault <dir>: vault with project p (state dir .lore)
  mkdir -p "$1/projects/p"
  git -C "$1" init -q
  git -C "$1" config user.name t; git -C "$1" config user.email t@t
  printf '# Status\n\n## Last checkpoint\n\n## Context refs\n- x\n' > "$1/projects/p/status.md"
  echo seed > "$1/seed.md"; git -C "$1" add -A; git -C "$1" commit -qm init
}
ev() { SECOND_BRAIN_PATH="$V" bash "$LORE" event "$@"; }
fold() { SECOND_BRAIN_PATH="$V" bash "$LORE" fold "$@"; }
count() { git -C "$V" rev-list --count HEAD; }

# --- event ---
V="$TMP/v1"; mkvault "$V"
out="$(ev --project p --source forge --kind log --line "x")"; rc=$?
check "event exits 0" 0 "$rc"
has "event emits ID" "ID=" "$out"
has "event emits OUTCOME" "OUTCOME=applied" "$out"
IN="$V/projects/p/.lore/inbox"
check "one .ev in the inbox" 1 "$(ls "$IN"/*.ev | wc -l | tr -d ' ')"
check "no temp file remains" 0 "$(ls -A "$IN" | grep -c '^\.tmp')"
f="$(ls "$IN"/*.ev)"
has "event file has V=1" "V=1" "$(cat "$f")"
has "event file has KIND" "KIND=log" "$(cat "$f")"
check "inbox is excluded locally" 1 "$(grep -cxF 'projects/*/.lore/inbox/' "$V/.git/info/exclude")"
check "inbox not seen by git" "" "$(git -C "$V" status --porcelain | grep inbox)"

ev --project nope --source forge --kind log --line x >/dev/null 2>&1; check "unmapped project exits 10" 10 "$?"
check "unmapped project writes nothing" 1 "$(ls "$IN"/*.ev | wc -l | tr -d ' ')"
ev --project p --source forge --kind log >/dev/null 2>&1; check "missing --line exits 2" 2 "$?"
ev --project p --source forge --kind bogus --line x >/dev/null 2>&1; check "bad kind at write exits 2" 2 "$?"
SECOND_BRAIN_PATH="$TMP/none" bash "$LORE" event --project p --source s --kind log --line x >/dev/null 2>&1
check "no vault exits 10" 10 "$?"

# --- fold: 3 events, one commit, idempotent ---
V="$TMP/v2"; mkvault "$V"
ev --project p --source forge --kind log --line "log one" >/dev/null
ev --project p --source cody --kind checkpoint --line "cp one" >/dev/null
ev --project p --source ralph --kind progress --line "[1] progress one" >/dev/null
b="$(count)"
out="$(fold 2>&1)"; rc=$?
check "fold exits 0" 0 "$rc"
has "fold applied" "OUTCOME=applied" "$out"
has "fold APPLIED=3" "APPLIED=3" "$out"
check "fold is one commit" $((b+1)) "$(count)"
has "session.log has the log line" "[forge] log one" "$(cat "$V/projects/p/.lore/session.log")"
has "progress.txt has the line" "[1] progress one" "$(cat "$V/projects/p/.lore/progress.txt")"
has "status.md has the checkpoint" "[cody] cp one" "$(cat "$V/projects/p/status.md")"
check "checkpoint is inside its section" "[cody] cp one" "$(awk '/^## Last checkpoint/{f=1;next}/^## /{f=0}f' "$V/projects/p/status.md" | sed 's/^\[[^]]*\] //')"
has "Context refs kept last" "## Context refs" "$(tail -n 2 "$V/projects/p/status.md")"
check "inbox emptied" 0 "$(ls "$V/projects/p/.lore/inbox" | wc -l | tr -d ' ')"
check "tree clean" "" "$(git -C "$V" status --porcelain)"
out="$(fold 2>&1)"
has "second fold unchanged" "OUTCOME=unchanged" "$out"
check "no second commit" $((b+1)) "$(count)"

# working-state snapshot
echo run > "$V/projects/p/.lore/ralph-run.md"
out="$(fold 2>&1)"
has "working state is committed by fold" "OUTCOME=applied" "$out"
check "ralph-run.md tracked" "projects/p/.lore/ralph-run.md" "$(git -C "$V" ls-files projects/p/.lore/ralph-run.md)"

# checkpoint keeps 3, newest first
V="$TMP/v3"; mkvault "$V"
for i in 1 2 3 4 5; do ev --project p --source s --kind checkpoint --line "cp $i" >/dev/null; sleep 1; done
fold >/dev/null 2>&1
sec="$(awk '/^## Last checkpoint/{f=1;next}/^## /{f=0}f' "$V/projects/p/status.md" | grep .)"
check "three checkpoints kept" 3 "$(printf '%s\n' "$sec" | wc -l | tr -d ' ')"
has "newest first" "cp 5" "$(printf '%s\n' "$sec" | head -n 1)"

# notes: same SOURCE+KEY, newer wins; cap 10 per source
V="$TMP/v4"; mkvault "$V"
ev --project p --source forge --kind note --key k --line "old" >/dev/null
ev --project p --source forge --kind note --key k --line "new" >/dev/null
fold >/dev/null 2>&1
sec="$(awk '/^## Other sources/{f=1;next}/^## /{f=0}f' "$V/projects/p/status.md" | grep .)"
check "one note line remains" 1 "$(printf '%s\n' "$sec" | wc -l | tr -d ' ')"
has "the newer note remains" "new" "$sec"
i=0; while [ $i -lt 12 ]; do ev --project p --source forge --kind note --key "k$i" --line "n$i" >/dev/null; i=$((i+1)); done
fold >/dev/null 2>&1
sec="$(awk '/^## Other sources/{f=1;next}/^## /{f=0}f' "$V/projects/p/status.md" | grep .)"
check "at most 10 notes per source" 10 "$(printf '%s\n' "$sec" | wc -l | tr -d ' ')"
has "newest note kept" "n11" "$sec"

# quarantine
V="$TMP/v5"; mkvault "$V"
IN="$V/projects/p/.lore/inbox"; mkdir -p "$IN"
printf 'V=1\nID=a\nSOURCE=s\nKIND=bogus\nTS=2026-01-01 00:00:00\nLINE=zzz\n' > "$IN/1-1-1.ev"
printf 'garbage\n' > "$IN/2-1-1.ev"
b="$(count)"
out="$(fold 2>&1)"
has "quarantined count" "QUARANTINED=2" "$out"
check "bogus event quarantined" 1 "$(ls "$IN/quarantine/1-1-1.ev" 2>/dev/null | wc -l | tr -d ' ')"
check ".why file written" 1 "$(ls "$IN/quarantine/1-1-1.ev.why" 2>/dev/null | wc -l | tr -d ' ')"
check "nothing committed for quarantine" "$b" "$(count)"
check "quarantine never tracked" "" "$(git -C "$V" ls-files | grep quarantine)"

# dead pid claim adopted exactly once
V="$TMP/v6"; mkvault "$V"
IN="$V/projects/p/.lore/inbox"; mkdir -p "$IN/.claimed-99999"
printf 'V=1\nID=a\nSOURCE=s\nKIND=log\nTS=2026-01-01 00:00:00\nLINE=dead one\n' > "$IN/.claimed-99999/1-1-1.ev"
printf 'V=1\nID=b\nSOURCE=s\nKIND=log\nTS=2026-01-01 00:00:01\nLINE=dead two\n' > "$IN/.claimed-99999/2-1-1.ev"
fold >/dev/null 2>&1
check "both dead-claim events applied" 2 "$(grep -c 'dead' "$V/projects/p/.lore/session.log")"
check "claimed dir removed" 0 "$(ls -A "$IN" | grep -c claimed)"
fold >/dev/null 2>&1
check "applied once" 2 "$(grep -c 'dead' "$V/projects/p/.lore/session.log")"
# live pid claim is left alone
mkdir -p "$IN/.claimed-$$"
printf 'V=1\nID=c\nSOURCE=s\nKIND=log\nTS=2026-01-01 00:00:02\nLINE=live one\n' > "$IN/.claimed-$$/3-1-1.ev"
fold >/dev/null 2>&1
check "live claim untouched" 0 "$(grep -c 'live one' "$V/projects/p/.lore/session.log")"

# concurrent folds over 50 events
V="$TMP/v7"; mkvault "$V"
i=1; while [ $i -le 50 ]; do ev --project p --source s --kind log --line "line-$i" >/dev/null; i=$((i+1)); done
fold >/dev/null 2>"$TMP/e1" & P1=$!
fold >/dev/null 2>"$TMP/e2" & P2=$!
wait $P1; r1=$?; wait $P2; r2=$?
check "concurrent folds exit 0" "0 0" "$r1 $r2"
check "50 lines applied" 50 "$(grep -c 'line-' "$V/projects/p/.lore/session.log")"
check "no duplicates" 50 "$(grep 'line-' "$V/projects/p/.lore/session.log" | sort -u | wc -l | tr -d ' ')"
check "no index.lock error" 0 "$(cat "$TMP/e1" "$TMP/e2" | grep -c index.lock)"
check "tree clean after folds" "" "$(git -C "$V" status --porcelain)"

# lock timeout: events stay claimed, then a later fold applies them
V="$TMP/v8"; mkvault "$V"
ev --project p --source s --kind log --line "late" >/dev/null
mkdir "$V/.git/lore.lock"; sleep 30 & H=$!
printf 'PID=%s\nAT=%s\n' "$H" "$(date +%s)" > "$V/.git/lore.lock/owner"
LORE_LOCK_WAIT=1 fold >/dev/null 2>&1; check "busy lock exits 20" 20 "$?"
kill $H 2>/dev/null; wait $H 2>/dev/null; rm -rf "$V/.git/lore.lock"
fold >/dev/null 2>&1
check "claimed events applied by the next fold" 1 "$(grep -c late "$V/projects/p/.lore/session.log")"

# identical lines are real events: lock timeout then adoption appends the repeat
V="$TMP/v9"; mkvault "$V"
mkdir -p "$V/projects/p/.lore"; echo "[2] same line" > "$V/projects/p/.lore/progress.txt"
git -C "$V" add -A; git -C "$V" commit -qm prog
ev --project p --source s --kind progress --line "[2] same line" >/dev/null
mkdir "$V/.git/lore.lock"; sleep 30 & H=$!
printf 'PID=%s\nAT=%s\n' "$H" "$(date +%s)" > "$V/.git/lore.lock/owner"
LORE_LOCK_WAIT=1 fold >/dev/null 2>&1
kill $H 2>/dev/null; wait $H 2>/dev/null; rm -rf "$V/.git/lore.lock"
fold >/dev/null 2>&1
check "identical progress line after lock timeout is appended" 2 "$(grep -c 'same line' "$V/projects/p/.lore/progress.txt")"

# the same line twice in one batch: both appended
V="$TMP/v10"; mkvault "$V"
ev --project p --source s --kind progress --line "[3] twice" >/dev/null
ev --project p --source s --kind progress --line "[3] twice" >/dev/null
fold >/dev/null 2>&1
check "identical lines in one batch both appended" 2 "$(grep -c twice "$V/projects/p/.lore/progress.txt")"

# crash after k of n: next fold applies exactly the remaining
V="$TMP/v11"; mkvault "$V"
i=1; while [ $i -le 5 ]; do ev --project p --source s --kind progress --line "[4] e$i" >/dev/null; i=$((i+1)); done
LORE_TEST_DIE_AFTER=2 fold >/dev/null 2>&1
check "crashed fold applied 2" 2 "$(grep -c 'e[0-9]' "$V/projects/p/.lore/progress.txt")"
fold >/dev/null 2>&1
check "recovery applied all 5" 5 "$(grep -c 'e[0-9]' "$V/projects/p/.lore/progress.txt")"
check "no duplicates after recovery" 5 "$(sort -u "$V/projects/p/.lore/progress.txt" | grep -c 'e[0-9]')"
# crash between effect and removal: the ledger skips the event by ID
V="$TMP/v12"; mkvault "$V"
IN="$V/projects/p/.lore/inbox"; mkdir -p "$IN/.claimed-99999"
printf 'V=1\nID=x1\nSOURCE=s\nKIND=progress\nTS=2026-01-01 00:00:00\nLINE=[5] done\n' > "$IN/.claimed-99999/1-1-1.ev"
printf 'V=1\nID=x2\nSOURCE=s\nKIND=progress\nTS=2026-01-01 00:00:00\nLINE=[5] todo\n' > "$IN/.claimed-99999/2-1-1.ev"
printf 'x1\n' > "$IN/.claimed-99999/applied"; echo "[5] done" > "$V/projects/p/.lore/progress.txt"
fold >/dev/null 2>&1
check "ledgered event not re-applied" 1 "$(grep -c '\[5\] done' "$V/projects/p/.lore/progress.txt")"
check "unledgered event applied" 1 "$(grep -c '\[5\] todo' "$V/projects/p/.lore/progress.txt")"

# SessionStart with a held lock: orientation is delayed by the short wait only
V="$TMP/v13"; mkvault "$V"; R="$TMP/r13"; mkdir -p "$R"; git -C "$R" init -q
printf '{"projects":{"%s":"p"}}\n' "$(cd "$R" && pwd -P)" > "$V/lore-config.json"
ev --project p --source s --kind log --line "held" >/dev/null
mkdir "$V/.git/lore.lock"; sleep 30 & H=$!
printf 'PID=%s\nAT=%s\n' "$H" "$(date +%s)" > "$V/.git/lore.lock/owner"
t0="$(date +%s)"
(cd "$R" && SECOND_BRAIN_PATH="$V" bash "$REPO_ROOT/claude/hooks/lore-orient.sh" >/dev/null 2>&1 </dev/null)
t1="$(date +%s)"
kill $H 2>/dev/null; wait $H 2>/dev/null; rm -rf "$V/.git/lore.lock"
[ $((t1 - t0)) -le 6 ] && ok "orientation delayed at most a few seconds by a held lock" || bad "orientation took $((t1 - t0)) s"
fold >/dev/null 2>&1
check "event left for the next fold" 1 "$(grep -c held "$V/projects/p/.lore/session.log")"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
