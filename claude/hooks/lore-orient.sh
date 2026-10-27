#!/usr/bin/env bash
# Lore SessionStart orientation. Read-only. Injects "where you left off"
# context at session start so you do not have to ask. Never writes, never
# blocks: it always exits 0 and prints best-effort orientation to stdout,
# which the host injects as context.
#
# Registered by the plugin's hooks/hooks.json (SessionStart, matcher
# startup|clear|compact); no manual install step.

# Skip on resume: the orientation is already in the transcript, so a second
# copy is noise (agent view re-runs SessionStart on every session switch).
# startup, clear and compact orient (context is empty or was compacted).
# Missing or unparseable stdin keeps orienting, so the hook never goes
# silent on a host that passes no input. Drop `clear` from the matcher above
# if re-orienting after /clear turns out to be unwanted.
# A session spawned by a squad hook (SQUAD_LORE_HOOK=1, e.g. the nudge judge or
# the checkpoint writer) needs no orientation; a normal session never sets it.
[ -z "${SQUAD_LORE_HOOK:-}" ] || exit 0
HOOK_INPUT=""
if [ ! -t 0 ]; then
  IFS= read -r -t 2 -d '' HOOK_INPUT || true
fi
HOOK_SOURCE=""
if [ -n "$HOOK_INPUT" ]; then
  if command -v jq >/dev/null 2>&1; then
    HOOK_SOURCE="$(printf '%s' "$HOOK_INPUT" | jq -r '.source // empty' 2>/dev/null)"
  else
    HOOK_SOURCE="$(printf '%s' "$HOOK_INPUT" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  fi
fi
if [ "$HOOK_SOURCE" = "resume" ]; then
  echo "{}"
  exit 0
fi

# Resolve vault path, project root, and display name via the shared
# path-resolve.sh utility (installed alongside this hook) rather than
# re-deriving the algorithm here. See PATH_RESOLUTION.md.
#
# Parsed line-by-line (not `eval`'d): path-resolve.sh's output is not
# shell-quoted, so eval-ing it would break on a path containing a space
# and execute anything shaped like $(...) or `...` in a directory name.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -x "$HOOK_DIR/path-resolve.sh" ]; then
  while IFS='=' read -r _key _value; do
    case "$_key" in
      VAULT_PATH) VAULT="$_value" ;;
      PROJECT_ROOT) ROOT="$_value" ;;
      DISPLAY_NAME) DISPLAY="$_value" ;;
      SQUAD_DIR) SQUAD_DIR="$_value" ;;
      TRACKER_MODE) TRACKER_MODE="$_value" ;;
    esac
  done < <("$HOOK_DIR/path-resolve.sh")
else
  # path-resolve.sh not installed alongside this hook — degrade to
  # resolving inline rather than failing the whole orientation.
  VAULT="${SECOND_BRAIN_PATH:-$HOME/second-brain}"
  ROOT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$ROOT" ]; then ROOT="$(dirname "$ROOT")"; else ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; fi
  DISPLAY=""
  if [ -n "$ROOT" ] && [ -f "$VAULT/lore-config.json" ] && command -v jq >/dev/null 2>&1; then
    DISPLAY="$(jq -r --arg k "$ROOT" '.projects[$k] // empty' "$VAULT/lore-config.json" 2>/dev/null)"
  fi
fi

# Emit {"systemMessage": <msg>, "hookSpecificOutput": {"hookEventName":
# "SessionStart", "additionalContext": <msg>}} (or just {"systemMessage":
# <msg>} when $2 = "msg-only"). Claude Code ignores a top-level
# additionalContext; SessionStart needs it nested. Always via jq when
# available; falls back to manual JSON-string escaping otherwise so the
# hook keeps its "always print best-effort orientation" promise even
# without jq. The manual fallback is the *only* escaping applied to
# $1 — callers must pass raw, unescaped text, or content ends up
# double-escaped in the emitted JSON.
emit_json() {
  local msg="$1" mode="${2:-full}"
  if command -v jq >/dev/null 2>&1; then
    if [ "$mode" = "msg-only" ]; then
      jq -n --arg msg "$msg" '{systemMessage: $msg}'
    else
      jq -n --arg msg "$msg" '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $msg}}'
    fi
    return
  fi
  local esc="$msg"
  esc="${esc//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\t'/\\t}"
  esc="${esc//$'\r'/\\r}"
  esc="${esc//$'\n'/\\n}"
  if [ "$mode" = "msg-only" ]; then
    printf '{"systemMessage": "%s"}\n' "$esc"
  else
    printf '{"systemMessage": "%s", "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "%s"}}\n' "$esc" "$esc"
  fi
}

