#!/usr/bin/env bash
# Tests claude/hooks/vault-check.sh and its SessionStart wiring (#333).
# Plain bash 3.2; every vault is a fixture, nothing touches ~/second-brain.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-vault-check.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in [$3])" ;; *) ok "$1" ;; esac; }

export SQUAD_INCIDENTS=off
export VAULT_CHECK_NOW="2026-10-26 12:00"
mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{vault-check.sh,decisions-lint.sh,lore-orient.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
VC="$TMPROOT/hooks/vault-check.sh"

# mkvault <dir>: clean vault with project "clean" (everything consistent).
mkvault() {
  local v="$1"
  mkdir -p "$v/projects/clean/.squad"
  cat > "$v/INDEX.md" <<'IDX'
# Index

## Active project

Name: clean
Status: [[projects/clean/status]]

## Projects

| Project | Status | Last updated |
|---------|--------|--------------|
| [[projects/clean/status\|clean]] | active | 2026-10-25 |

## Content

- x
IDX
  printf '# Status\nLast updated: 2026-10-25 21:58 by claude-code\n\n## Goal\nx\n\n## Last checkpoint\n[2026-10-25 21:00] ok\n' > "$v/projects/clean/status.md"
  printf -- '---\ntitle: d\n---\n\n## [2026-10-20] First\nbody\n' > "$v/projects/clean/decisions.md"
  printf '[2026-10-25 10:00] [ralph] start — batch: [#1]\n[2026-10-25 10:30] [ralph] end — resolved: 1\n' > "$v/projects/clean/.squad/session.log"
  printf 'x\n' > "$v/CLAUDE.md"; printf 'x\n' > "$v/lore-config.json"
}

# ---- clean project: nothing at all
V1="$TMPROOT/v1"; mkvault "$V1"
out="$(bash "$VC" check --vault "$V1" --project clean)"
check "clean project: no findings" "" "$out"
check "clean project: render prints nothing" "" "$(printf '%s' "$out" | bash "$VC" render)"
check "clean project --vault-wide: no findings" "" "$(bash "$VC" check --vault "$V1" --project clean --vault-wide)"

# ---- drifted project
V2="$TMPROOT/v2"; mkvault "$V2"
P="$V2/projects/clean"
cat > "$P/decisions.md" <<'DEC'
---
title: d
---

- [2026-10-01] bullet one
- [2026-10-02] bullet two

## [2026-10-20] Old thing
Old body.

## [2026-10-24] New thing
New body.
Supersedes: [2026-10-20] Old thing
DEC
printf '# Status\nLast updated: 2026-10-10 09:00 by claude-code\n\n## Last checkpoint\n[2026-10-12 09:00] later\n' > "$P/status.md"
sed -i.bak 's/| active | 2026-10-25 |/| active | 2026-10-05 |/' "$V2/INDEX.md"; rm -f "$V2/INDEX.md.bak"
sed -i.bak 's/^Name: clean/Name: other/' "$V2/INDEX.md"; rm -f "$V2/INDEX.md.bak"
printf '[2026-10-21 11:55] [sidecar] start — branch: A\n[2026-10-21 12:00] [sidecar] start — branch: B\n[2026-10-26 11:00] [lore] start — live session today\n' > "$P/.squad/session.log"
out="$(bash "$VC" check --vault "$V2" --project clean)"
has "scope line first" "VAULT_SCOPE=clean" "$out"
has "bullets (decisions-lint)" "DECISIONS_BULLETS=2" "$out"
has "missing inverse (decisions-lint)" "DECISIONS_MISSING_INVERSE=" "$out"
has "status stale" "STATUS_STALE=2026-10-10" "$out"
has "checkpoint newer" "STATUS_CHECKPOINT_NEWER=2026-10-12 09:00 > 2026-10-10 09:00" "$out"
has "index row behind" "INDEX_ROW_BEHIND=2026-10-05 < 2026-10-10" "$out"
lacks "another active project is not reported (#333)" "INDEX_ACTIVE_OTHER" "$out"
has "session unclosed count and oldest" "SESSION_UNCLOSED=2 oldest 2026-10-21 sidecar" "$out"
# decisions lines come from decisions-lint.sh, not reimplemented
want="$(bash "$TMPROOT/hooks/decisions-lint.sh" check "$P/decisions.md")"
dl="$(printf '%s\n' "$out" | grep '^DECISIONS_')"
check "decisions lines identical to decisions-lint.sh check" "$want" "$dl"
txt="$(printf '%s\n' "$out" | bash "$VC" render)"
has "render header" "### Vault health (clean)" "$txt"
has "render index line" "INDEX.md: row says 2026-10-05, status.md says 2026-10-10" "$txt"
has "render session line" "session.log: 2 start(s) without end (oldest 2026-10-21 sidecar)" "$txt"
has "render fix hint" "run lore check --fix" "$txt"

# missing decisions.md / status.md / index row
V3="$TMPROOT/v3"; mkvault "$V3"; rm "$V3/projects/clean/decisions.md" "$V3/projects/clean/status.md"
out="$(bash "$VC" check --vault "$V3" --project clean)"
has "decisions missing" "DECISIONS_FILE=missing" "$out"
has "status missing" "STATUS_FILE=missing" "$out"
V3b="$TMPROOT/v3b"; mkvault "$V3b"; : > "$V3b/projects/clean/decisions.md"
has "decisions empty" "DECISIONS_FILE=empty" "$(bash "$VC" check --vault "$V3b" --project clean)"
V3c="$TMPROOT/v3c"; mkvault "$V3c"; sed -i.bak '/^| \[\[projects/d' "$V3c/INDEX.md"; rm -f "$V3c/INDEX.md.bak"
has "no INDEX row" "INDEX_NO_ROW=clean" "$(bash "$VC" check --vault "$V3c" --project clean)"

# status over budget
V3d="$TMPROOT/v3d"; mkvault "$V3d"
{ cat "$V3d/projects/clean/status.md"; for i in $(seq 1 320); do printf 'w%d ' "$i"; done; echo; } > "$TMPROOT/s.md"; mv "$TMPROOT/s.md" "$V3d/projects/clean/status.md"
has "status over budget" "STATUS_OVER_BUDGET=" "$(bash "$VC" check --vault "$V3d" --project clean)"

# context: repo -> JOURNAL pointer
out="$(bash "$VC" check --vault "$V1" --project clean --context repo)"
has "repo context without JOURNAL pointer" "JOURNAL_POINTER_MISSING=clean" "$out"
printf 'See JOURNAL.md for the log.\n' >> "$V1/projects/clean/decisions.md"
check "repo context with JOURNAL pointer" "" "$(bash "$VC" check --vault "$V1" --project clean --context repo)"

# ---- --all: projects with no INDEX row and stray root files
V4="$TMPROOT/v4"; mkvault "$V4"
for n in orphan-a orphan-b orphan-c; do mkdir -p "$V4/projects/$n"; printf '# Status\nLast updated: 2026-10-25 10:00 by claude-code\n' > "$V4/projects/$n/status.md"; done
printf 'loose\n' > "$V4/insights-fix-plan.md"; printf 'x\n' > "$V4/squad-incidents.tsv"
out="$(bash "$VC" check --vault "$V4" --all)"
for n in orphan-a orphan-b orphan-c; do has "--all lists $n" "VAULT_PROJECT_NO_INDEX=$n" "$out"; done
has "--all lists stray root file" "VAULT_STRAY_ROOT=insights-fix-plan.md" "$out"
lacks "--all ignores known root files" "VAULT_STRAY_ROOT=squad-incidents.tsv" "$out"
lacks "--all ignores CLAUDE.md" "VAULT_STRAY_ROOT=CLAUDE.md" "$out"
out1="$(bash "$VC" check --vault "$V4" --project clean)"
lacks "no --all: no vault-wide pass" "VAULT_STRAY_ROOT" "$out1"

# ---- --fix: mechanical repairs, decision text byte-identical
cp "$P/decisions.md" "$TMPROOT/dec.before"
before_log="$(cat "$P/.squad/session.log")"
out="$(bash "$VC" check --fix --vault "$V2" --project clean)"
has "fix: INDEX row date" "FIXED_INDEX_ROW_DATE=clean" "$out"
has "fix: sessions closed" "FIXED_SESSION_CLOSED=2 clean" "$out"
has "fix: inverse applied" "DECISIONS_APPLIED_INVERSE=" "$out"
has "INDEX row date now status date" "| active | 2026-10-10 |" "$(cat "$V2/INDEX.md")"
lacks "fix leaves no row-behind finding" "INDEX_ROW_BEHIND" "$out"
lacks "fix leaves no unclosed finding" "SESSION_UNCLOSED" "$out"
lacks "fix leaves no missing inverse" "DECISIONS_MISSING_INVERSE" "$out"
log_after="$(cat "$P/.squad/session.log")"
has "closed without teardown line" "[sidecar] end — closed without teardown (start 2026-10-21 11:55)" "$log_after"
check "log is append-only" "$before_log" "$(printf '%s\n' "$log_after" | head -n 3)"
removed="$(diff "$TMPROOT/dec.before" "$P/decisions.md" | grep -c '^<')"
check "decisions: no original line removed or changed" "0" "$removed"
added="$(diff "$TMPROOT/dec.before" "$P/decisions.md" | grep '^>')"
check "decisions: only the inverse marker added" "> Superseded by: [2026-10-24] New thing" "$added"
sec_before="$(sed -n '/^## \[2026-10-24\]/,$p' "$TMPROOT/dec.before" | cksum)"
sec_after="$(sed -n '/^## \[2026-10-24\]/,$p' "$P/decisions.md" | cksum)"
check "decisions: superseding entry byte-identical" "$sec_before" "$sec_after"
bash "$VC" check --fix --vault "$V2" --project clean >/dev/null
check "fix is idempotent (log)" "$log_after" "$(cat "$P/.squad/session.log")"

# fix with nothing to repair keeps decisions.md byte-identical
V5="$TMPROOT/v5"; mkvault "$V5"; cp "$V5/projects/clean/decisions.md" "$TMPROOT/d5"
bash "$VC" check --fix --vault "$V5" --project clean >/dev/null
check "fix on clean decisions.md: byte-identical" "$(cksum < "$TMPROOT/d5")" "$(cksum < "$V5/projects/clean/decisions.md")"

# INDEX row added
V6="$TMPROOT/v6"; mkvault "$V6"; sed -i.bak '/^| \[\[projects/d' "$V6/INDEX.md"; rm -f "$V6/INDEX.md.bak"
out="$(bash "$VC" check --fix --vault "$V6" --project clean)"
has "fix: INDEX row added" "FIXED_INDEX_ROW_ADDED=clean" "$out"
check "added row sits at the end of the Projects table" '| [[projects/clean/status\|clean]] | active | 2026-10-25 |' "$(grep -B1 '^$' "$V6/INDEX.md" | grep 'projects/clean/status\\' )"
has "Content section kept" "## Content" "$(cat "$V6/INDEX.md")"

# ---- --fix commits only what it wrote
gitvault() { git -C "$1" init -q >/dev/null 2>&1; git -C "$1" config user.email t@t; git -C "$1" config user.name t
  git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -q -m init >/dev/null 2>&1; }
VG="$TMPROOT/vg"; mkvault "$VG"
mkdir -p "$VG/projects/other"; printf 'o\n' > "$VG/projects/other/notes.md"
printf '[2026-10-21 11:55] [sidecar] start — A\n' >> "$VG/projects/clean/.squad/session.log"
gitvault "$VG"
printf 'u\n' > "$VG/unrelated.txt"; git -C "$VG" add unrelated.txt
printf 'dirty\n' >> "$VG/projects/other/notes.md"
bash "$VC" check --fix --vault "$VG" --project clean >/dev/null
files="$(git -C "$VG" show --name-only --format= HEAD)"
check "fix commit holds only the written file" "projects/clean/.squad/session.log" "$files"
check "unrelated staged file stays staged" "A  unrelated.txt" "$(git -C "$VG" status --porcelain unrelated.txt)"
check "unrelated dirty file stays dirty" " M projects/other/notes.md" "$(git -C "$VG" status --porcelain projects/other/notes.md)"
head1="$(git -C "$VG" rev-parse HEAD)"
bash "$VC" check --fix --vault "$VG" --project clean >/dev/null
check "fix with nothing to repair creates no commit" "$head1" "$(git -C "$VG" rev-parse HEAD)"

# ---- same-tag orphan plus a live session today
VS="$TMPROOT/vs"; mkvault "$VS"; LOG="$VS/projects/clean/.squad/session.log"
printf '[2026-10-21 11:55] [sidecar] start — old\n[2026-10-26 09:00] [sidecar] start — live\n' > "$LOG"
out="$(bash "$VC" check --fix --vault "$VS" --project clean)"
has "same-tag fix closes the orphan" "FIXED_SESSION_CLOSED=1 clean" "$out"
snap="$(cat "$LOG")"
out="$(bash "$VC" check --fix --vault "$VS" --project clean)"
lacks "second fix reports nothing closed" "FIXED_SESSION_CLOSED" "$out"
check "second fix leaves the log unchanged" "$snap" "$(cat "$LOG")"
check "old orphan closed exactly once" "1" "$(grep -c 'closed without teardown (start 2026-10-21 11:55)' "$LOG")"
check "live start still open" "2026-10-26 09:00	sidecar" "$(. "$VC"; session_orphans "$LOG")"
printf '[2026-10-26 11:00] [sidecar] end — done\n' >> "$LOG"
check "real end pairs with the live start" "" "$(. "$VC"; session_orphans "$LOG")"
# the unfiltered view: live start closed by its own end, orphan stays closed
check "no orphan resurfaces" "" "$(. "$VC"; session_orphans "$LOG" 9999-99-99)"

# ---- missing decisions.md renders readably
VM="$TMPROOT/vm"; mkvault "$VM"; rm -f "$VM/projects/clean/decisions.md"
txt="$(bash "$VC" check --vault "$VM" --project clean | bash "$VC" render)"
has "missing decisions.md renders" "decisions.md: file is missing" "$txt"

# ---- orientation wiring (mapped project via lore-config.json)
V7="$TMPROOT/v7"; mkvault "$V7"
mkdir -p "$TMPROOT/proj7"; git -C "$TMPROOT/proj7" init -q >/dev/null 2>&1
PROJ7="$(cd "$TMPROOT/proj7" && pwd -P)"
printf '{"projects":{"%s":"clean"}}\n' "$PROJ7" > "$V7/lore-config.json"
printf '[2026-10-21 11:55] [sidecar] start — branch: A\n' > "$V7/projects/clean/.squad/session.log"
printf '# Status\nLast updated: 2026-10-10 09:00 by claude-code\n' > "$V7/projects/clean/status.md"
sed -i.bak 's/| active | 2026-10-25 |/| active | 2026-10-05 |/' "$V7/INDEX.md"; rm -f "$V7/INDEX.md.bak"
printf -- '- [2026-10-01] bullet\n' > "$V7/projects/clean/decisions.md"
printf 'DECISIONS_BULLETS=1\n' > "$V7/projects/clean/.decisions-lint"
o="$(cd "$PROJ7" && SECOND_BRAIN_PATH="$V7" bash "$TMPROOT/hooks/lore-orient.sh" </dev/null 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then ctx="$(printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext')"; else ctx="$o"; fi
has "orientation prints the health block" "### Vault health (clean)" "$ctx"
has "orientation INDEX line" "INDEX.md: row says 2026-10-05, status.md says 2026-10-10" "$ctx"
has "orientation session line" "session.log: 1 start(s) without end" "$ctx"
check "decisions bullets line printed once (saved findings folded in)" "1" "$(printf '%s\n' "$ctx" | grep -c "entries use '- \[YYYY-MM-DD\]' bullets")"
# clean project: no block
V8="$TMPROOT/v8"; mkvault "$V8"
printf '{"projects":{"%s":"clean"}}\n' "$PROJ7" > "$V8/lore-config.json"
o="$(cd "$PROJ7" && SECOND_BRAIN_PATH="$V8" bash "$TMPROOT/hooks/lore-orient.sh" </dev/null 2>/dev/null)"
lacks "clean project: orientation has no Vault health block" "Vault health" "$o"

# ---- budget: 400 files, under 200 ms without --all
V9="$TMPROOT/v9"; mkvault "$V9"
mkdir -p "$V9/projects/clean/notes"
i=0; while [ $i -lt 400 ]; do printf 'n\n' > "$V9/projects/clean/notes/f$i.md"; i=$((i+1)); done
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do mkdir -p "$V9/projects/p$n"; printf '# S\nLast updated: 2026-10-25 10:00\n' > "$V9/projects/p$n/status.md"; done
now_ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || echo 0; }
s=$(now_ms); bash "$VC" check --vault "$V9" --project clean --vault-wide >/dev/null; e=$(now_ms)
ms=$((e - s))
if [ "$ms" -lt 200 ]; then ok "400-file vault check under 200 ms (${ms} ms)"; else bad "400-file vault check took ${ms} ms"; fi

# full orient path (check + render + decisions-lint subprocesses)
mkdir -p "$TMPROOT/proj9"; git -C "$TMPROOT/proj9" init -q >/dev/null 2>&1
PROJ9="$(cd "$TMPROOT/proj9" && pwd -P)"
printf '{"projects":{"%s":"clean"}}\n' "$PROJ9" > "$V9/lore-config.json"
printf '[2026-10-21 11:55] [sidecar] start — A\n' > "$V9/projects/clean/.squad/session.log"
s=$(now_ms); (cd "$PROJ9" && SECOND_BRAIN_PATH="$V9" bash "$TMPROOT/hooks/lore-orient.sh" </dev/null >/dev/null 2>&1); e=$(now_ms)
ms=$((e - s))
if [ "$ms" -lt 200 ]; then ok "400-file full orientation under 200 ms (${ms} ms)"; else bad "400-file full orientation took ${ms} ms"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
