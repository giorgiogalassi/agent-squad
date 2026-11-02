#!/usr/bin/env bash
# Tier-1 tests for claude/hooks/squad-atlas.py gather (base resolution and
# verdict parsing) and squad-retro.py's progress.txt review parser.
# Plain bash 3.2 + python3; no bats, no jq.
# Usage: scripts/test-squad-atlas.sh
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ATLAS="$REPO_ROOT/claude/hooks/squad-atlas.py"
RETRO="$REPO_ROOT/claude/hooks/squad-retro.py"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-squad-atlas
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMPROOT/home"
mkdir -p "$HOME"

# Upstream: main moves 3 commits past the clone's local main; the feature
# branch is cut from the newer origin/main and adds one file.
UP="$TMPROOT/up"; CL="$TMPROOT/clone"
git init -q -b main "$UP"
( cd "$UP" && echo a > a && git add a && git commit -qm init )
git clone -q "$UP" "$CL" 2>/dev/null
( cd "$UP" && for i in 1 2 3; do echo "$i" > "u$i"; git add "u$i"; git commit -qm "upstream $i"; done )
( cd "$CL" && git fetch -q origin && git checkout -q -b feat origin/main \
  && echo f > f && git add f && git commit -qm "feature" && git checkout -q main )

VAULT="$TMPROOT/vault"; SD="$VAULT/projects/demo/.squad"
mkdir -p "$SD"
cat > "$SD/ralph-run.md" <<'EOR'
| Issue | Branch | Base |
|---|---|---|
| #7 | feat | main |
EOR
cat > "$SD/progress.txt" <<'EOP'
[#7] review: CHANGES_REQUESTED r1. Obs: missing test for the empty case
[#7] 2026-11-02 review: CHANGES_REQUESTED r2 on full PR at d13fdd73e2 (blocking: no fallback; non-blocking: naming)
[#7] review: COMMENT r3 on the uncommitted number/rating diff (nothing blocking; obs: rename the helper)
[#7] review: COMMENT r4 (only a nit)
[#7] review: APPROVED r5
EOP
export SQUAD_VAULT_PATH="$VAULT" SQUAD_PROJECT_ROOT="$CL" SQUAD_DISPLAY_NAME=demo SQUAD_TRACKER_MODE=detached

OUT=""; RC=0
run() { OUT="$(cd "$CL" && python3 "$ATLAS" gather "$@" 2>"$TMPROOT/err")"; RC=$?; }
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

run feat
check "A-1 stale local main: compares against origin/main" "0/origin/main/1/1" \
  "$RC/$(key BASE)/$(key COMMITS)/$(key FILES)"
check "A-2 atlas.json base is the ref used" "origin/main" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base"])' "$SD/atlas/feat/atlas.json")"

run feat --base main
check "A-3 --base overrides as given" "0/main/4/4" "$RC/$(key BASE)/$(key COMMITS)/$(key FILES)"

run --base=origin/main feat
check "A-4 --base= form" "0/origin/main" "$RC/$(key BASE)"

run feat --base nope
check "A-5 --base on a missing ref: rc 10" "10" "$RC"

run feat --base
check "A-6 --base without a value: rc 2" "2" "$RC"

( cd "$CL" && git remote remove origin )
run feat
check "A-7 no origin: falls back to local main" "0/main/4" "$RC/$(key BASE)/$(key COMMITS)"

VJSON="$(python3 -c 'import json,sys
for v in json.load(open(sys.argv[1]))["verdicts"]: print("%d|%s|%s" % (v["round"], v["verdict"], v["obs"]))' "$SD/atlas/feat/atlas.json")"
line() { printf '%s\n' "$VJSON" | sed -n "${1}p"; }
check "V-0 all five review lines recognised" "5" "$(printf '%s\n' "$VJSON" | grep -c .)"
check "V-1 legacy '. Obs:' form" "1|CHANGES_REQUESTED|missing test for the empty case" "$(line 1)"
check "V-2 dated, trailing text kept" \
  "2|CHANGES_REQUESTED|on full PR at d13fdd73e2 (blocking: no fallback; non-blocking: naming)" "$(line 2)"
check "V-3 lowercase obs: inside parentheses" "3|COMMENT|rename the helper" "$(line 3)"
check "V-4 surrounding parentheses dropped" "4|COMMENT|only a nit" "$(line 4)"
check "V-5 bare verdict, no observations" "5|APPROVED|" "$(line 5)"
check "V-6 VERDICTS counts rounds with observations" "4" "$(key VERDICTS)"

RJSON="$(python3 - "$RETRO" "$SD/progress.txt" <<'EOPY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("retro", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for n, v, o in m.parse_progress(open(sys.argv[2]).read().splitlines())["7"]["rounds"]:
    print("%d|%s|%s" % (n, v, o))
EOPY
)"
check "R-1 retro parses the same five rounds" "$VJSON" "$RJSON"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
