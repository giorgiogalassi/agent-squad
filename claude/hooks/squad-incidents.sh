#!/usr/bin/env bash
# squad-incidents.sh -- global append-only incident store. Bash 3.2.
# Verbs: record | summary | resolve. Contract: SCRIPT_CONTRACT.md.
# EXCEPTION: `record` never writes stdout and always exits 0, so failure
# paths can call it safely. Never calls path-resolve.sh.
#
# Store (TSV, one line per event):
#   ts session_id project source kind component signature dedupe_id excerpt
# Path: $SQUAD_INCIDENTS_FILE, else $SECOND_BRAIN_PATH/squad-incidents.tsv,
# else ~/second-brain/squad-incidents.tsv.
#
#   record  --session S --project P --source script|transcript
#           --kind failure|escalation|denial --component C [--exit N]
#           [--reason R] [--dedupe-id D]
#   summary
#   resolve --signature SIG --ref REF

SQUAD_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=squad-common.sh
. "$SQUAD_HOOKS_DIR/squad-common.sh"

TAB="$(printf '\t')"

store_path() {
  if [ -n "${SQUAD_INCIDENTS_FILE:-}" ]; then printf '%s' "$SQUAD_INCIDENTS_FILE"
  elif [ -n "${SECOND_BRAIN_PATH:-}" ]; then printf '%s/squad-incidents.tsv' "$SECOND_BRAIN_PATH"
  else printf '%s/second-brain/squad-incidents.tsv' "$HOME"; fi
}

# clean <text> <max>: strip tab/CR/LF, redact secrets, truncate.
clean() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
    -e 's/(AKIA|ASIA)[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/[0-9a-fA-F]{32,}/[REDACTED]/g' \
    -e 's/[A-Za-z0-9+\/=_-]{40,}/[REDACTED]/g' | cut -c1-"$2"
}

# normalise <reason>: lowercase, drop paths/SHAs/digits/punctuation.
normalise() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | tr 'A-Z' 'a-z' | sed -E \
    -e 's/[^ ]*\/[^ ]*/ /g' \
    -e 's/[0-9a-f]{7,}/ /g' \
    -e 's/[^a-z ]+/ /g' \
    -e 's/ +/ /g' -e 's/^ //' -e 's/ $//' | cut -c1-80
}

safe_token() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

cmd_record() (
  set +e +u
  exec 2>/dev/null
  [ "${SQUAD_INCIDENTS:-}" = "off" ] && exit 0
  local_session=""; project=""; source_=""; kind=""; comp=""; code=""; reason=""; dedupe=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) [ $# -ge 2 ] || break; local_session="$2"; shift 2 ;;
      --project) [ $# -ge 2 ] || break; project="$2"; shift 2 ;;
      --source) [ $# -ge 2 ] || break; source_="$2"; shift 2 ;;
      --kind) [ $# -ge 2 ] || break; kind="$2"; shift 2 ;;
      --component) [ $# -ge 2 ] || break; comp="$2"; shift 2 ;;
      --exit) [ $# -ge 2 ] || break; code="$2"; shift 2 ;;
      --reason) [ $# -ge 2 ] || break; reason="$2"; shift 2 ;;
      --dedupe-id) [ $# -ge 2 ] || break; dedupe="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$source_" in script|transcript) ;; *) source_="" ;; esac
  file="$(store_path)"
  [ -d "$(dirname "$file")" ] || exit 0
  case "$kind" in failure|escalation|denial) ;; *) exit 0 ;; esac
  comp="$(safe_token "$comp")"
  dedupe="$(safe_token "$dedupe")"
  if [ -n "$dedupe" ] && [ -f "$file" ] && \
     awk -F'\t' -v d="$dedupe" '$8==d{f=1} END{exit !f}' "$file"; then
    exit 0
  fi
  case "$project" in ""|local) ;; *) squad_local_only "$(dirname "$file")" "$project" && project=local ;; esac
  sig="$comp|$kind|$(safe_token "$code")|$(normalise "$reason")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$(safe_token "$local_session")" "$(safe_token "$project")" "$(safe_token "$source_")" \
    "$kind" "$comp" "$sig" "$dedupe" "$(clean "$reason" 120)" >> "$file"
  exit 0
)

cmd_summary() {
  local file; file="$(store_path)"
  if [ ! -f "$file" ]; then
    squad_emit RECURRING 0 || return $?
    squad_emit ESCALATIONS 0
    return $?
  fi
  awk -F'\t' '
    $5=="failure" || $5=="denial" {
      s=$7; cnt[s]++; last[s]=$1; lastn[s]=NR
      if (!((s SUBSEP $2) in seen)) { seen[s SUBSEP $2]=1; sess[s]++ }
      if (!(s in order)) { order[s]=++n; names[n]=s }
    }
    $5=="resolved" { res[$7]=NR }
    $5=="escalation" { esc++ }
    END {
      for (i=1;i<=n;i++) {
        s=names[i]
        if (sess[s]<2) continue
        if ((s in res) && res[s]>lastn[s]) continue
        printf "SIGNATURE=%s\nCOUNT=%d\nSESSIONS=%d\nLAST=%s\n", s, cnt[s], sess[s], last[s]
        rec++
      }
      printf "RECURRING=%d\nESCALATIONS=%d\n", rec+0, esc+0
    }' "$file"
}

cmd_resolve() {
  local sig="" ref=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --signature) [ $# -ge 2 ] || squad_fail 2 "resolve: --signature needs a value"; sig="$2"; shift 2 ;;
      --ref) [ $# -ge 2 ] || squad_fail 2 "resolve: --ref needs a value"; ref="$2"; shift 2 ;;
      *) squad_fail 2 "resolve: unknown argument $1" ;;
    esac
  done
  [ -n "$sig" ] && [ -n "$ref" ] || squad_fail 2 "resolve: --signature and --ref required"
  local file; file="$(store_path)"
  [ -d "$(dirname "$file")" ] || squad_fail 10 "incident store directory missing"
  local ts comp
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  comp="${sig%%|*}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "" "" "script" "resolved" "$(safe_token "$comp")" \
    "$(printf '%s' "$sig" | tr '\t\r\n' '   ')" "" "$(clean "$ref" 120)" >> "$file" \
    || squad_fail 20 "cannot write $file"
  squad_emit OUTCOME applied || return $?
  squad_emit CHANGED yes
}

verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
  record) cmd_record "$@"; exit 0 ;;
  summary) cmd_summary "$@"; exit $? ;;
  resolve) cmd_resolve "$@"; exit $? ;;
  *) squad_fail 2 "usage: squad-incidents.sh record|summary|resolve ..." ;;
esac
