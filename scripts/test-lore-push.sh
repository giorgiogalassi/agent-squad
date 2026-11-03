#!/usr/bin/env bash
# Tests `lore push` and the detached SessionEnd push (#427, parent #420), plus
# the local-only vault mode. Plain bash 3.2; fixture vaults with a bare origin
# and a recording gh shim; never touches a real remote or vault.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/test-tmp.sh"
test_tmp_init test-lore-push
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

for _v in $(env | sed -n 's/^\(\(SQUAD\|LORE\)_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
unset SECOND_BRAIN_PATH
export SQUAD_INCIDENTS=off GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
HOOKS="$TMPROOT/hooks"; mkdir -p "$HOOKS" "$TMPROOT/bin"
cp "$REPO_ROOT"/claude/hooks/{lore,lore-checkpoint.sh,lore-orient.sh,path-resolve.sh,squad-common.sh,squad-progress.sh,squad-incidents.sh,vault-check.sh,worktree.sh,squad-session.sh} "$HOOKS/" 2>/dev/null
LORE="$HOOKS/lore"
cat > "$TMPROOT/bin/gh" <<'EOP'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr list") [ -f "$GH_LOG.open" ] && printf '7' ;;
  "pr create") touch "$GH_LOG.open"; echo "https://example.invalid/pull/7" ;;
  *) exit 1 ;;
esac
EOP
chmod +x "$TMPROOT/bin/gh"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$TMPROOT/bin/claude"; chmod +x "$TMPROOT/bin/claude"
export PATH="$TMPROOT/bin:$PATH" GH_LOG="$TMPROOT/gh.log"; : > "$GH_LOG"

# mkvault <name> <config-json|""> <with-origin 1|0>: vault, project checkout mapped to "proj"
mkvault() {
  local v="$TMPROOT/$1" p="$TMPROOT/$1-proj"
  mkdir -p "$p"; git init -q -b main "$p"; echo x > "$p/f"; git -C "$p" add -A; git -C "$p" commit -qm init
  git init -q -b main "$v"; mkdir -p "$v/projects/proj"
  printf '# Decisions -- proj\n' > "$v/projects/proj/decisions.md"
  printf '{"projects":{"%s":"proj"}%s}\n' "$p" "${2:+,$2}" > "$v/lore-config.json"
  git -C "$v" add -A; git -C "$v" commit -qm init
  if [ "${3:-1}" = 1 ]; then
    git init -q --bare -b main "$TMPROOT/$1-origin.git"
    git -C "$v" remote add origin "$TMPROOT/$1-origin.git"; git -C "$v" push -q -u origin main 2>/dev/null
    git -C "$v" remote set-head origin main >/dev/null 2>&1
  fi
}
write() {  # write <vault> <file-content-tag>: a committed change through lore commit
  echo "$2" >> "$1/projects/proj/decisions.md"
  bash "$LORE" commit --vault "$1" --project proj --message "[lore] $2" --paths projects/proj/decisions.md >/dev/null 2>&1
}
remote_has() { git -C "$1" ls-remote "$TMPROOT/$2-origin.git" "refs/heads/$3" 2>/dev/null | wc -l | tr -d ' '; }
BR="lore/proj-$(date +%Y-%m-%d)"

# 1. lore push in PR mode: pushes, one PR, status applied
mkvault a '"vault_main":"pr"'; V="$TMPROOT/a"; write "$V" one
out="$(bash "$LORE" push --vault "$V" 2>/dev/null)"; rc=$?
check "push: exit 0" 0 "$rc"; has "push: applied" "OUTCOME=applied" "$out"
check "push: branch on remote once" 1 "$(remote_has "$V" a "$BR")"
check "push: one pr create" 1 "$(grep -c '^gh pr create' "$GH_LOG")"
st="$(cat "$V/.git/lore-push-status")"
has "status: OUTCOME=applied" "OUTCOME=applied" "$st"; has "status: AT" "AT=" "$st"
check "push: lock released" no "$([ -e "$V/.git/lore.lock" ] && echo yes || echo no)"
out="$(bash "$LORE" push --vault "$V" 2>/dev/null)"; has "push again: unchanged" "OUTCOME=unchanged" "$out"

