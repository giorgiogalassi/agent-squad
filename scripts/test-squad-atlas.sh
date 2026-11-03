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
unset SQUAD_DIR
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

run feat
check "A-1c re-run: unchanged" "unchanged/no" "$(key OUTCOME)/$(key CHANGED)"

# Head that exists only on origin: resolved like the base, no exit 10.
( cd "$UP" && git checkout -q -b remote-only main && echo r > r && git add r && git commit -qm "remote only" && git checkout -q main )
( cd "$CL" && git fetch -q origin )
run remote-only
check "A-8 origin-only head resolves via origin/<head>" "0/origin/remote-only/1" "$RC/$(key HEAD)/$(key FILES)"

# Renames: --no-renames keeps every path plain.
( cd "$CL" && git checkout -q -b ren origin/main && git mv a a-renamed && git commit -qm rename && git checkout -q main )
run ren --base origin/main
check "A-9 rename is delete+add, no 'old => new' path" "0/2/0" \
  "$RC/$(key FILES)/$(python3 -c 'import json,sys; print(sum("=>" in f["path"] for f in json.load(open(sys.argv[1]))["files"]))' "$SD/atlas/ren/atlas.json")"

# One bad batch row does not abort the others.
cp "$SD/ralph-run.md" "$TMPROOT/ralph-run.bak"
echo '| #8 | no-such-branch | main |' >> "$SD/ralph-run.md"
run --batch
check "A-10 batch: bad row reported, good row done" "0/2/1/1" \
  "$RC/$(key ROWS)/$(key ROWS_FAILED)/$(printf '%s\n' "$OUT" | grep -c '^ROW_ERROR=')"
check "A-10b batch: the good row still emitted its block" "1" "$(printf '%s\n' "$OUT" | grep -c '^ID=feat$')"
cp "$TMPROOT/ralph-run.bak" "$SD/ralph-run.md"

# scout-cache.md and forge/output.yaml come from $SQUAD_DIR, not the vault.
RS="$TMPROOT/repo-squad"; mkdir -p "$RS/forge"
printf '## Module map\n- `f` -- the feature file\n' > "$RS/scout-cache.md"
printf 'acceptance_criteria:\n  - "one"\n  - "two"\n' > "$RS/forge/output.yaml"
run feat
check "A-11 no SQUAD_DIR knowledge: root module, no criteria" "(root)/0" "$(key MODULES)/$(key CRITERIA)"
SQUAD_DIR="$RS" run feat
check "A-12 context: repo: module map and criteria from SQUAD_DIR" "f/2" "$(key MODULES)/$(key CRITERIA)"
check "A-12b atlas/ output stays in the vault" "yes" "$([ -f "$SD/atlas/feat/atlas.json" ] && echo yes)"

# ---------------------------------------------------------------- #410
# Graph page: mandatory graph, host links from the remote, no inline diffs,
# no commit list; issue key from the branch name; stale brief header.
arender() { OUT="$(cd "$CL" && python3 "$ATLAS" render "$@" 2>"$TMPROOT/err")"; RC=$?; }
( cd "$CL" && git remote set-url origin git@bitbucket.org:ws/demo.git )
run feat
GATHER="$OUT"
arender feat
PAGE="$SD/atlas/feat/index.html"
check "P-1 render exits 0" "0/applied" "$RC/$(key OUTCOME)"
check "P-2 the page carries the change graph" "1/1" "$(grep -c 'id="cg-data"' "$PAGE")/$(grep -c 'id="graph"' "$PAGE")"
check "P-3 no inline diffs, no commit list" "0/0/0" \
  "$(grep -c '<pre class="diff"' "$PAGE")/$(grep -c '^@@\|<span class="a">' "$PAGE")/$(grep -ci 'id="commits"\|<h2>Commits' "$PAGE")"
check "P-4 file list links to the host (Bitbucket shape)" "1" \
  "$([ "$(grep -c 'https://bitbucket.org/ws/demo/src/[0-9a-f]\{40\}/f"' "$PAGE")" -ge 1 ] && echo 1)"
