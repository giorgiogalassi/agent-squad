#!/usr/bin/env bash
# Tests vault writes on a branch + PR when the vault's main takes PRs only (#350):
# claude/hooks/squad-common.sh (squad_vault_*), vault-pr.sh, lore-decide.sh.
# Plain bash 3.2; fixture vaults with a bare origin and a fake gh; never touches
# ~/second-brain.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-vault-pr.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

export SQUAD_INCIDENTS=off GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
mkdir -p "$TMPROOT/hooks" "$TMPROOT/bin"
cp "$REPO_ROOT"/claude/hooks/{lore-decide.sh,vault-pr.sh,decisions-lint.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
cat > "$TMPROOT/hooks/path-resolve.sh" <<'EOP'
#!/usr/bin/env bash
echo "VAULT_PATH=$SECOND_BRAIN_PATH"; echo "PROJECT_ROOT=$PWD"
echo "DISPLAY_NAME=proj"; echo "SQUAD_DIR=$SECOND_BRAIN_PATH/projects/proj/.squad"
echo "TRACKER_MODE=${FAKE_TRACKER_MODE:-connected}"
EOP
cat > "$TMPROOT/bin/gh" <<'EOP'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr list") case "$*" in *"--state merged"*) printf '%s' "${GH_MERGED_OID:-}" ;; *) printf '%s' "${GH_OPEN:-}" ;; esac ;;
  "pr create") [ -n "${GH_CREATE_FAIL:-}" ] && exit 1; echo "https://example.invalid/pull/7" ;;
  *) exit 1 ;;
esac
EOP
chmod +x "$TMPROOT/bin/gh"
export PATH="$TMPROOT/bin:$PATH" GH_LOG="$TMPROOT/gh.log"

mkvault() {  # mkvault <name> [config-json]: vault clone with a bare origin
  git init -q --bare -b main "$TMPROOT/$1-origin.git"
  git init -q -b main "$TMPROOT/$1"
  mkdir -p "$TMPROOT/$1/projects/proj"
  printf '# Decisions -- proj\n' > "$TMPROOT/$1/projects/proj/decisions.md"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$TMPROOT/$1/lore-config.json"
  git -C "$TMPROOT/$1" add -A && git -C "$TMPROOT/$1" commit -qm init
  git -C "$TMPROOT/$1" remote add origin "$TMPROOT/$1-origin.git"
  git -C "$TMPROOT/$1" push -q -u origin main 2>/dev/null
}
decide() {  # decide <vault> <text>
  (cd "$TMPROOT" && SECOND_BRAIN_PATH="$1" bash "$TMPROOT/hooks/lore-decide.sh" "$2" >/dev/null 2>&1)
}
level() {  # clean tree and local main == origin/main
  [ -z "$(git -C "$1" status --porcelain)" ] && [ "$(git -C "$1" rev-parse main)" = "$(git -C "$1" rev-parse origin/main)" ] && echo level || echo off
}
branches() { git -C "$1" for-each-ref --format='%(refname:short)' 'refs/heads/lore/*' | tr '\n' ' '; }

# 1. Setting on: three decisions, one branch, main untouched.
mkvault on '{"vault_main": "pr"}'; V="$TMPROOT/on"
decide "$V" "One: first"; decide "$V" "Two: second"; decide "$V" "Three: third"
check "pr: main clean and level with origin" level "$(level "$V")"
B="lore/proj-$(date +%Y-%m-%d)"
check "pr: one lore branch for three writes" "$B " "$(branches "$V")"
check "pr: three commits on the branch" 3 "$(git -C "$V" rev-list --count origin/main.."$B")"
n="$(git -C "$V" show "$B:projects/proj/decisions.md" | grep -c '^## \[')"
check "pr: all three entries on the branch" 3 "$n"
check "pr: entries not on main" 0 "$(grep -c '^## \[' "$V/projects/proj/decisions.md")"