if [ ! -d "$VAULT" ]; then
  emit_json "Lore: no vault at $VAULT. Run /seed to initialize." msg-only
  exit 0
fi
if [ -z "$ROOT" ]; then
  echo "{}"
  exit 0
fi
if [ -z "$DISPLAY" ]; then
  emit_json "Lore: No vault mapping for this project — run /seed." msg-only
  exit 0
fi

PROJ="$VAULT/projects/$DISPLAY"
# Project knowledge location (vault or repo); progress.txt and session.log
# stay under the vault .squad/ regardless.
[ -z "${SQUAD_DIR:-}" ] && SQUAD_DIR="$PROJ/.squad"
STATUS="$PROJ/status.md"

NL=$'\n'

# Accumulate all text output into a variable, raw and unescaped — emit_json
# is the single place escaping happens, so content is never escaped twice.
OUTPUT="## Lore orientation — $DISPLAY (read-only, auto-injected)${NL}${NL}"

if [ -f "$STATUS" ]; then
  OUTPUT="${OUTPUT}### Last recorded status${NL}$(cat "$STATUS")${NL}"
  # Older versions live in the vault's git history (the checkpoints commit them).
  OUTPUT="${OUTPUT}Previous versions: git -C $VAULT log --oneline -- projects/$DISPLAY/status.md${NL}"
else
  OUTPUT="${OUTPUT}No status.md for this project yet. Reconstruct from the evidence below,${NL}or run /seed.${NL}"
fi

