#!/usr/bin/env bash
# Tests claude/hooks/lore-orient.sh output shape. Plain bash 3.2; needs jq to validate.
set -u
# Never write the real vault incident store.
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
JQ="$(command -v jq)" || { echo "jq required to validate output"; exit 1; }
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-lore-orient.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

# Hooks dir copy with path-resolve.sh alongside, as installed.
mkdir -p "$TMPROOT/hooks" "$TMPROOT/nojq"
cp "$REPO_ROOT/claude/hooks/lore-orient.sh" "$REPO_ROOT/claude/hooks/path-resolve.sh" "$TMPROOT/hooks/"
# PATH without jq: symlink the tools the hook needs, minus jq.
for t in bash git cat sed awk grep dirname basename tr wc head tail sort date stat ls mkdir cut find; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$TMPROOT/nojq/$t"
done

out="$("$MK" connected)"
F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
FIXROOTS="$F_ROOT"
# Awkward characters to prove escaping round-trips without doubling.
mkdir -p "$F_VAULT/projects/fixture"
printf '# Status\nquote " backslash \\ tab\tend\n' > "$F_VAULT/projects/fixture/status.md"
# Without jq the real path-resolve.sh cannot read the mapping, so the full
# output is only reachable via a stub that supplies it; this exercises the printf branch.
mkdir -p "$TMPROOT/hooks-nojq"
cp "$REPO_ROOT/claude/hooks/lore-orient.sh" "$TMPROOT/hooks-nojq/"
cat > "$TMPROOT/hooks-nojq/path-resolve.sh" <<EOP
#!/usr/bin/env bash
echo "VAULT_PATH=$F_VAULT"; echo "PROJECT_ROOT=$F_PROJECT"; echo "DISPLAY_NAME=fixture"; echo "SQUAD_DIR=$F_VAULT/projects/fixture/.squad"
EOP
chmod +x "$TMPROOT/hooks-nojq/path-resolve.sh"

CHECK='.hookSpecificOutput.hookEventName == "SessionStart"
  and (.hookSpecificOutput.additionalContext | length > 0)
  and (has("additionalContext") | not)
  and (.hookSpecificOutput.additionalContext == .systemMessage)'
MARK='quote " backslash \ tab'$'\t''end'
check_shape() {  # check_shape <label> <json>
  if printf '%s' "$2" | "$JQ" -e "$CHECK" >/dev/null 2>&1; then ok "$1 shape"; else bad "$1 shape: $2"; fi
  if printf '%s' "$2" | "$JQ" -e --arg m "$MARK" '.hookSpecificOutput.additionalContext | contains($m)' >/dev/null 2>&1; then ok "$1 escaping round-trips"; else bad "$1 escaping"; fi
}

j="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null)"
check_shape "jq" "$j"
n="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/nojq" bash "$TMPROOT/hooks-nojq/lore-orient.sh" 2>/dev/null)"
check_shape "no-jq" "$n"

# msg-only path (no vault): systemMessage only, both branches.
for mode in jq nojq; do
  if [ "$mode" = jq ]; then P="$PATH"; else P="$TMPROOT/nojq"; fi
  m="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$TMPROOT/missing" PATH="$P" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null)"
  if printf '%s' "$m" | "$JQ" -e '(keys == ["systemMessage"]) and (.systemMessage | length > 0)' >/dev/null 2>&1; then
    ok "msg-only $mode"; else bad "msg-only $mode: $m"; fi
done

# Incidents line (#244). Repo copies of squad-incidents.sh sit next to the hook.
cp "$REPO_ROOT/claude/hooks/squad-incidents.sh" "$REPO_ROOT/claude/hooks/squad-common.sh" "$TMPROOT/hooks/"
INC="$TMPROOT/hooks/squad-incidents.sh"
run_orient() {  # run_orient <store> [hooks-dir]
  (cd "$F_PROJECT" && SQUAD_INCIDENTS_FILE="$1" SECOND_BRAIN_PATH="$F_VAULT" bash "${2:-$TMPROOT/hooks}/lore-orient.sh" 2>/dev/null)
}
rec() {  # rec <store> <session> <component> <reason>
  SQUAD_INCIDENTS= SQUAD_INCIDENTS_FILE="$1" bash "$INC" record --session "$2" --project fixture --source script --kind failure --component "$3" --exit 1 --reason "$4"
}
ctx() { printf '%s' "$1" | "$JQ" -r '.hookSpecificOutput.additionalContext'; }

