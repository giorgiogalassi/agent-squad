#!/usr/bin/env bash
# Lore SessionStart orientation. Read-only. Injects "where you left off"
# context at session start so you do not have to ask. Never writes, never
# blocks: it always exits 0 and prints best-effort orientation to stdout,
# which the host injects as context.
#
# Registered by the plugin's hooks/hooks.json (SessionStart, matcher
# startup|clear|compact); no manual install step.

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

# Local evidence: cheap, offline, lets the model reconcile a stale status.md
# Uses the actual working directory, not $ROOT: $ROOT is the main project
# root (needed for the vault lookup above), but the branch/commits should
# reflect wherever this session actually is — the main checkout, or a
# Sidecar worktree on a different branch entirely.
OUTPUT="${OUTPUT}${NL}### Evidence (reconcile against the status above; it may be stale)${NL}"
OUTPUT="${OUTPUT}Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)${NL}"
OUTPUT="${OUTPUT}Recent commits:${NL}$(git log --oneline -5 2>/dev/null)${NL}"

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
if [ -f "$STATUS" ] && [ "$(wc -w < "$STATUS" | tr -d ' ')" -gt 300 ]; then
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
[ -n "$SIGNALS" ] && OUTPUT="${OUTPUT}${NL}### Signals${NL}${SIGNALS}"

OUTPUT="${OUTPUT}${NL}If the status looks stale next to the evidence, run /lore recover to rebuild it.${NL}"

# Export final JSON — systemMessage shows in UI, hookSpecificOutput.additionalContext is injected as prompt context
emit_json "$OUTPUT"

exit 0