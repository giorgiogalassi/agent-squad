#!/usr/bin/env bash
# squad-session.sh -- per-session resources for parallel worktree sessions:
# serve port, headless browser profile dir, shared-browser lock.
# Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq, no gh.
#
# Usage:
#   squad-session.sh port    --owner <id> [--dir <d>] [--base <n>] [--slots <n>] [--ttl <s>] [--worktrees <d>]
#   squad-session.sh owner   --worktree <path>
#   squad-session.sh release --owner <id> [--dir <d>]
#   squad-session.sh profile --owner <id> --scratch <d>
#   squad-session.sh browser-lock acquire|release|status --owner <id> [--dir <d>] [--ttl <s>]
#
# <d> defaults to ${SQUAD_SESSION_DIR:-${TMPDIR:-/tmp}/agent-squad-session}.
# port: first free port in base..base+slots-1 (default 3100, 50 slots) that
#   lsof shows not listening and no other owner holds a fresh claim on;
#   idempotent per owner. Emits PORT, SLOT. --worktrees <d> first drops port
#   claims of the caller's repo (owner prefix <key>-) whose worktree directory
#   <d>/<name> is gone; other repos' claims are never touched.
# owner: emits OWNER=<key>-<basename>, key = short hash of the repo's common
#   git dir, so same-named worktrees in two repos never share a claim.
# release: drops the owner's port claim (and a browser lock it holds).
# profile: creates <scratch>/playwright-profile, emits PROFILE_DIR.
# browser-lock: guards the shared MCP browser. acquire exits 10 with
#   LOCK=held when another owner holds a fresh lock (caller falls back to its
#   own headless context, never waits); stale locks (older than --ttl,
#   default 900s) are taken over. Emits LOCK=acquired|held|released|free and,
#   for held, LOCK_OWNER.
# Exit: 0 ok, 2 usage, 10 precondition failed (no free port / lock held),
#   20 I/O error.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

USAGE="usage: squad-session.sh port|release|profile|browser-lock ..."
VERB="${1:-}"
case "$VERB" in port|release|profile|browser-lock|owner) shift ;; *) squad_fail 2 "$USAGE" ;; esac
SUB=""
if [ "$VERB" = browser-lock ]; then
  SUB="${1:-}"
  case "$SUB" in acquire|release|status) shift ;; *) squad_fail 2 "browser-lock needs acquire|release|status" ;; esac
fi

OWNER=""; DIR="${SQUAD_SESSION_DIR:-${TMPDIR:-/tmp}/agent-squad-session}"
BASE=3100; SLOTS=50; TTL=""; SCRATCH=""; WTDIR=""; WTPATH=""
need() { [ $# -ge 2 ] || squad_fail 2 "$1 requires a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) need "$@"; OWNER="$2"; shift 2 ;;
    --dir) need "$@"; DIR="$2"; shift 2 ;;
    --base) need "$@"; BASE="$2"; shift 2 ;;
    --slots) need "$@"; SLOTS="$2"; shift 2 ;;
    --ttl) need "$@"; TTL="$2"; shift 2 ;;
    --scratch) need "$@"; SCRATCH="$2"; shift 2 ;;
    --worktree) need "$@"; WTPATH="$2"; shift 2 ;;
    --worktrees) need "$@"; WTDIR="$2"; shift 2 ;;
    *) squad_fail 2 "unknown argument: $1" ;;
  esac
done

case "$BASE$SLOTS$TTL" in *[!0-9]*) squad_fail 2 "--base, --slots and --ttl must be non-negative integers" ;; esac
if [ "$VERB" = owner ]; then
  [ -n "$WTPATH" ] || squad_fail 2 "--worktree is required"
  cd=""; cd="$(git -C "$WTPATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || cd=""
  [ -n "$cd" ] || cd="$(cd "$WTPATH" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
  [ -n "$cd" ] || squad_fail 10 "$WTPATH is not in a git repository"
  k="$(printf '%s' "$cd" | cksum | cut -d' ' -f1)"
  squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit OWNER "$k-$(basename "$WTPATH")"
  exit 0
fi
[ -n "$OWNER" ] || squad_fail 2 "--owner is required"
case "$OWNER" in *[!A-Za-z0-9._-]*) squad_fail 2 "--owner may contain only A-Za-z0-9._-" ;; esac

NOW="$(date +%s)"

# claim_fields <file>: sets C_OWNER, C_TS from "owner<TAB>epoch".
claim_fields() {
  C_OWNER=""; C_TS=0
  [ -f "$1" ] || return 0
  IFS="$(printf '\t')" read -r C_OWNER C_TS < "$1" || true
  case "$C_TS" in ''|*[!0-9]*) C_TS=0 ;; esac
}
# write_new <file>: atomic create (fails when the file exists).
write_new() { ( set -C; printf '%s\t%s\n' "$OWNER" "$NOW" > "$1" ) 2>/dev/null; }

# mtime <path>: epoch mtime; BSD stat first (validated numeric), GNU fallback.
mtime() {
  _m="$(stat -f %m "$1" 2>/dev/null)"
  case "$_m" in ''|*[!0-9]*) _m="$(stat -c %Y "$1" 2>/dev/null)" ;; esac
  case "$_m" in ''|*[!0-9]*) _m="$NOW" ;; esac
  printf '%s' "$_m"
}
# take_mutex <dir>: mkdir mutex for stale takeover. A mutex dir older than
# SQUAD_TAKE_TTL seconds (default 60) belongs to a dead process: remove it and
# retry once. Never waits.
take_mutex() {
  mkdir "$1" 2>/dev/null && return 0
  [ -d "$1" ] && [ $((NOW - $(mtime "$1"))) -ge "${SQUAD_TAKE_TTL:-60}" ] || return 1
  rmdir "$1" 2>/dev/null
  mkdir "$1" 2>/dev/null
}

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