check "P-5 node data carries a Bitbucket commit link" "1" "$([ "$(grep -c 'https://bitbucket.org/ws/demo/commits/' "$PAGE")" -ge 1 ] && echo 1)"
check "P-6 page stays small" "yes" "$([ "$(wc -c < "$PAGE")" -lt 40000 ] && echo yes)"
check "P-7 graph and units keys from gather" "folder/1/(root)" "$(OUT="$GATHER"; key UNIT_SOURCE)/$(OUT="$GATHER"; key UNITS)/$(OUT="$GATHER"; key MODULES)"
python3 - "$SD/atlas/feat/atlas.json" "$TMPROOT/no-graph.json" <<'EOPY'
import json, sys
d = json.load(open(sys.argv[1])); d.pop("graph"); json.dump(d, open(sys.argv[2], "w"))
EOPY
mkdir -p "$SD/atlas/old" && cp "$TMPROOT/no-graph.json" "$SD/atlas/old/atlas.json" && cp "$SD/atlas/feat/brief.md" "$SD/atlas/old/brief.md"
arender old
check "P-8 atlas.json without a graph: render rc 10 (the graph is mandatory)" "10" "$RC"
( cd "$CL" && git remote set-url origin "$UP" )
run feat
arender feat
check "P-9 unknown host: page renders, no links, says why" "0/0/1" \
  "$RC/$(grep -c 'href="https' "$PAGE")/$(grep -c 'No links' "$PAGE")"

# Branch name as the issue key; hostile commit subject and file name.
( cd "$CL" && git checkout -q -b 410-thing origin/main && printf 'x\n' > '<b>x.txt' && git add -A \
  && git commit -qm '</script><script>alert(1)</script>' && git checkout -q main )
printf '[#410] review: COMMENT r1 (obs: rename the helper)\n' >> "$SD/progress.txt"
run 410-thing
check "P-10 branch named like an issue key: verdicts collected" "1" "$(key VERDICTS)"
arender 410-thing
EVIL="$SD/atlas/410-thing/index.html"
check "P-11 no raw closing script tag, no raw element from a file name" "0/0" \
  "$(grep -c '</script><script>alert' "$EVIL")/$(grep -c '<b>x.txt' "$EVIL")"

# Re-gather keeps the brief text, refreshes a stale header.
printf '\nMY ANALYSIS\n' >> "$SD/atlas/feat/brief.md"
run feat --base main
check "P-12 stale Range line refreshed, text kept" "refreshed/1/1" \
  "$(key BRIEF_HEADER)/$(grep -c 'MY ANALYSIS' "$SD/atlas/feat/brief.md")/$(grep -c 'Range: `main\.\.\.feat`' "$SD/atlas/feat/brief.md")"
run feat --base main
check "P-13 header already current" "current" "$(key BRIEF_HEADER)"
sed -i.bak 's/^Range:.*$/Range: gone/' "$SD/atlas/feat/brief.md" && rm "$SD/atlas/feat/brief.md.bak"
run feat --base main
check "P-14 edited-away Range line: flagged, not overwritten" "unrecognised/1" "$(key BRIEF_HEADER)/$(grep -c '^Range: gone' "$SD/atlas/feat/brief.md")"

# A project folder below the repository root: paths start with the prefix.
( cd "$CL" && git checkout -q -b below origin/main && mkdir -p app/libs/a app/libs/b && printf '{"name":"a"}\n' > app/libs/a/project.json \
  && printf '{"name":"b"}\n' > app/libs/b/project.json && printf 'export const a = 1;\n' > app/libs/a/x.ts && printf 'export const b = 1;\n' > app/libs/b/y.ts \
  && echo outside > outside.txt && git add -A && git commit -qm below && git checkout -q main )
mkdir -p "$CL/app"
SQUAD_PROJECT_ROOT="$CL/app" run below
check "P-15 below-root project: units grouped despite the repo-root prefix" "manifest/libs/a,libs/b" "$(key UNIT_SOURCE)/$(key MODULES)"

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

# ---------------------------------------------------------------- retro
# Window, held% with unknown follow-ups, blocking-vs-non-blocking kinds.
d_ago() { python3 -c 'import datetime,sys; print((datetime.date.today()-datetime.timedelta(days=int(sys.argv[1]))).isoformat())' "$1"; }
RV="$TMPROOT/rvault"; RSD="$RV/projects/rdemo/.squad"; RC="$TMPROOT/rclone"
mkdir -p "$RSD"
git init -q -b main "$RC"
( cd "$RC" && echo a > a && git add a && git commit -qm init \
  && git checkout -q -b b10 && echo 1 > f1 && git add f1 && git commit -qm "ten" && git checkout -q main \
  && git merge -q --no-ff b10 -m "Merge pull request #100 from u/b10" \
  && git checkout -q -b prefix-fix-more && echo 2 > f2 && git add f2 && git commit -qm "other" && git checkout -q main \
  && git merge -q --no-ff prefix-fix-more -m "Merge pull request #50 from u/prefix-fix-more" )