# 2. Session end: pushed once, one PR; a second end updates, never re-creates.
: > "$GH_LOG"
(cd "$TMPROOT" && SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" finish >/dev/null 2>&1); rc=$?
check "finish: exit 0" 0 "$rc"
git -C "$V" ls-remote --exit-code origin "refs/heads/$B" >/dev/null 2>&1; check "finish: branch pushed" 0 $?
check "finish: one pr create" 1 "$(grep -c '^gh pr create' "$GH_LOG")"
check "finish: base is main" 1 "$(grep -c -- '--base main' "$GH_LOG")"
: > "$GH_LOG"; decide "$V" "Four: fourth"
(cd "$TMPROOT" && GH_OPEN=7 SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" finish >/dev/null 2>&1)
check "finish again: open PR is updated, not re-created" 0 "$(grep -c '^gh pr create' "$GH_LOG")"
check "finish again: still level" level "$(level "$V")"
: > "$GH_LOG"
(cd "$TMPROOT" && GH_OPEN=7 FAKE_TRACKER_MODE=detached SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" finish >/dev/null 2>&1)
check "finish detached: already pushed, no pr create" 0 "$(grep -c '^gh pr create' "$GH_LOG")"

# 3. Setting off: today's behaviour, commit on main, no branch.
mkvault off; V="$TMPROOT/off"
decide "$V" "One: first"
check "off: commit on main" 2 "$(git -C "$V" rev-list --count main)"
check "off: no lore branch" "" "$(branches "$V")"
mkvault direct '{"vault_main": "direct"}'; V="$TMPROOT/direct"
printf '#!/bin/sh\nexit 1\n' > "$V/.git/hooks/pre-push"; chmod +x "$V/.git/hooks/pre-push"
decide "$V" "One: first"
check "direct: overrides a rejecting hook" "" "$(branches "$V")"

# 4. Detection from a pre-push hook that rejects refs/heads/main.
mkvault hook; V="$TMPROOT/hook"
cat > "$V/.git/hooks/pre-push" <<'EOP'
#!/bin/sh
while read -r l s r rs; do [ "$r" = refs/heads/main ] && { echo "main takes PRs only" >&2; exit 1; }; done
exit 0
EOP
chmod +x "$V/.git/hooks/pre-push"
decide "$V" "One: first"
check "hook: detected, main level" level "$(level "$V")"
check "hook: branch used" "$B " "$(branches "$V")"
mkvault okhook; V="$TMPROOT/okhook"
printf '#!/bin/sh\nexit 0\n' > "$V/.git/hooks/pre-push"; chmod +x "$V/.git/hooks/pre-push"
decide "$V" "One: first"
check "hook accepting main: direct" "" "$(branches "$V")"

# 5. vault-pr.sh commit (global preference path), PR mode.
mkvault glob '{"vault_main": "pr"}'; V="$TMPROOT/glob"
mkdir -p "$V/preferences"; printf -- '- [2026-10-28] [global] x\n' > "$V/preferences/development.md"
(cd "$TMPROOT" && SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" commit "[lore] pref" preferences/development.md >/dev/null 2>&1)
check "commit: main level" level "$(level "$V")"
check "commit: file on the branch" 1 "$(git -C "$V" show "$B:preferences/development.md" 2>/dev/null | grep -c global)"

finish() {  # finish <vault> [env assignments...]: run vault-pr.sh finish, stdout to $TMPROOT/fin.out
  local v="$1"; shift
  (cd "$TMPROOT" && env "$@" SECOND_BRAIN_PATH="$v" bash "$TMPROOT/hooks/vault-pr.sh" finish > "$TMPROOT/fin.out" 2>/dev/null)
}
land() {  # land <vault> <origin-name> <branch>: squash-merge simulation, files copied onto origin main
  rm -rf "$TMPROOT/lander"; git clone -q "$TMPROOT/$2-origin.git" "$TMPROOT/lander" 2>/dev/null
  git -C "$1" archive "$3" projects | tar -x -C "$TMPROOT/lander"
  git -C "$TMPROOT/lander" add -A && git -C "$TMPROOT/lander" commit -qm squash && git -C "$TMPROOT/lander" push -q origin main 2>/dev/null
}

# 6. Squash-merged branch: tree equals main; cleaned, not re-pushed, no PR created.
mkvault sq '{"vault_main": "pr"}'; V="$TMPROOT/sq"
decide "$V" "One: first"; B="lore/proj-$(date +%Y-%m-%d)"
land "$V" sq "$B"
: > "$GH_LOG"; finish "$V"; rc=$?
check "squash: finish exit 0" 0 "$rc"
check "squash: branch removed" "" "$(branches "$V")"
check "squash: worktree removed" 0 "$(ls -d "$V"/.claude/worktrees/lore-* 2>/dev/null | wc -l | tr -d ' ')"
git -C "$V" ls-remote --exit-code origin "refs/heads/$B" >/dev/null 2>&1; check "squash: not re-pushed" 2 $?
check "squash: no pr create" 0 "$(grep -c '^gh pr create' "$GH_LOG")"
check "squash: nothing to do reports CHANGED=no" "CHANGED=no" "$(grep '^CHANGED=' "$TMPROOT/fin.out")"

# 7. Merged PR reported by gh (main's tree differs): dropped; dirty worktree refused.
mkvault mg '{"vault_main": "pr"}'; V="$TMPROOT/mg"
decide "$V" "One: first"
tip="$(git -C "$V" rev-parse "$B")"
: > "$GH_LOG"; printf 'x\n' >> "$V/.claude/worktrees/lore-proj-$(date +%Y-%m-%d)/projects/proj/decisions.md"
finish "$V" GH_MERGED_OID="$tip"; rc=$?
check "merged dirty: exit 20" 20 "$rc"
check "merged dirty: branch kept" "$B " "$(branches "$V")"
git -C "$V/.claude/worktrees/lore-proj-$(date +%Y-%m-%d)" checkout -q -- projects/proj/decisions.md
finish "$V" GH_MERGED_OID="$tip"; rc=$?
check "merged clean: exit 0" 0 "$rc"
check "merged clean: branch removed" "" "$(branches "$V")"
check "merged clean: no pr create" 0 "$(grep -c '^gh pr create' "$GH_LOG")"
: > "$GH_LOG"; FAKE_TRACKER_MODE=detached; export FAKE_TRACKER_MODE; finish "$V"; unset FAKE_TRACKER_MODE
check "detached finish: merged branch, no pr create" 0 "$(grep -c '^gh pr create' "$GH_LOG")"

# 8. Same-day write after a merge starts a fresh branch.
mkvault fr '{"vault_main": "pr"}'; V="$TMPROOT/fr"
decide "$V" "One: first"; finish "$V"
check "fresh: first finish pushed" "CHANGED=yes" "$(grep '^CHANGED=' "$TMPROOT/fin.out")"
land "$V" fr "$B"; git -C "$TMPROOT/fr-origin.git" branch -D "$B" >/dev/null 2>&1
decide "$V" "Two: second"
check "fresh: second branch" "$B-2" "$(git -C "$V" for-each-ref --format='%(refname:short)' 'refs/heads/lore/*-2')"
check "fresh: merged branch untouched, not reused" 1 "$(git -C "$V" show "$B-2:projects/proj/decisions.md" | grep -c '^## .*Two')"
check "fresh: second branch has one commit" 1 "$(git -C "$V" rev-list --count origin/main.."$B-2")"
check "fresh: main tree clean" "" "$(git -C "$V" status --porcelain)"
: > "$GH_LOG"; finish "$V"
check "fresh: finish drops merged, pushes new" "CHANGED=yes" "$(grep '^CHANGED=' "$TMPROOT/fin.out")"
check "fresh: one pr create" 1 "$(grep -c '^gh pr create' "$GH_LOG")"
finish "$V" GH_OPEN=9
check "finish with nothing to push: CHANGED=no" "CHANGED=no" "$(grep '^CHANGED=' "$TMPROOT/fin.out")"

# 9. Detection runs the pre-push hook once; an explicit setting never runs it.
mkvault cnt; V="$TMPROOT/cnt"; : > "$TMPROOT/hook.count"
cat > "$V/.git/hooks/pre-push" <<EOP
#!/bin/sh
echo run >> "$TMPROOT/hook.count"
exit 1
EOP
chmod +x "$V/.git/hooks/pre-push"
(cd "$TMPROOT" && SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/lore-decide.sh" "One: first" >/dev/null 2>"$TMPROOT/det.err")
decide "$V" "Two: second"; decide "$V" "Three: third"
check "detect: hook ran once across three commits" 1 "$(wc -l < "$TMPROOT/hook.count" | tr -d ' ')"
check "detect: mode is named and setting recommended" 1 "$(grep -c 'vault_main' "$TMPROOT/det.err")"
check "detect: three commits on branch" 3 "$(git -C "$V" rev-list --count origin/main.."$B")"
mkvault exp '{"vault_main": "pr"}'; V="$TMPROOT/exp"; : > "$TMPROOT/hook.count"
cp "$TMPROOT/cnt/.git/hooks/pre-push" "$V/.git/hooks/pre-push"
decide "$V" "One: first"; decide "$V" "Two: second"
check "explicit: hook never ran" 0 "$(wc -l < "$TMPROOT/hook.count" | tr -d ' ')"

# 10. Local main ahead of origin: its commits move onto the branch, main is levelled.
mkvault ahead '{"vault_main": "pr"}'; V="$TMPROOT/ahead"
echo stray > "$V/stray.md"; git -C "$V" add stray.md; git -C "$V" commit -qm "stranded"
decide "$V" "One: first"
B="lore/proj-$(date +%Y-%m-%d)"
check "ahead: main level with origin" level "$(level "$V")"
check "ahead: stranded commit on the branch" 1 "$(git -C "$V" show "$B:stray.md" 2>/dev/null | grep -c stray)"
check "ahead: two commits on the branch" 2 "$(git -C "$V" rev-list --count origin/main.."$B")"
mkvault aheadd '{"vault_main": "pr"}'; V="$TMPROOT/aheadd"
echo stray > "$V/stray.md"; git -C "$V" add stray.md; git -C "$V" commit -qm "stranded"
echo mine > "$V/stray.md"
ERR="$(cd "$TMPROOT" && SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/lore-decide.sh" "One: first" 2>&1 >/dev/null)"
check "ahead dirty: stranded commit on the branch" 1 "$(git -C "$V" show "$B:stray.md" 2>/dev/null | grep -c stray)"
check "ahead dirty: user edit kept" mine "$(cat "$V/stray.md" 2>/dev/null)"
check "ahead dirty: main still ahead" 1 "$(git -C "$V" rev-list --count origin/main..main)"
check "ahead dirty: warned" 1 "$(printf %s "$ERR" | grep -c "could not be levelled")"
# A refused reset is retried on the next call, once the tree is clean.
git -C "$V" checkout -q -- stray.md
decide "$V" "Two: second"
check "ahead retry: main level" level "$(level "$V")"

# Existing session branch, worktree gone, main ahead.
mkvault aheadw '{"vault_main": "pr"}'; V="$TMPROOT/aheadw"
decide "$V" "One: first"
git -C "$V" worktree remove --force "$V/.claude/worktrees/lore-proj-$(date +%Y-%m-%d)"
echo stray > "$V/stray.md"; git -C "$V" add stray.md; git -C "$V" commit -qm "stranded"
decide "$V" "Two: second"
check "ahead no-worktree: stranded commit on the branch" 1 "$(git -C "$V" show "$B:stray.md" 2>/dev/null | grep -c stray)"
check "ahead no-worktree: main level" level "$(level "$V")"

# Existing worktree, main gains a commit later.
mkvault aheadl '{"vault_main": "pr"}'; V="$TMPROOT/aheadl"
decide "$V" "One: first"
echo late > "$V/late.md"; git -C "$V" add late.md; git -C "$V" commit -qm "late"
decide "$V" "Two: second"
check "ahead later: late commit on the branch" 1 "$(git -C "$V" show "$B:late.md" 2>/dev/null | grep -c late)"
check "ahead later: main level" level "$(level "$V")"

# Merge conflict: main left as is.
mkvault aheadc '{"vault_main": "pr"}'; V="$TMPROOT/aheadc"
echo base > "$V/c.md"; git -C "$V" add c.md; git -C "$V" commit -qm c; git -C "$V" push -q origin main
decide "$V" "One: first"
W="$V/.claude/worktrees/lore-proj-$(date +%Y-%m-%d)"
echo branchside > "$W/c.md"; git -C "$W" commit -qam "branch c"
echo mainside > "$V/c.md"; git -C "$V" commit -qam "main c"
decide "$V" "Two: second"
check "ahead conflict: main stays ahead" 1 "$(git -C "$V" rev-list --count origin/main..main)"
check "ahead conflict: worktree not mid-merge" "" "$(git -C "$W" status --porcelain | grep -v '^??')"

# Diverged main keeps the old behaviour: nothing moved, nothing reset.
mkvault div '{"vault_main": "pr"}'; V="$TMPROOT/div"
echo o > "$V/o.md"; git -C "$V" add o.md; git -C "$V" commit -qm o; git -C "$V" push -q origin main
git -C "$V" reset -q --hard HEAD~1
echo l > "$V/l.md"; git -C "$V" add l.md; git -C "$V" commit -qm l
L="$(git -C "$V" rev-parse main)"
decide "$V" "One: first"
check "diverged: main untouched" "$L" "$(git -C "$V" rev-parse main)"
check "diverged: branch lacks local commit" 0 "$(git -C "$V" show "$B:l.md" 2>/dev/null | grep -c l)"

# 11. Detached project, vault in PR mode: the session branch is pushed and its PR opened (#364).
mkvault det '{"vault_main": "pr"}'; V="$TMPROOT/det"; B="lore/proj-$(date +%Y-%m-%d)"
decide "$V" "One: first"; : > "$GH_LOG"
finish "$V" FAKE_TRACKER_MODE=detached; rc=$?
check "detached pr mode: exit 0" 0 "$rc"
check "detached pr mode: OUTCOME=applied" "OUTCOME=applied" "$(grep '^OUTCOME=' "$TMPROOT/fin.out")"
git -C "$V" ls-remote --exit-code origin "refs/heads/$B" >/dev/null 2>&1; check "detached pr mode: branch pushed" 0 $?
check "detached pr mode: one pr create" 1 "$(grep -c '^gh pr create' "$GH_LOG")"
# Vault not in PR mode: nothing changes, no push, no gh call.
mkvault dir '{"vault_main": "direct"}'; V="$TMPROOT/dir"
git -C "$V" branch lore/stray; : > "$GH_LOG"
finish "$V" FAKE_TRACKER_MODE=detached
check "direct mode: OUTCOME=unchanged" "OUTCOME=unchanged" "$(grep '^OUTCOME=' "$TMPROOT/fin.out")"
check "direct mode: no gh call" 0 "$(wc -l < "$GH_LOG" | tr -d ' ')"

# 12. gh missing: the branch is still pushed, one stderr notice, not a failure (#364).
mkdir -p "$TMPROOT/nogh"; ln -sf "$(command -v git)" "$TMPROOT/nogh/git"
mkvault nog '{"vault_main": "pr"}'; V="$TMPROOT/nog"; B="lore/proj-$(date +%Y-%m-%d)"
decide "$V" "One: first"; : > "$GH_LOG"
(cd "$TMPROOT" && env PATH="$TMPROOT/nogh:/usr/bin:/bin" FAKE_TRACKER_MODE=detached SECOND_BRAIN_PATH="$V" \
  "$(command -v bash)" "$TMPROOT/hooks/vault-pr.sh" finish > "$TMPROOT/fin.out" 2> "$TMPROOT/fin.err"); rc=$?
check "no gh: exit 0" 0 "$rc"
check "no gh: OUTCOME=applied" "OUTCOME=applied" "$(grep '^OUTCOME=' "$TMPROOT/fin.out")"
git -C "$V" ls-remote --exit-code origin "refs/heads/$B" >/dev/null 2>&1; check "no gh: branch pushed" 0 $?
check "no gh: one stderr notice" 1 "$(grep -c 'gh not found' "$TMPROOT/fin.err")"
check "no gh: no gh call" 0 "$(wc -l < "$GH_LOG" | tr -d ' ')"
# gh present but pr create fails: still a failure.
mkvault ghf '{"vault_main": "pr"}'; V="$TMPROOT/ghf"
decide "$V" "One: first"
finish "$V" FAKE_TRACKER_MODE=detached GH_CREATE_FAIL=1; rc=$?
check "gh present, create fails: exit 20" 20 "$rc"
# Push failure (origin gone) is still a failure.
mkvault pf '{"vault_main": "pr"}'; V="$TMPROOT/pf"
decide "$V" "One: first"; rm -rf "$TMPROOT/pf-origin.git"
finish "$V" FAKE_TRACKER_MODE=detached; rc=$?
check "push failure: exit 20" 20 "$rc"

# 13. Local-only project (#351): finish never pushes, stray lore/* branch included.
mkvault loc '{"vault_main": "pr"}'; V="$TMPROOT/loc"; B="lore/proj-$(date +%Y-%m-%d)"
printf 'projects/proj/status.md\n' > "$V/.gitignore"; git -C "$V" add .gitignore && git -C "$V" commit -qm ignore && git -C "$V" push -q origin main 2>/dev/null
decide "$V" "One: first"; : > "$GH_LOG"
finish "$V"; rc=$?
check "local-only: exit 0" 0 "$rc"
check "local-only: CHANGED=no" "CHANGED=no" "$(grep '^CHANGED=' "$TMPROOT/fin.out")"
check "local-only: no lore branch" "" "$(branches "$V")"
mkdir -p "$V/.claude/worktrees"
git -C "$V" worktree add -q -b "$B" "$V/.claude/worktrees/lore-proj-$(date +%Y-%m-%d)" 2>/dev/null
echo x > "$V/.claude/worktrees/lore-proj-$(date +%Y-%m-%d)/projects/proj/x.md"
git -C "$V/.claude/worktrees/lore-proj-$(date +%Y-%m-%d)" add -A && git -C "$V/.claude/worktrees/lore-proj-$(date +%Y-%m-%d)" commit -qm stray
(cd "$TMPROOT" && SECOND_BRAIN_PATH="$V" bash "$TMPROOT/hooks/vault-pr.sh" finish > "$TMPROOT/fin.out" 2>/dev/null); rc=$?
check "local-only stray: exit 0" 0 "$rc"
check "local-only stray: CHANGED=no" "CHANGED=no" "$(grep '^CHANGED=' "$TMPROOT/fin.out")"
git -C "$V" ls-remote --exit-code origin "refs/heads/$B" >/dev/null 2>&1; check "local-only stray: not pushed" 2 $?
check "local-only stray: no gh call" 0 "$(wc -l < "$GH_LOG" | tr -d ' ')"

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]
