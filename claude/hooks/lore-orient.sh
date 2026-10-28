#!/usr/bin/env bash
# Lore SessionStart orientation. Injects "where you left off" context at
# session start so you do not have to ask. The only write is the starting-HEAD
# record of a linked-worktree session (see below). Never blocks: it always exits 0 and prints best-effort orientation to stdout,
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
HOOK_SOURCE=""; HOOK_CWD=""; HOOK_SESSION=""
if [ -n "$HOOK_INPUT" ]; then
  _hk() {
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$HOOK_INPUT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
    else
      printf '%s' "$HOOK_INPUT" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
    fi
  }
  HOOK_SOURCE="$(_hk source)"; HOOK_CWD="$(_hk cwd)"; HOOK_SESSION="$(_hk session_id)"
fi
# The session's own directory (a worktree session starts inside the worktree).
[ -n "$HOOK_CWD" ] && cd "$HOOK_CWD" 2>/dev/null
# record_start_head <proj-dir>: first write wins, so a compact or clear in the
# same session (same session_id) never moves the starting HEAD that SessionEnd
# counts commits from. Consumed by lore-checkpoint.sh at SessionEnd.
record_start_head() {
  [ -n "$HOOK_SESSION" ] || return 0
  [ -f "$1/.squad/sessions/$HOOK_SESSION" ] && return 0
  mkdir -p "$1/.squad/sessions" 2>/dev/null \
    && git rev-parse HEAD > "$1/.squad/sessions/$HOOK_SESSION" 2>/dev/null
}
if [ "$HOOK_SOURCE" = "resume" ]; then
  # No orientation, but a resumed worktree session (`claude -w <b> --resume`)
  # still needs a starting HEAD: SessionEnd deletes the previous record.
  _rv="$HOME/second-brain"; [ -n "${SECOND_BRAIN_PATH:-}" ] && _rv="$SECOND_BRAIN_PATH"
  _rd=""; _rr=""
  if [ -x "$(dirname "${BASH_SOURCE[0]:-$0}")/path-resolve.sh" ]; then
    while IFS='=' read -r _k _v; do
      case "$_k" in VAULT_PATH) _rv="$_v" ;; PROJECT_ROOT) _rr="$_v" ;; DISPLAY_NAME) _rd="$_v" ;; esac
    done < <("$(dirname "${BASH_SOURCE[0]:-$0}")/path-resolve.sh" 2>/dev/null)
  fi
  [ -z "$_rd" ] && [ -n "$_rr" ] && [ -d "$_rv/projects/${_rr##*/}" ] && _rd="${_rr##*/}"
  _rt="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$_rd" ] && [ -n "$_rr" ] && [ -n "$_rt" ] && [ "$_rt" != "$_rr" ] && [ -f "$_rt/.git" ]; then
    record_start_head "$_rv/projects/$_rd"
  fi
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
  # Local config first, then tracked, matching path-resolve.sh.
  if [ -n "$ROOT" ] && command -v jq >/dev/null 2>&1; then
    for _cfg in lore-config.local.json lore-config.json; do
      [ -f "$VAULT/$_cfg" ] || continue
      DISPLAY="$(jq -r --arg k "$ROOT" '.projects[$k] // empty' "$VAULT/$_cfg" 2>/dev/null)"
      [ -n "$DISPLAY" ] && break
    done
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
# SESSION_TITLE (set for a linked-worktree session) adds hookSpecificOutput.sessionTitle.
SESSION_TITLE=""
emit_json() {
  local msg="$1" mode="${2:-full}"
  if command -v jq >/dev/null 2>&1; then
    if [ "$mode" = "msg-only" ]; then
      jq -n --arg msg "$msg" '{systemMessage: $msg}'
    else
      jq -n --arg msg "$msg" --arg t "$SESSION_TITLE" '{systemMessage: $msg, hookSpecificOutput: ({hookEventName: "SessionStart", additionalContext: $msg} + (if $t != "" then {sessionTitle: $t} else {} end))}'
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
    local tj=""
    [ -n "$SESSION_TITLE" ] && tj=", \"sessionTitle\": \"${SESSION_TITLE//\"/\\\"}\""
    printf '{"systemMessage": "%s", "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "%s"%s}}\n' "$esc" "$esc" "$tj"
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
UNMAPPED_HINT=""
NAME_OWNED=""
if [ -z "$DISPLAY" ] && [ -d "$VAULT/projects/${ROOT##*/}" ]; then
  # Folder exists but no mapping for this checkout (local-only setups, #355).
  # Use it only when no checkout in either config owns that name.
  if command -v jq >/dev/null 2>&1; then
    for _cfg in lore-config.local.json lore-config.json; do
      [ -f "$VAULT/$_cfg" ] || continue
      if jq -e --arg n "${ROOT##*/}" '[.projects[]?] | index($n) != null' "$VAULT/$_cfg" >/dev/null 2>&1; then
        NAME_OWNED=1
      fi
    done
  fi
  if [ -z "$NAME_OWNED" ]; then
    DISPLAY="${ROOT##*/}"
    UNMAPPED_HINT="No lore-config entry maps this checkout; using projects/$DISPLAY. Add it to lore-config.local.json (local-only) or run /seed."
  fi
fi
if [ -z "$DISPLAY" ]; then
  if [ -n "$NAME_OWNED" ]; then
    emit_json "Lore: No vault mapping for this project — run /seed. projects/${ROOT##*/} belongs to another checkout." msg-only
  else
    emit_json "Lore: No vault mapping for this project — run /seed." msg-only
  fi
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
[ -n "$UNMAPPED_HINT" ] && OUTPUT="${OUTPUT}${UNMAPPED_HINT}${NL}${NL}"

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

# Linked-worktree orientation (#295): replaces the Sidecar skill's opening.
# A session started by `claude -w <branch>` runs inside .claude/worktrees/<name>;
# the WorktreeCreate hook (worktree.sh hook-create) already attached the branch
# and cloned node_modules. Here: base, diff stat, dependency lines, the session
# title, and the starting HEAD that SessionEnd counts commits from.
WT_TOP="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$WT_TOP" ] && [ "$WT_TOP" != "$ROOT" ] && [ -f "$WT_TOP/.git" ]; then
  WT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  OUTPUT="${OUTPUT}${NL}### Worktree session${NL}"
  if [ -n "$WT_BRANCH" ] && [ "$WT_BRANCH" != HEAD ]; then
    SESSION_TITLE="$WT_BRANCH"
    # Base, first match wins: open PR (connected), progress.txt naming this
    # branch, then main (said explicitly, never silently).
    WT_BASE=""; WT_BASE_SRC=""
    if [ "${TRACKER_MODE:-}" = connected ] && command -v gh >/dev/null 2>&1; then
      _bf="$(mktemp 2>/dev/null)"
      ( gh pr view "$WT_BRANCH" --json baseRefName -q .baseRefName > "$_bf" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
      _pid=$!; _i=0
      while kill -0 "$_pid" 2>/dev/null && [ "$_i" -lt 50 ]; do sleep 0.1; _i=$((_i + 1)); done
      if kill -0 "$_pid" 2>/dev/null; then pkill -P "$_pid" 2>/dev/null; kill "$_pid" 2>/dev/null; fi
      WT_BASE="$(head -n 1 "$_bf" 2>/dev/null)"; rm -f "$_bf"
      [ -n "$WT_BASE" ] && WT_BASE_SRC="open PR"
    fi
    if [ -z "$WT_BASE" ] && [ -f "$PROJ/.squad/progress.txt" ]; then
      WT_BASE="$(grep -F "[$WT_BRANCH]" "$PROJ/.squad/progress.txt" 2>/dev/null | tail -n 1 | sed -n 's/.*[Bb]ase[: ]*\([A-Za-z0-9._\/-][A-Za-z0-9._\/-]*\).*/\1/p')"
      [ -n "$WT_BASE" ] && WT_BASE_SRC="progress.txt"
    fi
    if [ -z "$WT_BASE" ]; then WT_BASE="main"; WT_BASE_SRC="default, no PR or progress.txt entry names one"; fi
    OUTPUT="${OUTPUT}Branch: $WT_BRANCH   Base: $WT_BASE ($WT_BASE_SRC)${NL}"
    # Share the resolved base with worktree-prompt-check.sh (#282), which
    # fetches and compares heads on every prompt; its notes ask for a round
    # report that starts with head before -> after and the base head.
    printf '%s\n' "$WT_BASE" > "$(git rev-parse --absolute-git-dir 2>/dev/null)/squad-base" 2>/dev/null
    OUTPUT="${OUTPUT}Each prompt a hook fetches origin and fast-forwards when safe; start each round's report with head before -> after and the base head.${NL}"
    case "$WT_BRANCH" in
      main|master|develop|release/*|hotfix/*)
        OUTPUT="${OUTPUT}WARNING: $WT_BRANCH is a shared integration branch; Cody refuses to commit on it.${NL}" ;;
    esac
    _bref=""
    for _c in "$WT_BASE" "origin/$WT_BASE"; do
      git rev-parse --verify --quiet "$_c^{commit}" >/dev/null 2>&1 && { _bref="$_c"; break; }
    done
    if [ -n "$_bref" ]; then
      OUTPUT="${OUTPUT}Diff vs $_bref: $(git diff "$_bref...HEAD" --stat 2>/dev/null | tail -n 1 | sed 's/^ *//')${NL}"
    else
      OUTPUT="${OUTPUT}Diff: base $WT_BASE not found locally${NL}"
    fi
    # Dependency lines: stored by hook-create in the worktree's git dir.
    _deps="$(git rev-parse --absolute-git-dir 2>/dev/null)/squad-deps"
    if [ -s "$_deps" ]; then
      while IFS= read -r _l; do
        case "$_l" in
          DEP=*)
            IFS='|' read -r _rel _out _tier _sec <<< "${_l#DEP=}"
            case "$_out" in
              cloned) OUTPUT="${OUTPUT}Dependencies: $_tier clone of $_rel in ${_sec}s${NL}" ;;
              already-present) OUTPUT="${OUTPUT}Dependencies: $_rel already present${NL}" ;;
              failed) OUTPUT="${OUTPUT}Dependencies: clone of $_rel failed; run your install command in $WT_TOP/$(dirname "$_rel") before testing.${NL}" ;;
            esac ;;
          HOOKS=missing\|*)
            IFS='|' read -r _ _hp _hc <<< "${_l#HOOKS=}"
            OUTPUT="${OUTPUT}Git hooks: core.hooksPath points at $_hp, which is missing in this worktree.${_hc:+ Run \`$_hc\` in $WT_TOP to create it.}${NL}" ;;
          STALE=*)
            IFS='|' read -r _rel _kind <<< "${_l#STALE=}"
            case "$_kind" in
              branch-drift) OUTPUT="${OUTPUT}Dependencies check: WARNING - the lockfile for $_rel differs between branch $WT_BRANCH and the source checkout; the copied node_modules may not match. Install in $WT_TOP/$(dirname "$_rel") before testing.${NL}" ;;
              presence-diff) OUTPUT="${OUTPUT}Dependencies check: WARNING - the lockfile for $_rel exists in only one of the worktree and the source checkout. Install in $WT_TOP/$(dirname "$_rel") to regenerate it.${NL}" ;;
              self-stale) OUTPUT="${OUTPUT}Dependencies check: NOTE - the source checkout's node_modules at $_rel is older than its lockfile; the copy may already have been stale. Install in the source checkout, not the worktree.${NL}" ;;
            esac ;;
        esac
      done < "$_deps"
      case "$OUTPUT" in *"Dependencies check: WARNING"*) OUTPUT="${OUTPUT}If a build or test fails, it may be the dependency mismatch, not the code change.${NL}" ;; esac
    fi
    # Env override (#278): variables whose value is a path inside the source
    # checkout would make tools act on it, not on this worktree. Scanned here
    # (SessionStart) because this hook sees the session environment and can
    # write CLAUDE_ENV_FILE, which reaches the session's and subagents' Bash.
    # Nothing is written to the source checkout or shared git config.
    if [ -x "$HOOK_DIR/worktree.sh" ]; then
      while IFS= read -r _l; do
        case "$_l" in ENV=*) ;; *) continue ;; esac
        IFS='|' read -r _en _es _ew <<< "${_l#ENV=}"
        if [ "$_es" = "$ROOT" ]; then _ex="export $_en=\"\$PWD\""; else _ex="export $_en=\"$_ew\""; fi
        if [ -n "${CLAUDE_ENV_FILE:-}" ] && printf "export %s='%s'\n" "$_en" "$(printf '%s' "$_ew" | sed "s/'/'\\\\''/g")" >> "$CLAUDE_ENV_FILE" 2>/dev/null; then
          OUTPUT="${OUTPUT}Env override: $_en pointed at the source checkout ($_es); set to $_ew for this session's Bash and subagents (applied via CLAUDE_ENV_FILE). Manual equivalent: $_ex${NL}"
        else
          OUTPUT="${OUTPUT}Env override: WARNING - $_en points at the source checkout ($_es), so tools may act on it instead of this worktree. Run: $_ex${NL}"
        fi
      done < <(cd "$WT_TOP" && "$HOOK_DIR/worktree.sh" env "$WT_TOP" 2>/dev/null)
    fi
    # Per-session resources (#281). Owner = worktree name: stable across
    # resume and compaction (session ids change), so the claim is idempotent;
    # released by worktree.sh hook-remove, never at SessionEnd (resume).
    _wtn="$(bash "$HOOK_DIR/squad-session.sh" owner --worktree "$WT_TOP" 2>/dev/null | sed -n 's/^OWNER=//p')"
    [ -n "$_wtn" ] || _wtn="$(basename "$WT_TOP")"
    _ss="$HOOK_DIR/squad-session.sh"
    _port="$(bash "$_ss" port --owner "$_wtn" --worktrees "$(dirname "$WT_TOP")" 2>/dev/null | sed -n 's/^PORT=//p')"
    _prof="$(bash "$_ss" profile --owner "$_wtn" --scratch "$(git rev-parse --absolute-git-dir 2>/dev/null)" 2>/dev/null | sed -n 's/^PROFILE_DIR=//p')"
    if [ -n "$_port" ]; then
      OUTPUT="${OUTPUT}Port: $_port (serve your dev server on it; also exported as SQUAD_PORT)${NL}"
      if [ -n "${CLAUDE_ENV_FILE:-}" ] && ! grep -qx "export SQUAD_PORT=$_port" "$CLAUDE_ENV_FILE" 2>/dev/null; then
        printf 'export SQUAD_PORT=%s\n' "$_port" >> "$CLAUDE_ENV_FILE" 2>/dev/null
      fi
    else
      OUTPUT="${OUTPUT}Port: none free in 3100..3149; pick a free port yourself and say which.${NL}"
    fi
    [ -n "$_prof" ] && OUTPUT="${OUTPUT}Browser profile dir: $_prof${NL}Browser rule: use a headless Playwright context with that profile by default. Use the shared MCP browser only after \`bash ${_ss} browser-lock acquire --owner $_wtn\` succeeds (re-acquire before each browser pass, release when done); exit 10 means held, fall back to your own context, never wait.${NL}"
    OUTPUT="${OUTPUT}Remote test data: name every remote entity you create or mutate in your report and restore it afterwards; do not touch entities another session may be using.${NL}"
    # Starting HEAD for SessionEnd (commits in THIS session, not the branch).
    if [ -n "$HOOK_SESSION" ]; then
      record_start_head "$PROJ"
      find "$PROJ/.squad/sessions" -type f -mtime +14 -delete 2>/dev/null
    fi
  else
    OUTPUT="${OUTPUT}Detached HEAD in $WT_TOP; no branch name to show.${NL}"
  fi
fi

# Local evidence: cheap, offline, lets the model reconcile a stale status.md
# Uses the actual working directory, not $ROOT: $ROOT is the main project
# root (needed for the vault lookup above), but the branch/commits should
# reflect wherever this session actually is — the main checkout, or a
# linked worktree on a different branch entirely.
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