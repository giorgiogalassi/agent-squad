#!/usr/bin/env bash
# Tests the Bitbucket Cloud VCS adapter (claude/hooks/vcs/bitbucket.sh) through the
# VCS facade and squad-pr-desc.sh, over recorded responses (scripts/fixtures/
# bitbucket/) and the curl shim (scripts/curl-shim/curl): no network, no real
# Bitbucket. Proves that no `gh` is called, that the token appears on no argv,
# output, log or file, that the write policy and detached mode refuse writes before
# any request, and that the description drift is kept in the handoff when the policy
# denies description-set. Plain bash 3.2; jq needed.
set -u
export SQUAD_INCIDENTS=off
unset SQUAD_VAULT_PATH SQUAD_PROJECT_ROOT SQUAD_DISPLAY_NAME SQUAD_DIR SQUAD_TRACKER_MODE SQUAD_TRACKER_PROVIDER SQUAD_VCS_PROVIDER SQUAD_BITBUCKET_TOKEN
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
VCS="$REPO_ROOT/claude/hooks/squad-vcs.sh"
DESC="$REPO_ROOT/claude/hooks/squad-pr-desc.sh"
FX="$REPO_ROOT/scripts/fixtures/bitbucket"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-vcs-bitbucket
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
command -v jq >/dev/null 2>&1 || { echo "skip - jq missing"; exit 0; }

TOKEN="BBTESTTOKEN-must-never-leak-5c1d"
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >> "$GHLOG"
exit 1
STUB
chmod +x "$BIN/gh"
export GHLOG="$TMPROOT/gh.log"; : > "$GHLOG"
export CURL_SHIM_FIXTURES="$FX" CURL_SHIM_LOG="$TMPROOT/curl.log" CURL_SHIM_ARGV="$TMPROOT/argv.log" CURL_SHIM_ROUTES="$TMPROOT/routes"
: > "$CURL_SHIM_LOG"; : > "$CURL_SHIM_ARGV"
ALL="$TMPROOT/all.out"; : > "$ALL"

