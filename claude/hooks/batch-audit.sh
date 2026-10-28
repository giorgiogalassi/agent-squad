#!/usr/bin/env bash
# batch-audit.sh -- close Chisel batch open questions and acceptance criteria
# once their issues are resolved (#363). Backs `lore audit`. Contract:
# SCRIPT_CONTRACT.md (KEY=value lines on stdout).
#
# Usage:
#   batch-audit.sh list  [--vault <dir>] [--project <name>]
#   batch-audit.sh close <batch-file> --line <n> --hash <hash> --as answered|open|obsolete
#                        [--decision "<YYYY-MM-DD> <title>"] [--vault <dir>] [--project <name>]
#
# list is read-only and makes no tracker call. An issue counts as resolved when
# progress.txt has `[KEY] (YYYY-MM-DD)? resolved` or a `[MERGE] ... closes KEY[, KEY]` line (KEY
# is the local ID or the tracker key from the batch Key mapping, `#` ignored);
# a batch with Status done|resolved|merged|closed|complete|executed resolves them all.
# Listed items: bullets under `Open questions` (batch or issue level) and under
# `### Acceptance criteria` of resolved issues, not already struck (`~~`).
# Batch-level questions are listed only when every issue of the batch is resolved.
#   AUDIT_ITEM=<batch>|<line>|<key>|<question|criterion>|<hash>|<text>   (one per item;
#     hash = cksum of the text, backslashes in text escaped)
#   AUDIT_COUNT=<n>  AUDIT_BATCHES=<n>  OUTCOME=unchanged  CHANGED=no
# close edits exactly one item, only on the user's answer:
#   answered  strike + pointer to a decisions.md entry (must exist, else exit 10:
#             record it with `lore decide` first)
#   obsolete  strike
#   open      strike and carry the text to status.md `## Next`
# and commits through squad_vault_commit. Emits OUTCOME= CHANGED= ITEM_LINE=.
# close refuses (exit 10) when the line no longer holds the listed item (hash).
# Exit: 0 ok, 2 usage, 10 precondition (bad or stale line, missing decision), 20 I/O.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=squad-common.sh
. "$HOOK_DIR/squad-common.sh"

VERB="${1:-}"; [ $# -gt 0 ] && shift
VAULT=""; PROJECT=""; BATCH=""; LINE=""; HASH=""; AS=""; DECISION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) [ $# -ge 2 ] || squad_fail 2 "--vault needs a value"; VAULT="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || squad_fail 2 "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --line) [ $# -ge 2 ] || squad_fail 2 "--line needs a value"; LINE="$2"; shift 2 ;;
    --hash) [ $# -ge 2 ] || squad_fail 2 "--hash needs a value"; HASH="$2"; shift 2 ;;
    --as) [ $# -ge 2 ] || squad_fail 2 "--as needs a value"; AS="$2"; shift 2 ;;
    --decision) [ $# -ge 2 ] || squad_fail 2 "--decision needs a value"; DECISION="$2"; shift 2 ;;
    -*) squad_fail 2 "unknown argument: $1" ;;
    *) [ -z "$BATCH" ] || squad_fail 2 "one batch file only"; BATCH="$1"; shift ;;
  esac
done
case "$VERB" in list|close) ;; *) squad_fail 2 "usage: batch-audit.sh list|close ..." ;; esac

if [ -z "$VAULT" ] || [ -z "$PROJECT" ]; then
  squad_resolve || exit 20
  [ -n "$VAULT" ] || VAULT="$VAULT_PATH"
  [ -n "$PROJECT" ] || PROJECT="${DISPLAY_NAME:-}"
fi
[ -n "$PROJECT" ] || squad_fail 20 "no project name resolved"
SQ="$VAULT/projects/$PROJECT/.squad"
ISSUES="$SQ/issues"
PROGRESS="$SQ/progress.txt"