cat > "$RSD/ralph-run.md" <<'EOR'
| Issue | Branch | Base |
|---|---|---|
| #10 | b10 | main |
| #13 | fix | main |
EOR
D5="$(d_ago 5)"; D400="$(d_ago 400)"
cat > "$RSD/progress.txt" <<EOP
[#10] $D5 review: CHANGES_REQUESTED r1 (blocking: no fallback; non-blocking: naming)
[#10] $D5 review: APPROVED r2
[#10] $D5 resolved. PR: #100 (base: main)
[#11] review: CHANGES_REQUESTED r1. Obs: missing test for the empty case
[#12] $D400 review: CHANGES_REQUESTED r1. Obs: missing test
[#12] $D400 resolved. PR: #90 (base: main)
[#13] $D5 review: COMMENT r1 (nothing blocking; obs: rename the helper, cache the lookup)
[#13] $D5 review: APPROVED r2
[#13] $D5 resolved. PR: #101 (base: main)
[#14] $D5 review: CHANGES_REQUESTED r1. Obs: the author field is wrong and scout-cache is stale
[#15] $D5 review: CHANGES_REQUESTED r1. Obs: latest results are not asserted, add a test; non-blocking: naming
EOP
printf 'ts\tpr\tverdict\n' > "$RSD/verdicts.tsv"
export SQUAD_VAULT_PATH="$RV" SQUAD_PROJECT_ROOT="$RC" SQUAD_DISPLAY_NAME=rdemo SQUAD_TRACKER_MODE=detached
rrun() { OUT="$(cd "$RC" && python3 "$RETRO" "$@" 2>"$TMPROOT/err")"; RC_=$?; }
trail_keys() { python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["trail"])))' "$RSD/retro/.trail.json"; }
trail_kinds() { python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["trail"]; print(";".join("%s=%s" % (k, "+".join(t[k]["kinds"])) for k in sorted(t)))' "$RSD/retro/.trail.json"; }

rrun collect --days 30
check "T-1 window: dated recent only; undated #11 and old #12 left out" "0/10,13,14,15" "$RC_/$(trail_keys)"
check "T-2 first collect applied" "applied/yes" "$(key OUTCOME)/$(key CHANGED)"
rrun collect --days 30
check "T-2b re-run unchanged" "unchanged/no" "$(key OUTCOME)/$(key CHANGED)"
rrun collect --days 3650
check "T-3 wide window adds #12, still not undated #11" "10,12,13,14,15" "$(trail_keys)"
rrun collect --days 30
check "T-4 blocking vs non-blocking, word boundaries, COMMENT ignored" \
  "10=error handling;13=;14=other;15=tests" "$(trail_kinds)"
check "T-5 git-only: SOURCE and merge detected, follow-ups unknown" "git-only/?" "$(key SOURCE)/$(key FOLLOWED_UP)"
rrun report
check "T-6 HELD_PCT unknown, not 100" "?" "$(key HELD_PCT)"
REPORT="$(key REPORT)"
check "T-7 report says follow-ups unknown for the merged approval" "1" \
  "$(grep -c 'merged with follow-ups unknown: 1' "$REPORT")"
check "T-8 anchored branch grep: #13 (branch 'fix') not merged" "1" "$(grep -c 'not merged or unknown: 1' "$REPORT")"
check "T-9 naming never credited (only non-blocking)" "0" "$(grep -c '^| naming' "$REPORT")"
check "T-10 candidates labelled unvalidated" "1" "$(grep -c 'unvalidated until #403' "$REPORT")"
rrun report
check "T-11 report re-run unchanged" "unchanged/no" "$(key OUTCOME)/$(key CHANGED)"

# Known follow-ups: held% counts only judged approvals.
python3 - "$RSD/retro/.trail.json" <<'EOPY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["trail"]["10"]["post"]["followups"] = 0
d["trail"]["13"]["post"].update({"merged": "2026-01-01", "followups": 2, "state": "MERGED"})
json.dump(d, open(p, "w"))
EOPY
rrun report
check "T-12 one held, one followed by a fix: 50%" "50" "$(key HELD_PCT)"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