S2="$TMPROOT/inc-two.tsv"
rec "$S2" s1 cody "boom one"; rec "$S2" s2 cody "boom one"
rec "$S2" s1 ralph "bang two"; rec "$S2" s2 ralph "bang two"
o="$(run_orient "$S2")"
c="$(printf '%s' "$o" | "$JQ" -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 && ctx "$o")"
[ "$(printf '%s\n' "$c" | grep -c '2 recurring squad incidents')" = 1 ] && ok "incidents: 2 recurring, exactly once" || bad "incidents: 2 recurring: $c"
printf '%s\n' "$c" | grep -qF "2 recurring squad incidents: run $TMPROOT/hooks/squad-incidents.sh summary" && ok "incidents: line text" || bad "incidents: line text"
printf '%s' "$o" | "$JQ" -e "$CHECK" >/dev/null 2>&1 && ok "incidents: JSON stays valid" || bad "incidents: JSON shape"

S0="$TMPROOT/inc-none.tsv"
rec "$S0" s1 cody "once only"; rec "$S0" s1 ralph "same session"; rec "$S0" s2 ralph "same session"; rec "$S0" s3 ralph "same session"
SQUAD_INCIDENTS_FILE="$S0" bash "$INC" resolve --signature "ralph|failure|1|same session" --ref x >/dev/null
o="$(run_orient "$S0")"
c="$(ctx "$o")"
printf '%s' "$c" | grep -q 'recurring squad incidents' && bad "incidents: non-recurring/resolved leaks a line" || ok "incidents: none recurring, no line"

base="$(run_orient "$TMPROOT/absent.tsv")"
printf '%s' "$base" | "$JQ" -e "$CHECK" >/dev/null 2>&1 && ok "incidents: missing store valid JSON" || bad "incidents: missing store: $base"
printf '%s' "$base" | grep -q 'recurring squad incidents' && bad "incidents: missing store has line" || ok "incidents: missing store, no line"
# Missing script: hooks dir without squad-incidents.sh, recurring store present.
o="$(run_orient "$S2" "$TMPROOT/hooks-nojq")"
printf '%s' "$o" | grep -q 'recurring squad incidents' && bad "incidents: missing script has line" || ok "incidents: missing script, no line"

# Dirty open worktrees (#296): listed with branch and file count; clean ones are not.
git -C "$F_PROJECT" worktree add -q -b dirty-wt "$TMPROOT/dirty-wt" 2>/dev/null
git -C "$F_PROJECT" worktree add -q -b clean-wt "$TMPROOT/clean-wt" 2>/dev/null
echo a > "$TMPROOT/dirty-wt/a.txt"; echo b > "$TMPROOT/dirty-wt/b.txt"
c="$(ctx "$(run_orient "$TMPROOT/absent.tsv")")"
printf '%s\n' "$c" | grep -q 'uncommitted work on dirty-wt: 2 files' && ok "worktrees: dirty one listed with count" || bad "worktrees: dirty one listed: $c"
printf '%s\n' "$c" | grep -q 'clean-wt' && bad "worktrees: clean one listed" || ok "worktrees: clean one omitted"

# SessionStart source (#289): resume skips, everything else orients.
run_src() {  # run_src <stdin-json> [path]
  (cd "$F_PROJECT" && printf '%s' "$1" | SQUAD_INCIDENTS_FILE="$TMPROOT/absent.tsv" SECOND_BRAIN_PATH="$F_VAULT" PATH="${2:-$PATH}" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null)
}
o="$(run_src '{"source":"resume"}')"
[ "$o" = "{}" ] && ok "source: resume emits {}" || bad "source: resume: $o"
o="$(run_src '{"source":"resume"}' "$TMPROOT/nojq")"
[ "$o" = "{}" ] && ok "source: resume emits {} (no jq)" || bad "source: resume no-jq: $o"
for src in startup clear compact; do
  o="$(run_src "{\"source\":\"$src\"}")"
  printf '%s' "$o" | "$JQ" -e "$CHECK" >/dev/null 2>&1 && ok "source: $src orients" || bad "source: $src: $o"
done
o="$(run_src '')"
printf '%s' "$o" | "$JQ" -e "$CHECK" >/dev/null 2>&1 && ok "source: empty stdin orients" || bad "source: empty stdin: $o"
o="$(run_src 'not json')"
printf '%s' "$o" | "$JQ" -e "$CHECK" >/dev/null 2>&1 && ok "source: garbage stdin orients" || bad "source: garbage stdin: $o"