case "$VERB" in
port)
  [ -n "$TTL" ] || TTL=43200
  mkdir -p "$DIR/ports" || squad_fail 20 "cannot create $DIR/ports"
  if [ -n "$WTDIR" ]; then
    for f in "$DIR"/ports/*; do
      [ -f "$f" ] || continue
      claim_fields "$f"
      case "$C_OWNER" in
        "${OWNER%%-*}"-*)
          [ "$C_OWNER" != "$OWNER" ] && [ ! -d "$WTDIR/${C_OWNER#*-}" ] && rm -f "$f" ;;
      esac
    done
  fi
  i=0
  while [ "$i" -lt "$SLOTS" ]; do
    p=$((BASE + i)); f="$DIR/ports/$p"
    claim_fields "$f"
    if [ "$C_OWNER" = "$OWNER" ]; then
      printf '%s\t%s\n' "$OWNER" "$NOW" > "$f"
      squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit PORT "$p"; squad_emit SLOT "$i"; exit 0
    fi
    i=$((i+1))
  done
  i=0
  while [ "$i" -lt "$SLOTS" ]; do
    p=$((BASE + i)); f="$DIR/ports/$p"
    if ! port_busy "$p"; then
      claim_fields "$f"
      # Stale takeover under a mkdir mutex, re-checked inside it, so two
      # takers cannot delete a claim the other has just recreated.
      if [ -f "$f" ] && [ $((NOW - C_TS)) -ge "$TTL" ]; then
        if take_mutex "$f.take"; then
          claim_fields "$f"
          [ $((NOW - C_TS)) -ge "$TTL" ] && rm -f "$f"
          write_new "$f"; rmdir "$f.take" 2>/dev/null
        fi
        claim_fields "$f"
        if [ "$C_OWNER" = "$OWNER" ]; then
          squad_emit OUTCOME applied; squad_emit CHANGED yes; squad_emit PORT "$p"; squad_emit SLOT "$i"; exit 0
        fi
      elif write_new "$f"; then
        squad_emit OUTCOME applied; squad_emit CHANGED yes; squad_emit PORT "$p"; squad_emit SLOT "$i"; exit 0
      fi
    fi
    i=$((i+1))
  done
  squad_fail 10 "no free port in $BASE..$((BASE + SLOTS - 1))"
  ;;
release)
  changed=no
  for f in "$DIR"/ports/* "$DIR/browser.lock"; do
    [ -f "$f" ] || continue
    claim_fields "$f"
    if [ "$C_OWNER" = "$OWNER" ]; then rm -f "$f" && changed=yes; fi
  done
  squad_emit OUTCOME "$([ $changed = yes ] && echo applied || echo unchanged)"
  squad_emit CHANGED "$changed"
  ;;
profile)
  [ -n "$SCRATCH" ] || squad_fail 2 "--scratch is required"
  P="$SCRATCH/playwright-profile"
  if [ -d "$P" ]; then ch=no; out=unchanged; else mkdir -p "$P" || squad_fail 20 "cannot create $P"; ch=yes; out=applied; fi
  squad_emit OUTCOME "$out"; squad_emit CHANGED "$ch"; squad_emit PROFILE_DIR "$P"
  ;;
browser-lock)
  [ -n "$TTL" ] || TTL=900
  mkdir -p "$DIR" || squad_fail 20 "cannot create $DIR"
  L="$DIR/browser.lock"
  claim_fields "$L"
  fresh=no
  [ -f "$L" ] && [ $((NOW - C_TS)) -lt "$TTL" ] && fresh=yes
  case "$SUB" in
  status)
    squad_emit OUTCOME unchanged; squad_emit CHANGED no
    if [ $fresh = yes ]; then squad_emit LOCK held; squad_emit LOCK_OWNER "$C_OWNER"; else squad_emit LOCK free; fi
    ;;
  acquire)
    if [ $fresh = yes ] && [ "$C_OWNER" = "$OWNER" ]; then
      printf '%s\t%s\n' "$OWNER" "$NOW" > "$L"
      squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit LOCK acquired; exit 0
    fi
    if [ $fresh = yes ]; then
      squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit LOCK held; squad_emit LOCK_OWNER "$C_OWNER"
      squad_fail 10 "shared browser held by $C_OWNER; use your own headless Playwright context"
    fi
    if [ -f "$L" ]; then
      # Stale takeover under a mkdir mutex, re-checked inside it.
      if take_mutex "$L.take"; then
        claim_fields "$L"
        [ $((NOW - C_TS)) -ge "$TTL" ] && rm -f "$L"
        write_new "$L"; rmdir "$L.take" 2>/dev/null
      fi
      claim_fields "$L"
      [ "$C_OWNER" = "$OWNER" ] && write_ok=1 || write_ok=0
    else
      write_new "$L"; claim_fields "$L"
      [ "$C_OWNER" = "$OWNER" ] && write_ok=1 || write_ok=0
    fi
    if [ "$write_ok" = 1 ]; then
      squad_emit OUTCOME applied; squad_emit CHANGED yes; squad_emit LOCK acquired
    else
      claim_fields "$L"
      squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit LOCK held; squad_emit LOCK_OWNER "$C_OWNER"
      squad_fail 10 "shared browser taken by $C_OWNER; use your own headless Playwright context"
    fi
    ;;
  release)
    if [ -f "$L" ] && [ "$C_OWNER" = "$OWNER" ]; then
      rm -f "$L"; squad_emit OUTCOME applied; squad_emit CHANGED yes
    else
      squad_emit OUTCOME unchanged; squad_emit CHANGED no
    fi
    squad_emit LOCK released
    ;;
  esac
  ;;
esac
exit 0