# Resolved keys (one per line, '#' stripped) from progress.txt.
resolved_keys() {
  [ -f "$PROGRESS" ] || return 0
  awk '
    function iskey(t) { return (t ~ /^#?[0-9]+$/ || t ~ /^[A-Za-z][A-Za-z0-9]*-[0-9]+$/) }
    /^\[MERGE\]/ { s=$0
      while (match(s, /(^|[^A-Za-z])[Cc]loses[ \t]+/)) {
        s=substr(s, RSTART+RLENGTH)
        while (match(s, /^#?[A-Za-z0-9_-]+/)) {
          k=substr(s, 1, RLENGTH)
          if (!iskey(k)) break
          sub(/^#/, "", k); print k
          s=substr(s, RLENGTH+1)
          if (!match(s, /^[ \t]*(,|&|and)[ \t]*/)) break
          s=substr(s, RLENGTH+1)
        } }
      next }
    /^\[(#?[0-9]+|[A-Za-z][A-Za-z0-9]*-[0-9]+)\]( [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])? resolved([ .,]|$)/ {
      k=$0; sub(/^\[/, "", k); sub(/\].*/, "", k); sub(/^#/, "", k); print k }
  ' "$PROGRESS"
}

# item_hash <text>: short checksum that ties a close to the item listed.
item_hash() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

# audit_one <batch-file> <keys-file>: emit AUDIT_ITEM lines for one batch.
audit_one() {
  awk -v bn="$(basename "$1")" -v keysf="$2" '
    function strip(s) { sub(/^#/, "", s); return s }
    BEGIN { while ((getline k < keysf) > 0) res[k]=1 }
    { lines[NR]=$0 }
    END {
      n=NR; st=""; inmap=0
      for (i=1;i<=n;i++) {
        l=lines[i]
        if (l ~ /^Status:/) { st=l; sub(/^Status:[ \t]*/, "", st); st=tolower(st) }
        if (l ~ /^## Key mapping/) { inmap=1; continue }
        if (l ~ /^## /) inmap=0
        if (inmap && l ~ /^\|/) {
          split(l, c, "|"); a=c[2]; b=c[3]
          gsub(/[ \t]/, "", a); gsub(/[ \t]/, "", b)
          if (a != "" && a !~ /^-+$/ && a != "Local" && b != "" && b != "—" && b != "-") tr[a]=strip(b)
        }
      }
      alldone = (st ~ /^(done|resolved|merged|closed|complete|executed)/)
      key=""; sect=""; nissue=0; unres=0; nitems=0
      for (i=1;i<=n;i++) {
        l=lines[i]
        if (l ~ /^## /) {
          sect=""; key=""
          if (l ~ /^## [A-Za-z][A-Za-z0-9]*-[0-9]+:/) {
            key=l; sub(/^## /, "", key); sub(/:.*/, "", key)
            if (l ~ /\(parent\)[ \t]*$/) key=""
            else { nissue++; ok = alldone || (key in res) || ((key in tr) && (tr[key] in res)); if (!ok) unres++; isres[key]=ok
                   if (key in tr) disp[key]=key; }
          } else if (tolower(l) ~ /^## open questions/) sect="oq"
          continue
        }
        if (l ~ /^### /) {
          if (tolower(l) ~ /^### open questions/) sect="oq"
          else if (tolower(l) ~ /^### acceptance criteri/) sect="ac"
          else sect=""
          continue
        }
        if (sect != "" && l ~ /^[ \t]*[-*] / && l !~ /~~/) {
          t=l; sub(/^[ \t]*[-*] +(\[[ xX]\] +)?/, "", t)
          nitems++; ik[nitems]=key; ikind[nitems]=(sect=="oq" ? "question" : "criterion"); iline[nitems]=i; itext[nitems]=t
          isect[nitems]=sect
        }
      }
      for (j=1;j<=nitems;j++) {
        if (ik[j] == "") { if (!(nissue > 0 && unres == 0)) continue; kk="batch" }
        else { if (!isres[ik[j]]) continue; kk=ik[j] }
        if (kk != "batch" && (kk in tr)) kk=kk "/" tr[kk]
        print "AUDIT_ITEM=" bn "|" iline[j] "|" kk "|" ikind[j] "|" itext[j]
      }
    }' "$1"
}

if [ "$VERB" = list ]; then
  KF="$(mktemp "${TMPDIR:-/tmp}/batch-audit.XXXXXX")" || squad_fail 20 "mktemp failed"
  trap 'rm -f "$KF"' EXIT
  resolved_keys > "$KF"
  COUNT=0; NB=0
  for f in "$ISSUES"/batch-*.md; do
    [ -f "$f" ] || continue
    out="$(audit_one "$f" "$KF" | while IFS='|' read -r b l k kind text; do
      printf 'AUDIT_ITEM=%s|%s|%s|%s|%s|%s\n' "${b#AUDIT_ITEM=}" "$l" "$k" "$kind" "$(item_hash "$text")" "$(printf '%s' "$text" | sed 's/\\/\\\\/g')"
    done)"
    [ -n "$out" ] || continue
    NB=$((NB+1)); COUNT=$((COUNT + $(printf '%s\n' "$out" | wc -l)))
    printf '%s\n' "$out"
  done
  echo "AUDIT_COUNT=$COUNT"; echo "AUDIT_BATCHES=$NB"; echo "OUTCOME=unchanged"; echo "CHANGED=no"
  exit 0
fi

# ---- close
[ -n "$BATCH" ] && [ -n "$LINE" ] && [ -n "$HASH" ] && [ -n "$AS" ] || squad_fail 2 "usage: batch-audit.sh close <batch-file> --line <n> --hash <hash> --as answered|open|obsolete [--decision ...]"
case "$LINE" in ''|*[!0-9]*) squad_fail 2 "--line must be a number" ;; esac
case "$AS" in answered|open|obsolete) ;; *) squad_fail 2 "--as must be answered, open or obsolete" ;; esac
case "$BATCH$DECISION" in *$'\n'*) squad_fail 2 "newlines are not allowed in arguments" ;; esac
case "$BATCH" in */*) F="$BATCH" ;; *) F="$ISSUES/$BATCH" ;; esac
[ -f "$F" ] || squad_fail 10 "batch file not found: $F"
case "$F" in "$ISSUES"/batch-*.md) ;; *) squad_fail 10 "not a batch file under $ISSUES" ;; esac

cur="$(sed -n "${LINE}p" "$F")"
case "$cur" in
  *'~~'*) squad_emit OUTCOME unchanged; squad_emit CHANGED no; squad_emit ITEM_LINE "$LINE"; exit 0 ;;
  [[:space:]]*"- "*|"- "*|[[:space:]]*"* "*|"* "*) ;;
  *) squad_fail 10 "line $LINE is not a list item" ;;
esac

want="$(printf '%s' "$cur" | sed -E 's/^[[:space:]]*[-*] +(\[[ xX]\] +)?//')"
[ "$(item_hash "$want")" = "$HASH" ] || squad_fail 10 "line $LINE changed since list; re-run list"

PTR=""
case "$AS" in
  answered)
    [ -n "$DECISION" ] || squad_fail 10 "answered needs --decision \"<YYYY-MM-DD> <title>\"; record it with lore decide first"
    DF="$VAULT/projects/$PROJECT/decisions.md"
    [ -f "$DF" ] && grep -E '^## \[' "$DF" | sed -E 's/^## (\[[0-9-]+\]) (\[rule\] )?/\1 /; s/[[:space:]]+$//' | grep -qxF -- "[${DECISION%% *}] ${DECISION#* }" \
      || squad_fail 10 "no decisions.md entry \"$DECISION\"; record it with lore decide first"
    PTR=" (answered: decisions.md [${DECISION%% *}] ${DECISION#* })" ;;
  obsolete) PTR=" (obsolete)" ;;
  open) PTR=" (still open: carried to status.md Next)" ;;
esac

indent="$(printf '%s' "$cur" | sed -E 's/^([[:space:]]*[-*] ).*/\1/')"
text="${cur#"$indent"}"
TMP="$F.tmp.$$"
# ENVIRON keeps the text byte-exact (awk -v would expand backslash escapes)
BA_PRE="$indent" BA_TXT="$text" BA_PTR="$PTR" awk -v n="$LINE" \
  'NR==n { print ENVIRON["BA_PRE"] "~~" ENVIRON["BA_TXT"] "~~" ENVIRON["BA_PTR"]; next } { print }' "$F" > "$TMP" && mv "$TMP" "$F" || { rm -f "$TMP"; squad_fail 20 "cannot write $F"; }

PATHS="projects/$PROJECT/.squad/issues/$(basename "$F")"
if [ "$AS" = open ]; then
  ST="$VAULT/projects/$PROJECT/status.md"
  item="- $text (from $(basename "$F"))"
  if [ -f "$ST" ] && grep -q '^## Next' "$ST"; then
    BA_ITEM="$item" awk '{ print } /^## Next/ && !d { print ENVIRON["BA_ITEM"]; d=1 }' "$ST" > "$ST.tmp.$$" && mv "$ST.tmp.$$" "$ST" || squad_fail 20 "cannot write $ST"
  elif [ -f "$ST" ]; then
    printf '\n## Next\n%s\n' "$item" >> "$ST" || squad_fail 20 "cannot write $ST"
  else
    printf '## Next\n%s\n' "$item" > "$ST" || squad_fail 20 "cannot write $ST"
  fi
  PATHS="$PATHS projects/$PROJECT/status.md"
fi
# shellcheck disable=SC2086
squad_vault_commit "$VAULT" "$PROJECT" "[lore] $(squad_public_name "$VAULT" "$PROJECT") audit $(date '+%Y-%m-%d %H:%M')" $PATHS
squad_emit OUTCOME applied; squad_emit CHANGED yes; squad_emit ITEM_LINE "$LINE"
exit 0