# 2. rejecting remote: failed status, orientation names it
mkvault b '"vault_main":"pr"'; V="$TMPROOT/b"; P="$TMPROOT/b-proj"
printf '#!/bin/sh\necho rejected >&2\nexit 1\n' > "$TMPROOT/b-origin.git/hooks/pre-receive"; chmod +x "$TMPROOT/b-origin.git/hooks/pre-receive"
write "$V" one
out="$(bash "$LORE" push --vault "$V" 2>/dev/null)"; rc=$?
check "rejected: exit 20" 20 "$rc"; has "rejected: OUTCOME=failed" "OUTCOME=failed" "$out"
st="$(cat "$V/.git/lore-push-status")"
has "rejected: status failed" "OUTCOME=failed" "$st"; has "rejected: REASON" "REASON=" "$st"
o="$(cd "$P" && SECOND_BRAIN_PATH="$V" bash "$HOOKS/lore-orient.sh" </dev/null 2>/dev/null)"
has "orient names the failed push" "vault push failed" "$o"
sleep 1; rm -f "$TMPROOT/b-origin.git/hooks/pre-receive"

# 3. SessionEnd returns fast while a slow push completes afterwards
mkvault c '"vault_main":"pr"'; V="$TMPROOT/c"; P="$TMPROOT/c-proj"
printf '#!/bin/sh\nsleep 6\nexit 0\n' > "$TMPROOT/c-origin.git/hooks/pre-receive"; chmod +x "$TMPROOT/c-origin.git/hooks/pre-receive"
printf -- '---\ntitle: s\n---\n# Status\nLast updated: 2999-01-01 00:00 by x\n\n## Goal\n\n## Last checkpoint\n\n## Context refs\n' > "$V/projects/proj/status.md"
git -C "$V" add -A; git -C "$V" commit -qm status; git -C "$V" push -q origin main 2>/dev/null
write "$V" one
t0="$(date +%s)"
printf '{"cwd":"%s"}' "$P" | SECOND_BRAIN_PATH="$V" bash "$HOOKS/lore-checkpoint.sh" >/dev/null 2>&1
t1="$(date +%s)"
[ $((t1 - t0)) -lt 3 ] && ok "SessionEnd returned in under 3 s ($((t1 - t0)) s)" || bad "SessionEnd took $((t1 - t0)) s"
check "slow push not done at return" 0 "$(remote_has "$V" c "$BR")"
i=0; while [ "$i" -lt 30 ] && [ "$(remote_has "$V" c "$BR")" = 0 ]; do sleep 1; i=$((i+1)); done
check "slow push completed afterwards" 1 "$(remote_has "$V" c "$BR")"
sleep 1

# 4. push killed right after start: SessionStart retries, remote has the branch once
mkvault d '"vault_main":"pr"'; V="$TMPROOT/d"; P="$TMPROOT/d-proj"
write "$V" one
check "ahead branch before retry: not on remote" 0 "$(remote_has "$V" d "$BR")"
( cd "$P" && SECOND_BRAIN_PATH="$V" bash "$HOOKS/lore-orient.sh" </dev/null >/dev/null 2>&1 )
i=0; while [ "$i" -lt 15 ] && [ "$(remote_has "$V" d "$BR")" = 0 ]; do sleep 1; i=$((i+1)); done
check "SessionStart retried: branch on remote once" 1 "$(remote_has "$V" d "$BR")"
sleep 1
( cd "$P" && SECOND_BRAIN_PATH="$V" bash "$HOOKS/lore-orient.sh" </dev/null >/dev/null 2>&1 ); sleep 2
check "caught up: still once" 1 "$(remote_has "$V" d "$BR")"

# 5. vault_main local-only: local commit, unchanged, gh never called
mkvault e '"vault_main":"local-only"'; V="$TMPROOT/e"; : > "$GH_LOG"
git -C "$V" switch -qc side
write "$V" one
check "local-only: committed on the current branch" "[lore] one" "$(git -C "$V" log -1 --format=%s)"
out="$(bash "$LORE" push --vault "$V" 2>/dev/null)"; rc=$?
check "local-only: exit 0" 0 "$rc"; has "local-only: unchanged" "OUTCOME=unchanged" "$out"
check "local-only: no gh call" 0 "$(wc -l < "$GH_LOG" | tr -d ' ')"
check "local-only: nothing on remote" 0 "$(git -C "$V" ls-remote origin 'refs/heads/side' | wc -l | tr -d ' ')"

# 6. detect: no origin behaves as local-only
mkvault f "" 0; V="$TMPROOT/f"; : > "$GH_LOG"
git -C "$V" switch -qc side
write "$V" one
check "no origin: committed on the current branch" "[lore] one" "$(git -C "$V" log -1 --format=%s)"
out="$(bash "$LORE" push --vault "$V" 2>/dev/null)"; has "no origin: unchanged" "OUTCOME=unchanged" "$out"
check "no origin: no gh call" 0 "$(wc -l < "$GH_LOG" | tr -d ' ')"

echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