# Open PRs and status history (#328). gh is a stub on PATH; fixtures only.
mkdir -p "$TMPROOT/ghok" "$TMPROOT/ghdead" "$TMPROOT/ghslow" "$TMPROOT/ghnone"
cat > "$TMPROOT/ghok/gh" <<'EOS'
#!/bin/sh
[ "$1" = auth ] && exit 0
echo "#7 Add thing (feat -> main)"
echo "#8 Fix other (fix -> main)"
EOS
printf '#!/bin/sh\n[ "$1" = auth ] && exit 1\nexit 1\n' > "$TMPROOT/ghdead/gh"
printf '#!/bin/sh\nsleep 30\n' > "$TMPROOT/ghslow/gh"
chmod +x "$TMPROOT"/ghok/gh "$TMPROOT"/ghdead/gh "$TMPROOT"/ghslow/gh
# PATH with the basics but no gh, for the "gh not installed" case.
for t in bash git cat sed awk grep dirname basename tr wc head tail sort date stat ls mkdir cut find jq mktemp rm sleep kill pkill; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$TMPROOT/ghnone/$t"
done
run_pr() {  # run_pr <path-prefix> [vault]
  (cd "$F_PROJECT" && SQUAD_ORIENT_PR_TIMEOUT=1 SQUAD_INCIDENTS_FILE="$TMPROOT/absent.tsv" SECOND_BRAIN_PATH="${2:-$F_VAULT}" PATH="$1:$PATH" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null </dev/null)
}
c="$(ctx "$(run_pr "$TMPROOT/ghok")")"
printf '%s\n' "$c" | grep -q '^Open PRs:' && printf '%s\n' "$c" | grep -q '#7 Add thing (feat -> main)' && ok "open PRs: connected lists them" || bad "open PRs listed: $c"
c="$(ctx "$(run_pr "$TMPROOT/ghdead")")"
printf '%s\n' "$c" | grep -q 'Open PRs: unavailable (gh not authenticated)' && ok "open PRs: unauthenticated one-liner" || bad "open PRs unauth: $c"
t0=$SECONDS
c="$(ctx "$(run_pr "$TMPROOT/ghslow")")"
printf '%s\n' "$c" | grep -q 'Open PRs: unavailable (gh timed out' && [ $((SECONDS - t0)) -lt 10 ] && ok "open PRs: timeout is bounded" || bad "open PRs timeout: $c"
printf '%s\n' "$c" | grep -q 'Lore orientation' && ok "open PRs: orientation survives a hang" || bad "orientation lost on hang"
c="$(ctx "$(cd "$F_PROJECT" && SQUAD_INCIDENTS_FILE="$TMPROOT/absent.tsv" SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/ghnone" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null </dev/null)")"
printf '%s\n' "$c" | grep -q 'Open PRs: unavailable (gh not found)' && ok "open PRs: gh missing one-liner" || bad "open PRs no gh: $c"
# Detached: same vault with chisel.mode flipped, gh would succeed, nothing printed.
sed -i.bak 's/"mode": "connected"/"mode": "detached"/' "$F_VAULT/projects/fixture/.squad/chisel-config.json"
c="$(ctx "$(run_pr "$TMPROOT/ghok")")"
printf '%s\n' "$c" | grep -q 'Open PRs' && bad "detached: PR line printed" || ok "detached: nothing about PRs"
mv "$F_VAULT/projects/fixture/.squad/chisel-config.json.bak" "$F_VAULT/projects/fixture/.squad/chisel-config.json"
c="$(ctx "$(run_pr "$TMPROOT/ghok")")"
printf '%s\n' "$c" | grep -q 'Previous versions: git -C '"$F_VAULT"' log --oneline -- projects/fixture/status.md' && ok "previous versions line names the git command" || bad "previous versions: $c"
# A squad-hook child session (SQUAD_LORE_HOOK=1) gets no orientation; a normal one does.
q="$(cd "$F_PROJECT" && SQUAD_LORE_HOOK=1 SECOND_BRAIN_PATH="$F_VAULT" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null </dev/null)"
if [ -z "$q" ]; then ok "SQUAD_LORE_HOOK=1: silent"; else bad "SQUAD_LORE_HOOK=1: not silent"; fi
q="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" bash "$TMPROOT/hooks/lore-orient.sh" 2>/dev/null </dev/null)"
if [ -n "$q" ]; then ok "unset SQUAD_LORE_HOOK: still orients"; else bad "normal session lost orientation"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