# Context refs: auto-load the files listed under "## Context refs" in
# status.md (read-only). Wikilinks [[path|label]] and plain paths, resolved
# relative to the vault. Caps: 5 refs, 60 lines per file, 2400 chars total.
if [ -f "$STATUS" ]; then
  REFS_MAX=5; REFS_LINES=60; REFS_BUDGET=2400
  REFS_OUT=""; REFS_N=0; REFS_FULL=0
  while IFS= read -r _line; do
    case "$_line" in
      '- '*|'* '*) _line="${_line:2}" ;;
      *) continue ;;
    esac
    if [[ "$_line" =~ \[\[([^]|]+)(\|[^]]*)?\]\] ]]; then
      _ref="${BASH_REMATCH[1]}"
    else
      _ref="${_line%% *}"
    fi
    case "$_ref" in ''|'—'|'-'|/*|*..*) continue ;; esac
    REFS_N=$((REFS_N + 1))
    [ "$REFS_N" -gt "$REFS_MAX" ] && break
    _file="$VAULT/$_ref"
    [ -f "$_file" ] || _file="$VAULT/$_ref.md"
    if [ ! -f "$_file" ]; then
      REFS_OUT="${REFS_OUT}⚠ Context ref not found: ${_ref} — skipping.${NL}"
      continue
    fi
    [ "$REFS_FULL" = 1 ] && continue
    _body="#### ${_ref}${NL}$(head -n "$REFS_LINES" "$_file")${NL}"
    [ "$(wc -l < "$_file" | tr -d ' ')" -gt "$REFS_LINES" ] && _body="${_body}… (truncated)${NL}"
    if [ $(( ${#REFS_OUT} + ${#_body} )) -gt "$REFS_BUDGET" ]; then
      _room=$(( REFS_BUDGET - ${#REFS_OUT} ))
      [ "$_room" -gt 0 ] && REFS_OUT="${REFS_OUT}${_body:0:$_room}${NL}"
      REFS_OUT="${REFS_OUT}… (truncated)${NL}"
      REFS_FULL=1
    else
      REFS_OUT="${REFS_OUT}${_body}"
    fi
  done < <(awk '/^## /{on = ($0 == "## Context refs"); next} on' "$STATUS")
  [ -n "$REFS_OUT" ] && OUTPUT="${OUTPUT}${NL}### Context refs${NL}${REFS_OUT}"
fi

# JOURNAL tail (#330): a `context: repo` project keeps its decisions in the
# repository's JOURNAL.md, so show the last 40 lines (at most 2400 chars, the
# same budget as the context refs). Silent when the file is absent.
if [ "$SQUAD_DIR" != "$PROJ/.squad" ] && [ -f "$ROOT/JOURNAL.md" ]; then
  _jt="$(tail -n 40 "$ROOT/JOURNAL.md" | tail -c 2400)"
  [ -n "$_jt" ] && OUTPUT="${OUTPUT}${NL}### JOURNAL.md (tail, context: repo)${NL}${_jt}${NL}"
fi

# Local evidence: cheap, offline, lets the model reconcile a stale status.md
# Uses the actual working directory, not $ROOT: $ROOT is the main project
# root (needed for the vault lookup above), but the branch/commits should
# reflect wherever this session actually is — the main checkout, or a
# Sidecar worktree on a different branch entirely.
OUTPUT="${OUTPUT}${NL}### Evidence (reconcile against the status above; it may be stale)${NL}"
OUTPUT="${OUTPUT}Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)${NL}"
OUTPUT="${OUTPUT}Recent commits:${NL}$(git log --oneline -5 2>/dev/null)${NL}"

# Open PRs (#328): connected mode only; detached prints nothing. The call is
# network-bound at SessionStart, so it runs in the background with a hard
# deadline (PR_TIMEOUT seconds, default 5) and can never block orientation.
if [ "${TRACKER_MODE:-}" = connected ]; then
  PR_TIMEOUT="${SQUAD_ORIENT_PR_TIMEOUT:-5}"
  PR_OUT=""
  if ! command -v gh >/dev/null 2>&1; then
    PR_OUT="Open PRs: unavailable (gh not found)"
  else
    _prf="$(mktemp 2>/dev/null)"
    ( gh auth status >/dev/null 2>&1 || { echo "AUTH" > "$_prf.err"; exit 1; }
      gh pr list --state open --limit 10 --json number,title,headRefName,baseRefName \
        --jq '.[] | "#\(.number) \(.title) (\(.headRefName) -> \(.baseRefName))"' > "$_prf" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    _pid=$!; _i=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_i" -lt $((PR_TIMEOUT * 10)) ]; do sleep 0.1; _i=$((_i + 1)); done
    if kill -0 "$_pid" 2>/dev/null; then
      pkill -P "$_pid" 2>/dev/null; kill "$_pid" 2>/dev/null
      PR_OUT="Open PRs: unavailable (gh timed out after ${PR_TIMEOUT}s)"
    elif wait "$_pid" 2>/dev/null; then
      if [ -s "$_prf" ]; then PR_OUT="Open PRs:${NL}$(cat "$_prf")"; else PR_OUT="Open PRs: none"; fi
    elif [ -f "$_prf.err" ]; then
      PR_OUT="Open PRs: unavailable (gh not authenticated)"
    else
      PR_OUT="Open PRs: unavailable (gh pr list failed)"
    fi
    rm -f "$_prf" "$_prf.err"
  fi
  OUTPUT="${OUTPUT}${PR_OUT}${NL}"
fi

# Open worktrees with uncommitted work: a killed session never ran SessionEnd,
# so derive it from git (one line per dirty linked worktree, at most 5).
DIRTY_WT=""; _n=0; _wt=""
while IFS= read -r _l; do
  case "$_l" in
    "worktree "*) _wt="${_l#worktree }" ;;
    "branch "*)
      if [ -n "$_wt" ] && [ "$_wt" != "$ROOT" ] && [ -d "$_wt" ]; then
        _c="$(git -C "$_wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
        if [ "${_c:-0}" -gt 0 ] && [ "$_n" -lt 5 ]; then
          DIRTY_WT="${DIRTY_WT}uncommitted work on ${_l#branch refs/heads/}: $_c files ($_wt)${NL}"
          _n=$((_n + 1))
        fi
      fi ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)
[ -n "$DIRTY_WT" ] && OUTPUT="${OUTPUT}Open worktrees:${NL}${DIRTY_WT}"

if [ -f "$PROJ/.squad/progress.txt" ]; then
  OUTPUT="${OUTPUT}progress.txt (tail):${NL}$(tail -n 5 "$PROJ/.squad/progress.txt")${NL}"
fi

if [ -f "$PROJ/.squad/session.log" ]; then
  OUTPUT="${OUTPUT}session.log (tail):${NL}$(tail -n 5 "$PROJ/.squad/session.log")${NL}"
fi

# Staleness and budget signals. Each line is omitted when not applicable.
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
SIGNALS=""
if [ -f "$SQUAD_DIR/architecture.md" ]; then
  ARCH_M="$(mtime "$SQUAD_DIR/architecture.md")"
  NEWEST_F=""; NEWEST_M=0
  for _f in package.json package-lock.json pnpm-lock.yaml yarn.lock bun.lockb \
    pyproject.toml uv.lock poetry.lock Cargo.toml Cargo.lock go.mod go.sum \
    Gemfile.lock composer.lock; do
    [ -f "$ROOT/$_f" ] || continue
    _m="$(mtime "$ROOT/$_f")"
    if [ -n "$_m" ] && [ "$_m" -gt "$NEWEST_M" ]; then NEWEST_M="$_m"; NEWEST_F="$_f"; fi
  done
  if [ -n "$NEWEST_F" ] && [ -n "$ARCH_M" ] && [ "$ARCH_M" -lt "$NEWEST_M" ]; then
    SIGNALS="${SIGNALS}Architecture snapshot older than $NEWEST_F; run /seed${NL}"
  fi
fi
# Vault health (#333): one shared script; its lines replace the status budget
# line and the saved SessionEnd decisions findings below, so nothing prints
# twice. Whole-vault pass only on small vaults (<= 60 projects).
HEALTH=""
if [ -x "$HOOK_DIR/vault-check.sh" ]; then
  _vc_args=(check --vault "$VAULT" --project "$DISPLAY")
  [ "$SQUAD_DIR" != "$PROJ/.squad" ] && _vc_args+=(--context repo)
  _projs=("$VAULT"/projects/*/)
  [ "${#_projs[@]}" -le 60 ] && _vc_args+=(--vault-wide)
  HEALTH="$(bash "$HOOK_DIR/vault-check.sh" "${_vc_args[@]}" 2>/dev/null | bash "$HOOK_DIR/vault-check.sh" render 2>/dev/null)"
