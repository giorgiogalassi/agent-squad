#!/usr/bin/env bash
# Tests scripts/lib/test-tmp.sh and lint check 11 (issue #376).
# Failure mode under test: a failed mktemp left TMPROOT empty, `cd ""` made it
# the working directory, and the EXIT trap deleted it. Everything that could
# be destroyed here lives in a sandbox created with the REAL mktemp before
# anything is broken; the broken mktemp is a fake placed first on PATH.
# Plain bash 3.2.
set -u
export SQUAD_INCIDENTS=off
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-safe-tmproot.XXXXXX")" || exit 2 # lint:tmp-ok
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "cannot create sandbox" >&2; exit 2; }
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
trap 'case "$SANDBOX" in /?*/?*) rm -rf "$SANDBOX" ;; esac' EXIT # lint:tmp-ok
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

# --- fake mktemp variants -------------------------------------------------
mkdir -p "$SANDBOX/fake-fail" "$SANDBOX/fake-empty" "$SANDBOX/fake-outside" "$SANDBOX/outside" "$SANDBOX/work"
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/fake-fail/mktemp"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/fake-empty/mktemp"
printf '#!/bin/sh\necho "%s/outside"\n' "$SANDBOX" > "$SANDBOX/fake-outside/mktemp"
chmod +x "$SANDBOX"/fake-*/mktemp
echo keep > "$SANDBOX/outside/sentinel"

# run_broken <fakedir> <script...>: runs in $SANDBOX/work with TMPDIR set to a
# base that is NOT the sandbox's "outside" dir. Sets RC and OUT.
run_broken() {
  local fake="$1"; shift
  mkdir -p "$SANDBOX/base"
  echo keep > "$SANDBOX/work/sentinel"
  OUT="$(cd "$SANDBOX/work" && PATH="$SANDBOX/$fake:$PATH" TMPDIR="$SANDBOX/base" bash "$@" 2>&1 >/dev/null)"
  RC=$?
}
intact() {  # nothing deleted or written in the cwd; outside dir untouched
  [ -f "$SANDBOX/work/sentinel" ] && [ -f "$SANDBOX/outside/sentinel" ] \
    && [ "$(ls -A "$SANDBOX/work" | tr '\n' ' ')" = "sentinel " ]
}

# --- helper -----------------------------------------------------------------
cat > "$SANDBOX/probe.sh" <<PROBE
. "$REPO_ROOT/scripts/lib/test-tmp.sh"
test_tmp_init probe
echo "reached \$TMPROOT" > "\$TMPROOT/f"
echo "\$TMPROOT" > "$SANDBOX/probe.root"
PROBE
for fake in fake-fail fake-empty fake-outside; do
  run_broken "$fake" "$SANDBOX/probe.sh"
  if [ "$RC" -eq 2 ] && [ -n "$OUT" ] && intact; then ok "helper: $fake exits 2 with a reason, cwd intact"
  else bad "helper: $fake (rc=$RC out=[$OUT])"; fi
done
rm -f "$SANDBOX/probe.root"
echo keep > "$SANDBOX/work/sentinel"
(cd "$SANDBOX/work" && TMPDIR="$SANDBOX/base" bash "$SANDBOX/probe.sh") >/dev/null 2>&1
root="$(cat "$SANDBOX/probe.root" 2>/dev/null)"
if [ -n "$root" ] && [ ! -e "$root" ] && [ -f "$SANDBOX/work/sentinel" ]; then ok "helper: normal run creates then removes the root"
else bad "helper: normal run (root=[$root])"; fi

# The cleanup itself refuses paths outside the temp base.
out="$(cd "$SANDBOX/work" && TMPDIR="$SANDBOX/base" bash -c '. "$1"; FIXROOTS="$2 $3 /"; TEST_TMP_ROOTS="$4"; test_tmp_cleanup' _ \
  "$REPO_ROOT/scripts/lib/test-tmp.sh" "$SANDBOX/outside" "$SANDBOX/work" "$SANDBOX/base" 2>&1)"
if [ -f "$SANDBOX/outside/sentinel" ] && [ -f "$SANDBOX/work/sentinel" ] && [ -d "$SANDBOX/base" ]; then ok "helper: cleanup refuses paths outside (and equal to) the temp base"
else bad "helper: cleanup deleted something it should not ($out)"; fi

# --- every real test script -------------------------------------------------
n=0
for t in "$REPO_ROOT"/scripts/test-*.sh; do
  case "$t" in */test-safe-tmproot.sh) continue ;; esac
  case "$(basename "$t")" in test-chisel-config-validate.sh|test-plugin-version-bump.sh) continue ;; esac  # no scratch root
  n=$((n+1))
  run_broken fake-fail "$t"
  if [ "$RC" -ne 0 ] && intact; then ok "$(basename "$t"): mktemp broken -> rc=$RC, nothing written or deleted"
  else bad "$(basename "$t"): mktemp broken (rc=$RC, cwd: $(ls -A "$SANDBOX/work" | tr '\n' ' '))"; fi
done
[ "$n" -ge 20 ] && ok "covered $n test scripts" || bad "only $n test scripts covered"

# --- lint check 11 ----------------------------------------------------------
LF="$SANDBOX/lintfix"
mkdir -p "$LF"
cp -R "$REPO_ROOT/claude" "$LF/claude"
cp -R "$REPO_ROOT/scripts" "$LF/scripts"
cp "$REPO_ROOT"/*.md "$LF/" 2>/dev/null
[ -d "$REPO_ROOT/codex" ] && cp -R "$REPO_ROOT/codex" "$LF/codex"
[ -d "$REPO_ROOT/docs" ] && cp -R "$REPO_ROOT/docs" "$LF/docs"
lint() { bash "$REPO_ROOT/scripts/squad-lint.sh" --repo-root "$LF" 2>&1; }
out="$(lint)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "lint: clean fixture passes"; else bad "lint: clean fixture failed: $(printf '%s' "$out" | grep FAIL | head -3)"; fi

printf '#!/usr/bin/env bash\nTMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")"\nTMPROOT="$(cd "$TMPROOT" && pwd -P)"\ntrap '"'"'rm -rf "$TMPROOT"'"'"' EXIT\n' > "$LF/scripts/test-zz-unsafe.sh"
out="$(lint)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL.*11\..*test-zz-unsafe.sh:2' && printf '%s' "$out" | grep -q 'test-zz-unsafe.sh:4'; then ok "lint: unsafe mktemp + raw rm trap flagged"
else bad "lint: unsafe script not flagged (rc=$rc)"; fi

printf '#!/usr/bin/env bash\nTMP=$(mktemp -d)\n' > "$LF/scripts/test-zz-unsafe.sh"
out="$(lint)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'test-zz-unsafe.sh:2'; then ok "lint: bare command-substitution mktemp flagged"
else bad "lint: bare mktemp not flagged (rc=$rc)"; fi
rm -f "$LF/scripts/test-zz-unsafe.sh"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
