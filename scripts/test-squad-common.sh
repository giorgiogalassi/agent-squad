#!/usr/bin/env bash
# Tests claude/hooks/squad-common.sh. Plain bash 3.2; no bats, no jq.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$REPO_ROOT/scripts/fixtures/make-fixture.sh"
COMMON="$REPO_ROOT/claude/hooks/squad-common.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-squad-common.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXROOTS=""
trap 'rm -rf "$TMPROOT" $FIXROOTS' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

# Hooks dir copy: library and path-resolve.sh side by side, as installed.
mkdir -p "$TMPROOT/hooks" "$TMPROOT/realbin" "$TMPROOT/shimbin"
cp "$REPO_ROOT"/claude/hooks/path-resolve.sh "$COMMON" "$TMPROOT/hooks/"
# Recording gh stub: one argv element per line, so exact argv is checkable.
cat > "$TMPROOT/realbin/gh" <<'EOP'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done >> "$GH_ARGV_LOG"
[ -n "${GH_STUB_STDOUT:-}" ] && printf '%s\n' "$GH_STUB_STDOUT"
exit "${GH_STUB_RC:-0}"
EOP
chmod +x "$TMPROOT/realbin/gh"
export GH_ARGV_LOG="$TMPROOT/argv.log"
export GH_SHIM_LOG="$TMPROOT/shim.log"; : > "$GH_SHIM_LOG"
ln -s "$REPO_ROOT/scripts/gh-shim/gh" "$TMPROOT/shimbin/gh"

fixture() {  # fixture <mode>; sets F_PROJECT, F_VAULT
  local out; out="$("$MK" "$1")" || return 1
  F_ROOT="$(printf '%s\n' "$out" | sed -n 's/^FIXTURE_ROOT=//p')"
  F_PROJECT="$(printf '%s\n' "$out" | sed -n 's/^PROJECT=//p')"
  F_VAULT="$(printf '%s\n' "$out" | sed -n 's/^VAULT=//p')"
  FIXROOTS="$FIXROOTS $F_ROOT"
}
# --- squad_resolve
fixture connected
out="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" bash -c '. "$1/squad-common.sh"; squad_resolve; echo "$TRACKER_MODE $DISPLAY_NAME"' _ "$TMPROOT/hooks")"
[ "$out" = "connected fixture" ] && ok "squad_resolve exports mode and name" || bad "squad_resolve ($out)"

# --- squad_gh_write detached: exit 20, shim log empty
fixture detached
: > "$GH_SHIM_LOG"
out="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/shimbin:$PATH" \
  bash -c '. "$1/squad-common.sh"; squad_resolve; squad_gh_write issue edit 1 --add-label x; echo "RC=$?"' _ "$TMPROOT/hooks" 2>/dev/null)"
[ "$out" = "RC=20" ] && ok "gh_write detached returns 20" || bad "gh_write detached ($out)"
[ ! -s "$GH_SHIM_LOG" ] && ok "gh_write detached made zero gh calls" || bad "shim log not empty"

# --- squad_gh_write connected: exact argv
fixture connected
: > "$GH_ARGV_LOG"
out="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/realbin:$PATH" \
  bash -c '. "$1/squad-common.sh"; squad_resolve; squad_gh_write issue edit 7 --add-label "a b"; echo "RC=$?"' _ "$TMPROOT/hooks" 2>/dev/null)"
[ "$out" = "RC=0" ] && ok "gh_write connected returns 0" || bad "gh_write connected ($out)"
exp="$(printf 'issue\nedit\n7\n--add-label\na b\n')"
[ "$(cat "$GH_ARGV_LOG")" = "$exp" ] && ok "gh_write connected passes exact argv" || bad "argv mismatch"

# gh failure is mapped to 20, not passed through
out="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/realbin:$PATH" GH_STUB_RC=4 \
  bash -c '. "$1/squad-common.sh"; squad_resolve; squad_gh_write issue edit 7; echo "RC=$?"' _ "$TMPROOT/hooks" 2>/dev/null)"
[ "$out" = "RC=20" ] && ok "gh failure (4) mapped to 20" || bad "gh failure mapping ($out)"

# gh stdout must not leak onto the function's stdout (contract lines only)
out="$(cd "$F_PROJECT" && SECOND_BRAIN_PATH="$F_VAULT" PATH="$TMPROOT/realbin:$PATH" GH_STUB_STDOUT="https://github.com/o/r/pull/1" \
  bash -c '. "$1/squad-common.sh"; squad_resolve; squad_gh_write pr create' _ "$TMPROOT/hooks" 2>/dev/null)"
[ -z "$out" ] && ok "gh_write keeps gh stdout off stdout" || bad "gh stdout leaked ($out)"

# --- squad_record_local
H="$TMPROOT/deep/dir/handoff.txt"
src='. "$1/squad-common.sh"; squad_record_local "$2" "$3"; echo "RC=$?"'
r1="$(bash -c "$src" _ "$TMPROOT/hooks" "$H" "- [x] step one")"
r2="$(bash -c "$src" _ "$TMPROOT/hooks" "$H" "- [x] step one")"
[ "$r1" = "RC=0" ] && ok "record_local appends (changed)" || bad "record_local first ($r1)"
[ "$r2" = "RC=1" ] && ok "record_local repeat reports unchanged" || bad "record_local repeat ($r2)"
[ "$(grep -c 'step one' "$H")" = 1 ] && ok "record_local no duplicate" || bad "duplicate line"

# --- squad_emit
src='. "$1/squad-common.sh"; shift; squad_emit "$@"; echo "RC=$?"'
[ "$(bash -c "$src" _ "$TMPROOT/hooks" OUTCOME applied)" = "$(printf 'OUTCOME=applied\nRC=0')" ] && ok "emit valid" || bad "emit valid"
[ "$(bash -c "$src" _ "$TMPROOT/hooks" K 'a\b=c')" = "$(printf 'K=a\\\\b=c\nRC=0')" ] && ok "emit escapes backslash, keeps =" || bad "emit escape"
for k in "lower" "HAS SPACE" ""; do
  o="$(bash -c "$src" _ "$TMPROOT/hooks" "$k" v 2>/dev/null)"
  [ "$o" = "RC=2" ] && ok "emit rejects key '$k'" || bad "emit key '$k' ($o)"
done
o="$(bash -c "$src" _ "$TMPROOT/hooks" KEY "$(printf 'a\nb')" 2>/dev/null)"
[ "$o" = "RC=2" ] && ok "emit rejects multi-line value" || bad "emit multiline ($o)"

# --- squad_fail
errf="$TMPROOT/err"
bash -c '. "$1/squad-common.sh"; squad_fail 10 "precondition x"' _ "$TMPROOT/hooks" >"$TMPROOT/out" 2>"$errf"; rc=$?
[ "$rc" = 10 ] && ok "fail exits with code" || bad "fail rc=$rc"
[ "$(wc -l < "$errf" | tr -d ' ')" = 1 ] && [ "$(cat "$errf")" = "precondition x" ] && ok "fail one stderr line" || bad "fail stderr"
[ ! -s "$TMPROOT/out" ] && ok "fail writes nothing to stdout" || bad "fail stdout"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