setcfg() { jq "$@" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"; }
out="$(TMPDIR="$TMPROOT" "$MK" connected)" || exit 1
P="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"; V="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
CFG="$V/projects/fixture/.squad/chisel-config.json"
setcfg '.chisel.vcs = "bitbucket"'
git -C "$P" remote add bb git@bitbucket.org:acme/app.git
git -C "$P" remote set-url origin git@bitbucket.org:acme/app.git
RC=0
# bb <cmd...>: run in the fixture project with the shims first on PATH; stdout in OUT, rc in RC.
bb() {
  OUT="$(cd "$P" && PATH="$REPO_ROOT/scripts/curl-shim:$BIN:$PATH" SECOND_BRAIN_PATH="$V" SQUAD_BITBUCKET_TOKEN="${TOK-$TOKEN}" "$@" 2>"$TMPROOT/err")"; RC=$?
  { printf '%s\n' "$OUT"; cat "$TMPROOT/err"; } >> "$ALL"
}
routes() { cat > "$CURL_SHIM_ROUTES"; : > "$CURL_SHIM_LOG"; }
key() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
callsx() { grep -cxF "$1" "$CURL_SHIM_LOG"; }
body_of() { grep -xF -A1 "$1" "$CURL_SHIM_LOG" | sed -n 's/^BODY //p' | head -n 1; }
R=/repositories/acme/app

# --- credentials, repository detection
TOK="" routes <<RT
GET $R repo.json
RT
TOK="" bb bash "$VCS" default-branch
check "no token: exit 10" 10 "$RC"
check "no token: no request made" 0 "$(wc -l < "$CURL_SHIM_LOG" | tr -d ' ')"
grep -q "squad-bitbucket" "$TMPROOT/err" && ok "no token: stderr says where to put it" || bad "no token: stderr says where to put it"

mkdir -p "$TMPROOT/kc"
cat > "$TMPROOT/kc/security" <<STUB
#!/bin/sh
[ "\$1 \$2 \$3 \$4 \$5 \$6" = "find-generic-password -s squad-bitbucket -a acme -w" ] && echo "$TOKEN" && exit 0
exit 44
STUB
chmod +x "$TMPROOT/kc/security"
routes <<RT
GET $R repo.json
RT
OUT="$(cd "$P" && PATH="$REPO_ROOT/scripts/curl-shim:$TMPROOT/kc:$BIN:$PATH" SECOND_BRAIN_PATH="$V" bash "$VCS" default-branch 2>"$TMPROOT/err")"; RC=$?
{ printf '%s\n' "$OUT"; cat "$TMPROOT/err"; } >> "$ALL"
check "keychain token (account = workspace): default-branch" "DEFAULT_BRANCH=main" "$OUT"

routes <<RT
GET $R repo.json
RT
bb bash "$VCS" default-branch
check "default-branch" "DEFAULT_BRANCH=main" "$OUT"
check "workspace and slug come from an scp-style origin" 1 "$(callsx "GET $R")"
git -C "$P" remote set-url origin "https://me@bitbucket.org/acme/app.git"
routes <<RT
GET $R repo.json
RT
bb bash "$VCS" default-branch
check "https origin with a user is parsed" 1 "$(callsx "GET $R")"
git -C "$P" remote set-url origin "ssh://git@bitbucket.org/acme/app"
routes <<RT
GET $R repo.json
RT
bb bash "$VCS" default-branch
check "ssh:// origin without .git is parsed" 1 "$(callsx "GET $R")"
git -C "$P" remote set-url origin "https://github.com/acme/app.git"
routes <<RT
GET $R repo.json
RT
bb bash "$VCS" default-branch
check "a non-bitbucket origin: exit 10" 10 "$RC"
setcfg '.chisel.bitbucket_workspace = "other" | .chisel.bitbucket_repo = "thing"'
routes <<RT
GET /repositories/other/thing repo.json
RT
bb bash "$VCS" default-branch
check "config overrides the remote" "DEFAULT_BRANCH=main" "$OUT"
setcfg 'del(.chisel.bitbucket_workspace, .chisel.bitbucket_repo)'
git -C "$P" remote set-url origin git@bitbucket.org:acme/app.git

# user set -> Basic, none -> Bearer (the shim accepts both; the log never holds headers)
setcfg '.chisel.bitbucket_user = "bob"'
routes <<RT
GET $R repo.json
RT
bb bash "$VCS" default-branch
check "bitbucket_user: Basic auth accepted" "DEFAULT_BRANCH=main" "$OUT"
setcfg 'del(.chisel.bitbucket_user)'

# --- reads
routes <<RT
GET $R repo.json
RT
bb bash "$VCS" auth-status; check "auth-status ok" 0 "$RC"
routes <<RT
GET $R repo.json 403
RT
bb bash "$VCS" auth-status; check "auth-status rejected" 1 "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
bb bash "$VCS" available; check "available" 0 "$RC"
bb bash "$VCS" cli-name; check "cli-name" "CLI_NAME=curl" "$OUT"

routes <<RT
GET $R/refs/branches/12-feature branch-ok.json
GET $R/refs/branches/feat/x%20y not-found.json 404
RT
bb bash "$VCS" branch-exists 12-feature; check "branch-exists yes" "EXISTS=yes" "$OUT"
bb bash "$VCS" branch-exists "feat/x y"; check "branch-exists no (slash kept, space encoded)" "EXISTS=no" "$OUT"

routes <<RT
GET $R/pullrequests?q=*state=OPEN&state=MERGED* prs-all.json
GET $R/pullrequests?q=*state=MERGED* prs-merged.json
GET $R/pullrequests?q=*state=OPEN&sort* prs-open.json
GET $R/commit/abcdef123456 commit-abcdef.json
GET $R/commit/111111111111 commit-1111.json
GET $R/commit/222222222222 commit-2222.json
RT
bb bash "$VCS" pr-for-branch 12-feature
check "pr-for-branch open: PR" 7 "$(key "$OUT" PR)"
check "pr-for-branch open: BASE" main "$(key "$OUT" BASE)"
bb bash "$VCS" pr-for-branch 12-feature --state all
check "pr-for-branch all: states in order, DECLINED reads CLOSED" "STATE=OPEN HEAD_OID=abcdef1234567890abcdef1234567890abcdef12 STATE=CLOSED HEAD_OID=1111111111111111111111111111111111111111" "$(printf '%s\n' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
bb bash "$VCS" pr-for-branch 12-feature --state merged
check "pr-for-branch merged: full HEAD_OID" "HEAD_OID=2222222222222222222222222222222222222222" "$OUT"
routes <<RT
GET $R/pullrequests?q=* prs-empty.json
RT
bb bash "$VCS" pr-for-branch nothing
check "pr-for-branch with no PR: empty, exit 0" "0:" "$RC:$OUT"
bb bash "$VCS" pr-for-branch 'a"b'; check "pr-for-branch: a quote in the branch is a usage error" 2 "$RC"

routes <<RT
GET $R/pullrequests?state=OPEN* prs-list.json
RT
bb bash "$VCS" pr-list --state open --limit 5
check "pr-list display lines (newline in a title flattened)" "#7 [#12] Add the thing (12-feature -> main)
#8 [#14] other line (14-other -> main)" "$OUT"

routes <<RT
GET $R/pullrequests/7/diffstat?page=2 diffstat-2.json
GET $R/pullrequests/7/diffstat?* diffstat-1.json
GET $R/pullrequests/7 pr-7.json
GET $R/pullrequests/4 pr-4-merged.json
GET $R/pullrequests/99 not-found.json 404
RT
bb bash "$VCS" pr-view 7 --field base; check "pr-view base" "BASE=main" "$OUT"
bb bash "$VCS" pr-view 7 --field state; check "pr-view state" "STATE=OPEN" "$OUT"
bb bash "$VCS" pr-view 7 --field title; check "pr-view title" "TITLE=[#12] Add the thing" "$OUT"
bb bash "$VCS" pr-view 7 --field url; check "pr-view url" "URL=https://bitbucket.org/acme/app/pull-requests/7" "$OUT"
bb bash "$VCS" pr-view 7 --field changed-files; check "pr-view changed-files follows pagination" "CHANGED_FILES=3" "$OUT"
bb bash "$VCS" pr-view 99 --field base; check "pr-view of an unknown PR: 20" 20 "$RC"
bb bash "$VCS" pr-view 7 --field nope; check "pr-view bad field: 2" 2 "$RC"
bb bash "$VCS" merged 7; check "merged no" "MERGED=no" "$OUT"
bb bash "$VCS" merged 4; check "merged yes" "MERGED=yes" "$OUT"
routes <<RT
GET $R/pullrequests/7/diffstat?* diffstat-evil.json
RT
bb bash "$VCS" pr-view 7 --field changed-files
check "a next link off the API host is refused" 20 "$RC"
check "the token never went to the foreign host" 0 "$(grep -c evil "$CURL_SHIM_LOG")"

# pr-view by branch resolves the open PR
routes <<RT
GET $R/pullrequests?q=*state=OPEN&sort* prs-open.json
RT
bb bash "$VCS" pr-view 12-feature --field base; check "pr-view by branch" "BASE=main" "$OUT"

# pr-data
routes <<RT
GET $R/pullrequests/7/commits?* commits-7.json
GET $R/pullrequests/7/diffstat?* diffstat-2.json
GET $R/pullrequests/7/comments?* comments-7.json
GET $R/pullrequests/7 pr-7.json
GET $R/pullrequests/4 pr-4-merged.json
RT
bb bash "$VCS" pr-data 7 --fields number,state,createdAt,mergedAt,commits
check "pr-data: only the requested keys" "commits,createdAt,mergedAt,number,state" "$(printf '%s' "$OUT" | jq -r 'keys | join(",")')"
check "pr-data: createdAt is second precision UTC" "2026-11-01T10:00:00Z" "$(printf '%s' "$OUT" | jq -r .createdAt)"
check "pr-data: open PR has no mergedAt" null "$(printf '%s' "$OUT" | jq -r .mergedAt)"
check "pr-data: commits in the GitHub shape" "2026-11-01T10:05:00Z first commit aaaaaaaaaaaa" "$(printf '%s' "$OUT" | jq -r '.commits[0] | "\(.committedDate) \(.messageHeadline) \(.oid)"')"
bb bash "$VCS" pr-data 7 --fields title,body,headRefName,baseRefName,url,files,comments,reviews
check "pr-data: head/base/title" "[#12] Add the thing 12-feature main" "$(printf '%s' "$OUT" | jq -r '"\(.title) \(.headRefName) \(.baseRefName)"')"
check "pr-data: files" "b.txt" "$(printf '%s' "$OUT" | jq -r '[.files[].path] | join(",")')"
check "pr-data: comments (deleted dropped), author login" "looks good maria" "$(printf '%s' "$OUT" | jq -r '[.comments[] | "\(.body) \(.author.login)"] | join(",")')"
check "pr-data: reviews are the approvals" "maria APPROVED" "$(printf '%s' "$OUT" | jq -r '[.reviews[] | "\(.author.login) \(.state)"] | join(",")')"
bb bash "$VCS" pr-data 4 --fields state,mergedAt,mergeCommit
check "pr-data: merged PR" "MERGED 2026-11-03T12:30:15Z 99aabbccdd11" "$(printf '%s' "$OUT" | jq -r '"\(.state) \(.mergedAt) \(.mergeCommit.oid)"')"
bb bash "$VCS" pr-data 7 --fields bogus; check "pr-data unknown field: 2" 2 "$RC"

# --- diff: the PR's own diff; local fallback, labelled
routes <<RT
GET $R/pullrequests?q=*state=OPEN&sort* prs-open.json
GET $R/pullrequests/7/diff diff-7.txt
RT
bb bash "$VCS" diff --base main --head 12-feature
check "diff: the API diff of the PR with that base" "diff --git a/a.txt b/a.txt" "$(printf '%s\n' "$OUT" | head -n 1)"
check "diff: not labelled as local" 0 "$(printf '%s\n' "$OUT" | grep -c '^# squad:')"
# local fallback: real branches in the fixture clone
git -C "$P" checkout -q -b 12-feature
echo hello > "$P/local.txt"; git -C "$P" add local.txt; git -C "$P" -c user.name=t -c user.email=t@t commit -qm local
git -C "$P" checkout -q main
routes <<RT
GET $R/pullrequests?q=*state=OPEN&sort* prs-empty.json
RT
bb bash "$VCS" diff --base main --head 12-feature
check "diff fallback (no PR): exit 0" 0 "$RC"
check "diff fallback: first line labels it" "# squad: local git diff main...12-feature (Bitbucket API unavailable: no open PR from 12-feature into main)" "$(printf '%s\n' "$OUT" | head -n 1)"
check "diff fallback: carries the local change" 1 "$(printf '%s\n' "$OUT" | grep -c '^+hello')"
grep -q "computed from local git" "$TMPROOT/err" && ok "diff fallback: stderr says so" || bad "diff fallback: stderr says so"
routes <<RT
GET $R/pullrequests?q=*state=OPEN&sort* prs-open.json
GET $R/pullrequests/7/diff error-400.json 500
RT
bb bash "$VCS" diff --base main --head 12-feature
check "diff fallback (API error): labelled local" "# squad: local git diff" "$(printf '%s\n' "$OUT" | head -n 1 | cut -c1-23)"
TOK="" routes </dev/null
TOK="" bb bash "$VCS" diff --base main --head 12-feature
check "diff fallback (no token): still a diff" 0 "$RC"
check "diff fallback (no token): labelled" 1 "$(printf '%s\n' "$OUT" | grep -c '^# squad: local git diff')"
bb bash "$VCS" diff --base main --head nonexistent-branch
check "diff: neither API nor local refs: 20" 20 "$RC"
bb bash "$VCS" diff --base main; check "diff without --head: 2" 2 "$RC"

# stacked: the PR with its own base shows only its diff
routes <<RT
GET $R/pullrequests?q=*state=OPEN&sort* prs-open-stacked.json
GET $R/pullrequests/9/diff diff-7.txt
RT
bb bash "$VCS" diff --base 12-feature --head 13-top
check "diff of a stacked PR uses the PR into its own base" 1 "$(callsx "GET $R/pullrequests/9/diff")"

# --- writes
routes <<RT
GET $R/pullrequests/7 pr-7.json
PUT $R/pullrequests/7 put-ok.json
POST $R/pullrequests/7/comments comment-ok.json
POST $R/pullrequests create-ok.json
RT
printf '## Summary\n- new line\n"quoted" \\ back\n' > "$TMPROOT/body.md"
bb bash "$VCS" description-get 7
check "description-get is verbatim" "## Summary
- old line
- second line" "$OUT"
bb bash "$VCS" description-set 7 --body-file "$TMPROOT/body.md"
check "description-set: exit 0" 0 "$RC"
check "description-set: title kept, description from the file" "[#12] Add the thing|## Summary
- new line
\"quoted\" \\ back" "$(body_of "PUT $R/pullrequests/7" | jq -r '"\(.title)|\(.description)"')"
bb bash "$VCS" pr-create --head 12-feature --base main --title "[#12] New" --body "two
lines"
check "pr-create: PR and URL" "PR=11 URL=https://bitbucket.org/acme/app/pull-requests/11" "$(printf '%s' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
check "pr-create: payload" "[#12] New|12-feature|main|two
lines" "$(body_of "POST $R/pullrequests" | jq -r '"\(.title)|\(.source.branch.name)|\(.destination.branch.name)|\(.description)"')"
: > "$CURL_SHIM_LOG"
bb bash "$VCS" comment 7 --body "hello"
check "comment refused by the Bitbucket default policy: 20" 20 "$RC"
check "comment refused: REASON on stdout" "REASON=policy: comment not allowed on fixture" "$OUT"
check "comment refused: no request made" 0 "$(wc -l < "$CURL_SHIM_LOG" | tr -d ' ')"
setcfg '.chisel.writes = {"tracker": [], "vcs": ["pr-create", "description-set", "comment"]}'
bb bash "$VCS" comment 7 --body "hello"
check "comment allowed when listed" 0 "$RC"
check "comment payload" hello "$(body_of "POST $R/pullrequests/7/comments" | jq -r .content.raw)"
routes <<RT
GET $R/pullrequests/7 pr-7.json
PUT $R/pullrequests/7 error-400.json 400
RT
bb bash "$VCS" description-set 7 --body-file "$TMPROOT/body.md"
check "description-set API error: 20" 20 "$RC"
grep -q "title is required" "$TMPROOT/err" && ok "API error text surfaced" || bad "API error text surfaced"
setcfg '.chisel.writes = {"tracker": [], "vcs": ["pr-create", "stack-init"]}'
bb bash "$VCS" stack-init a b
check "stack-init unsupported: 10 with REASON" "10:1" "$RC:$(printf '%s\n' "$OUT" | grep -c '^REASON=')"
bb bash "$VCS" description-set 7 --body-file "$TMPROOT/body.md"
check "description-set denied by policy: 20" 20 "$RC"

# --- squad-pr-desc.sh: drift applied when allowed, kept in the handoff when denied
cat > "$TMPROOT/block.md" <<'EOB'
## Description drift
- line: - old line
  to: - new line
- add: extra bullet
EOB
HF="$TMPROOT/handoff.md"; : > "$HF"
setcfg '.chisel.writes = {"tracker": [], "vcs": ["pr-create", "description-set"]}'
routes <<RT
GET $R/pullrequests/7 pr-7.json
PUT $R/pullrequests/7 put-ok.json
RT
bb bash "$DESC" apply --block "$TMPROOT/block.md" --pr 7 --issue 12 --handoff "$HF"
check "pr-desc allowed: applied" "applied" "$(key "$OUT" OUTCOME)"
check "pr-desc allowed: one PUT with the edited text" "## Summary
- new line
- second line
- extra bullet" "$(body_of "PUT $R/pullrequests/7" | jq -r .description)"
check "pr-desc allowed: handoff untouched" 0 "$(wc -c < "$HF" | tr -d ' ')"
setcfg '.chisel.writes = {"tracker": [], "vcs": ["pr-create"]}'
routes <<RT
GET $R/pullrequests/7 pr-7.json
PUT $R/pullrequests/7 put-ok.json
RT
bb bash "$DESC" apply --block "$TMPROOT/block.md" --pr 7 --issue 12 --handoff "$HF"
check "pr-desc denied: exit 20, outcome refused" "20:refused" "$RC:$(key "$OUT" OUTCOME)"
check "pr-desc denied: the PR is not touched" 0 "$(wc -l < "$CURL_SHIM_LOG" | tr -d ' ')"
check "pr-desc denied: drift kept in the handoff" 2 "$(grep -c '^- \[ \] PR description of 12' "$HF")"

# --- detached mode refuses writes before any request
out="$(TMPDIR="$TMPROOT" "$MK" detached)" || exit 1
P2="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"; V2="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
jq '.chisel.vcs = "bitbucket"' "$V2/projects/fixture/.squad/chisel-config.json" > "$TMPROOT/c2" && mv "$TMPROOT/c2" "$V2/projects/fixture/.squad/chisel-config.json"
git -C "$P2" remote set-url origin git@bitbucket.org:acme/app.git
routes <<RT
GET $R/pullrequests/7 pr-7.json
POST $R/pullrequests create-ok.json
PUT $R/pullrequests/7 put-ok.json
RT
OUT="$(cd "$P2" && PATH="$REPO_ROOT/scripts/curl-shim:$BIN:$PATH" SECOND_BRAIN_PATH="$V2" SQUAD_BITBUCKET_TOKEN="$TOKEN" bash "$VCS" pr-create --head a --base b --title t --body x 2>&1)"; RC=$?
echo "$OUT" >> "$ALL"
check "detached: pr-create is not gated on tracker mode (as on github)" 0 "$RC"
: > "$CURL_SHIM_LOG"
OUT="$(cd "$P2" && PATH="$REPO_ROOT/scripts/curl-shim:$BIN:$PATH" SECOND_BRAIN_PATH="$V2" SQUAD_BITBUCKET_TOKEN="$TOKEN" bash "$VCS" description-set 7 --body-file "$TMPROOT/body.md" 2>&1)"; RC=$?
check "detached: description-set refused" 20 "$RC"
check "detached: description-set sent no request" 0 "$(grep -cE '^PUT' "$CURL_SHIM_LOG")"
OUT="$(cd "$P2" && PATH="$REPO_ROOT/scripts/curl-shim:$BIN:$PATH" SECOND_BRAIN_PATH="$V2" SQUAD_BITBUCKET_TOKEN="$TOKEN" bash "$VCS" description-get 7 2>&1)"; RC=$?
check "detached: reads still work" 0 "$RC"

# --- hygiene
check "no gh call on the Bitbucket path" 0 "$(wc -l < "$GHLOG" | tr -d ' ')"
check "no REJECTED curl call (every request had a route)" 0 "$(grep -c '^REJECTED' "$CURL_SHIM_LOG")"
grep -qF "$TOKEN" "$ALL" "$CURL_SHIM_ARGV" "$CURL_SHIM_LOG" 2>/dev/null && bad "the token appears in output, log or argv" || ok "the token appears in no output, log or argv"
grep -rqF "$TOKEN" "$V" "$P" "$FX" 2>/dev/null && bad "the token is in a config, vault, project or fixture file" || ok "the token is in no config, vault, project or fixture file"
grep -qE '(^|[^a-z_])gh ' "$REPO_ROOT/claude/hooks/vcs/bitbucket.sh" | grep -v '^#' >/dev/null; \
  [ "$(grep -v '^ *#' "$REPO_ROOT/claude/hooks/vcs/bitbucket.sh" | grep -cE '(^|[^A-Za-z_-])gh ')" = 0 ] && ok "bitbucket.sh has no gh command" || bad "bitbucket.sh has no gh command"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