fi
if [ -z "$HEALTH" ] && [ ! -x "$HOOK_DIR/vault-check.sh" ] && [ -f "$STATUS" ] && [ "$(wc -w < "$STATUS" | tr -d ' ')" -gt 300 ]; then
  SIGNALS="${SIGNALS}status.md over budget; next rebuild compresses${NL}"
fi
# Recurring squad incidents (one awk pass inside the store script). Silent
# when the script or store is missing.
if [ -x "$HOOK_DIR/squad-incidents.sh" ]; then
  _rec="$("$HOOK_DIR/squad-incidents.sh" summary 2>/dev/null | sed -n 's/^RECURRING=//p')"
  case "$_rec" in ''|*[!0-9]*|0) ;; *)
    SIGNALS="${SIGNALS}${_rec} recurring squad incidents: run $HOOK_DIR/squad-incidents.sh summary${NL}" ;;
  esac
fi
# Decisions lint findings left by the last SessionEnd (read-only here; the
# human text comes from decisions-lint.sh render, shared with `lore check`).
if [ ! -x "$HOOK_DIR/vault-check.sh" ] && [ -s "$PROJ/.decisions-lint" ] && [ -x "$HOOK_DIR/decisions-lint.sh" ]; then
  _dl="$(bash "$HOOK_DIR/decisions-lint.sh" render < "$PROJ/.decisions-lint" 2>/dev/null)"
  [ -n "$_dl" ] && SIGNALS="${SIGNALS}${_dl}${NL}"
fi
[ -n "$SIGNALS" ] && OUTPUT="${OUTPUT}${NL}### Signals${NL}${SIGNALS}"
[ -n "$HEALTH" ] && OUTPUT="${OUTPUT}${NL}${HEALTH}${NL}"

OUTPUT="${OUTPUT}${NL}If the status looks stale next to the evidence, run /lore recover to rebuild it.${NL}"

# Export final JSON — systemMessage shows in UI, hookSpecificOutput.additionalContext is injected as prompt context
emit_json "$OUTPUT"

exit 0