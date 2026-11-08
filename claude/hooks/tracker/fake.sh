#!/usr/bin/env bash
# tracker/fake.sh -- in-memory-on-disk tracker adapter, the reference for the
# adapter contract (scripts/test-squad-tracker.sh). SOURCED by squad_tracker
# when TRACKER_PROVIDER=fake. State lives in $SQUAD_FAKE_TRACKER_DIR, one
# file per issue: <id>.issue holding KEY=VALUE lines. No network, no CLI.
# Writes go through squad_provider_write's guard (squad_write_guard), exactly
# like a real adapter, so the detached-mode refusal is tested here too.

_fk_dir() {
  [ -n "${SQUAD_FAKE_TRACKER_DIR:-}" ] || { echo "squad: SQUAD_FAKE_TRACKER_DIR not set" >&2; return 20; }
  mkdir -p "$SQUAD_FAKE_TRACKER_DIR" 2>/dev/null || return 20
}
_fk_next() { local n=1; while [ -f "$SQUAD_FAKE_TRACKER_DIR/$n.issue" ]; do n=$((n + 1)); done; echo "$n"; }
_fk_get() { sed -n "s/^$2=//p" "$SQUAD_FAKE_TRACKER_DIR/$1.issue" | head -n 1; }
_fk_set() {  # _fk_set <id> <key> <value>
  local f="$SQUAD_FAKE_TRACKER_DIR/$1.issue"
  { grep -v "^$2=" "$f" 2>/dev/null; printf '%s=%s\n' "$2" "$3"; } > "$f.tmp" && mv "$f.tmp" "$f"
}

tracker_repo() { echo "REPO=fake/fake"; }

tracker_get() {
  [ -n "${1:-}" ] || { echo "squad: get requires an id" >&2; return 2; }
  _fk_dir || return 20
  [ -f "$SQUAD_FAKE_TRACKER_DIR/$1.issue" ] || { echo "squad: no issue $1" >&2; return 10; }
  echo "ID=$1"
  local k; for k in TITLE STATE URL PARENT BLOCKED_BY LABELS; do echo "$k=$(_fk_get "$1" $k)"; done
}

tracker_create() {
  local title="" parent="" blocked="" id
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="${2:-}"; shift 2 ;;
      --parent) parent="${2:-}"; shift 2 ;;
      --blocked-by) blocked="${2:-}"; shift 2 ;;
      --body|--label) shift 2 ;;
      *) echo "squad: create: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$title" ] || { echo "squad: create requires --title" >&2; return 2; }
  squad_write_guard || return 20
  _fk_dir || return 20
  id="$(_fk_next)"
  : > "$SQUAD_FAKE_TRACKER_DIR/$id.issue"
  _fk_set "$id" TITLE "$title"; _fk_set "$id" STATE open; _fk_set "$id" URL "fake://issue/$id"
  _fk_set "$id" PARENT "$parent"; _fk_set "$id" BLOCKED_BY "$blocked"; _fk_set "$id" LABELS ""
  echo "ID=$id"; echo "URL=fake://issue/$id"
}

tracker_create_child() {
  local p="${1:-}"
  [ -n "$p" ] || { echo "squad: create-child requires a parent id" >&2; return 2; }
  shift
  tracker_create "$@" --parent "$p"
}

tracker_batch() {
  local c="${1:-}" f id first=1
  [ -n "$c" ] || { echo "squad: batch requires a container id" >&2; return 2; }
  _fk_dir || return 20
  for f in "$SQUAD_FAKE_TRACKER_DIR"/*.issue; do
    [ -f "$f" ] || continue
    id="$(basename "$f" .issue)"
    [ "$(_fk_get "$id" PARENT)" = "$c" ] || continue
    [ "$first" = 1 ] || echo ""
    first=0
    tracker_get "$id"
  done
}

tracker_labels() { _fk_dir || return 20; _fk_get "$1" LABELS | tr ',' '\n' | grep -v '^$'; return 0; }
tracker_label_list() { echo "fake-label"; }
tracker_label_create() { squad_write_guard; }

# label <id> [--assign-me] [--add L]... [--remove L]...
tracker_label() {
  local id="${1:-}" cur new l
  [ -n "$id" ] || { echo "squad: label requires an id" >&2; return 2; }
  shift
  squad_write_guard || return 20
  _fk_dir || return 20
  cur="$(_fk_get "$id" LABELS)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --assign-me) shift ;;
      --add) cur="$(printf '%s\n%s\n' "$(printf '%s' "$cur" | tr ',' '\n')" "${2:-}" | grep -v '^$' | awk '!s[$0]++' | paste -sd, -)"; shift 2 ;;
      --remove) cur="$(printf '%s' "$cur" | tr ',' '\n' | grep -vxF -- "${2:-}" | paste -sd, -)"; shift 2 ;;
      *) echo "squad: label: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  _fk_set "$id" LABELS "$cur"
}

tracker_comment() {
  [ -n "${1:-}" ] && [ "${2:-}" = --body ] || { echo "squad: usage: comment <id> --body <text>" >&2; return 2; }
  squad_write_guard || return 20
  _fk_dir || return 20
  printf '%s\n' "${3:-}" >> "$SQUAD_FAKE_TRACKER_DIR/$1.comments"
}

tracker_preflight() { echo "PROVIDER=fake"; }
