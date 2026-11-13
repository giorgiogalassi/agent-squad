#!/usr/bin/env bash
# squad-progress.sh -- the squad's vault state writes: progress.txt, session.log and
# ralph-run.md. Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq.
#
# Usage:
#   squad-progress.sh append --issue <ID> --line <text>   progress.txt: "[ID] <text>"
#   squad-progress.sh log --source <name> --line <text>  session.log "[ts] [name] <text>" via `lore event` (folded later)
#   squad-progress.sh run-write --from <file>             replace ralph-run.md
#   squad-progress.sh run-row --issue <ID> --set <Column>=<value> [--set ...]
#   squad-progress.sh run-status --value <Status>         set the "Status:" header line
#   squad-progress.sh where --file progress|log|run|env       print the current copy's path
#
# Working state (progress.txt, ralph-run.md, cody-checkpoint.env) is written directly
# and is never committed here: the next `lore fold` snapshot-commits it, so a reader
# sees it at once (read-after-write). In a PR-mode vault it lives in this project's
# session worktree, never in the vault checkout (nothing of ours is dirty there for
# another session to carry or trip over); `where` returns that path. Durable history
# (`log`) is an event, visible in session.log after the next fold.
# An `append` whose text is `resolved. PR: #N ...` is skipped when the file
# already holds a `[ID] [date] resolved. PR: #N` line (dated or not), whoever wrote it.
# Emits: OUTCOME=applied|unchanged, CHANGED=yes|no (where: FILE=<path>).
# Exit: 0 ok, 2 usage, 10 precondition (no ralph-run.md / row / column), 20 resolve or I/O failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
[ -n "$VERB" ] || squad_fail 2 "usage: squad-progress.sh append|log|run-write|run-row|run-status|where ..."
shift
ISSUE=""; LINE=""; SOURCE=""; FROM=""; VALUE=""; WHICH=""; SETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --issue|--line|--source|--from|--value|--file|--set)
      [ $# -ge 2 ] || squad_fail 2 "$1 requires a value"
      case "$1" in
        --issue) ISSUE="$2" ;; --line) LINE="$2" ;; --source) SOURCE="$2" ;;
        --from) FROM="$2" ;; --value) VALUE="$2" ;; --file) WHICH="$2" ;;
        --set) SETS+=("$2") ;;
      esac
      shift 2 ;;
    *) squad_fail 2 "unknown argument '$1'" ;;
  esac
done
case "$VERB" in append|log|run-write|run-row|run-status|where) ;; *) squad_fail 2 "unknown verb '$VERB'" ;; esac

squad_resolve || squad_fail 20 "path resolution failed"
V="$VAULT_PATH"; PROJ="${DISPLAY_NAME:-$(basename "$PROJECT_ROOT")}"
# No project (#441): exit 10, never a usage error from a writer further down.
[ -n "$PROJ" ] || squad_fail 10 "no project mapped for ${PROJECT_ROOT:-$PWD}; run /seed or /lore start"
LORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lore"
REL_DIR="projects/$PROJ/$(squad_state_name "$V")"

# W: where working state lives (squad_vault_wroot). A PR-mode vault: this project's
# session worktree, on or off the default branch, so the vault checkout never holds
# our uncommitted files. Direct-mode/local-only: the vault, refused (exit 10) off its
# default branch. `where` only reads: it falls back to the vault on a refusal.
W="$V"
if ! squad_local_only "$V" "$PROJ" 2>/dev/null; then
  W="$(squad_vault_wroot "$V" "$PROJ")"; _wrc=$?
  if [ "$VERB" = where ]; then
    { [ "$_wrc" = 0 ] && [ -n "$W" ]; } || W="$V"
  else
    [ "$_wrc" = 10 ] && squad_fail 10 "vault checkout is not on its default branch and the vault is in direct mode; nothing written"
    [ "$_wrc" = 0 ] && [ -n "$W" ] || squad_fail 20 "vault worktree failed"
  fi
fi

relof() {
  case "$1" in
    progress) echo "$REL_DIR/progress.txt" ;; env) echo "$REL_DIR/cody-checkpoint.env" ;; log) echo "$REL_DIR/session.log" ;;
    run) echo "$REL_DIR/ralph-run.md" ;; *) return 1 ;;
  esac
}
# current <rel>: the copy holding the latest content: the session worktree's in a
# PR-mode vault (the vault checkout's committed copy only while the worktree has none,
# and never off the default branch: that checkout is another session's), else the vault's.
current() {
  if [ "$W" != "$V" ] && { [ -f "$W/$1" ] || squad_vault_offdefault "$V"; }; then
    printf '%s' "$W/$1"; return
  fi
  printf '%s' "$V/$1"
}
# stage <rel>: make $W/<rel> exist, holding the current content, ready to edit.
stage() {
  mkdir -p "$(dirname "$W/$1")" || return 1
  if [ ! -f "$W/$1" ]; then
    if [ "$W" != "$V" ] && [ -f "$V/$1" ] && ! squad_vault_offdefault "$V"; then cp "$V/$1" "$W/$1" || return 1
    else : > "$W/$1"; fi
  fi
}
done_changed() { squad_emit OUTCOME applied; squad_emit CHANGED yes; exit 0; }
unchanged() { squad_emit OUTCOME unchanged; squad_emit CHANGED no; exit 0; }
norm_id() { local i="${1#\[}"; i="${i%\]}"; i="${i#\#}"; printf '%s' "$i"; }
esc_re() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/-]/\\&/g'; }

case "$VERB" in
  where)
    REL="$(relof "$WHICH")" || squad_fail 2 "where requires --file progress|log|run|env"
    squad_emit FILE "$(current "$REL")"; squad_emit OUTCOME unchanged; squad_emit CHANGED no; exit 0 ;;

  append)
    [ -n "$ISSUE" ] && [ -n "$LINE" ] || squad_fail 2 "append requires --issue and --line"
    REL="$(relof progress)"; ID="$(norm_id "$ISSUE")"; CUR="$(current "$REL")"
    # Callers pass lines with or without the leading "[ID] ": never doubled.
    case "$LINE" in "[$ISSUE] "*|"[#$ID] "*|"[$ID] "*) LINE="${LINE#* }" ;; esac
    OUTLINE="[$ISSUE] $LINE"; case "$ISSUE" in \[*) OUTLINE="$ISSUE $LINE" ;; esac
    if [ -f "$CUR" ]; then
      PRN="$(printf '%s' "$LINE" | sed -n 's/^\([0-9-]\{10\} \)\{0,1\}resolved\. PR: #\([0-9][0-9]*\).*/\2/p')"
      if [ -n "$PRN" ]; then
        grep -Eq "^\[#?$(esc_re "$ID")\] ([0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9:]+)? )?resolved\. PR: #$PRN( |\.|\$)" "$CUR" && unchanged
      fi
      grep -qxF -- "$OUTLINE" "$CUR" && unchanged
    fi
    stage "$REL" || squad_fail 20 "cannot stage $REL"
    # A file without a final newline would glue the new line onto the last one.
    [ -s "$W/$REL" ] && [ -n "$(tail -c 1 "$W/$REL")" ] && echo >> "$W/$REL"
    printf '%s\n' "$OUTLINE" >> "$W/$REL" || squad_fail 20 "cannot write $REL"
    done_changed ;;

  log)
    [ -n "$LINE" ] || squad_fail 2 "log requires --line"
    [ -n "$SOURCE" ] || squad_fail 2 "log requires --source <name> (the skill or agent writing the line)"
    # A non-git root is not a detached HEAD (#466): "branch: detached" becomes "branch: none".
    case "$LINE" in
      *"branch: detached"*)
        git -C "${PROJECT_ROOT:-$PWD}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
          || LINE="${LINE/branch: detached/branch: none}" ;;
    esac
    _rc=0
    SECOND_BRAIN_PATH="$V" bash "$LORE" event --vault "$V" --project "$PROJ" --source "$SOURCE" --kind log --line "$LINE" >/dev/null || _rc=$?
    [ "$_rc" = 0 ] || squad_fail "$([ "$_rc" = 10 ] && echo 10 || echo 20)" "log event not written (lore event exit $_rc)"
    done_changed ;;

  run-write)
    [ -n "$FROM" ] || squad_fail 2 "run-write requires --from"
    [ -f "$FROM" ] && [ -r "$FROM" ] || squad_fail 10 "source file missing or unreadable: $FROM"
    REL="$(relof run)"; CUR="$(current "$REL")"
    [ -f "$CUR" ] && cmp -s "$CUR" "$FROM" && unchanged
    mkdir -p "$(dirname "$W/$REL")" && cp "$FROM" "$W/$REL" || squad_fail 20 "cannot write $REL"
    done_changed ;;

  run-status)
    [ -n "$VALUE" ] || squad_fail 2 "run-status requires --value"
    REL="$(relof run)"; CUR="$(current "$REL")"
    [ -f "$CUR" ] || squad_fail 10 "ralph-run.md does not exist"
    grep -q '^Status:' "$CUR" || squad_fail 10 "ralph-run.md has no Status line"
    grep -qxF "Status: $VALUE" "$CUR" && unchanged
    stage "$REL" || squad_fail 20 "cannot stage $REL"
    T="$W/$REL.tmp.$$"
    sed "s|^Status:.*|Status: $(printf '%s' "$VALUE" | sed 's/[\\&|]/\\&/g')|" "$W/$REL" > "$T" && mv "$T" "$W/$REL" || squad_fail 20 "cannot write $REL"
    done_changed ;;

  run-row)
    [ -n "$ISSUE" ] && [ "${#SETS[@]}" -gt 0 ] || squad_fail 2 "run-row requires --issue and at least one --set"
    REL="$(relof run)"; CUR="$(current "$REL")"; ID="$(norm_id "$ISSUE")"
    [ -f "$CUR" ] || squad_fail 10 "ralph-run.md does not exist"
    stage "$REL" || squad_fail 20 "cannot stage $REL"
    T="$W/$REL.tmp.$$"; cp "$W/$REL" "$T" || squad_fail 20 "cannot write $REL"
    for kv in "${SETS[@]}"; do
      COL="${kv%%=*}"; VAL="${kv#*=}"
      case "$kv" in *=*) ;; *) rm -f "$T"; squad_fail 2 "--set needs Column=value" ;; esac
      case "$VAL" in *"
"*) rm -f "$T"; squad_fail 2 "--set value cannot contain a newline" ;; esac
      case "$VAL" in *'|'*) rm -f "$T"; squad_fail 2 "--set value cannot contain '|'" ;; esac
      # An older table has no Contests column (#486): add it (default 0/-) so a run
      # started before the column existed can still be resumed and updated.
      if [ "$COL" = Contests ] && ! grep -Eq '^\|.*\| *Contests *\|' "$T"; then
        awk '
          /^\|/ && !h { sub(/[ \t]*$/, ""); print $0 " Contests |"; h = 1; next }
          /^\|[-| ]+\|[ \t]*$/ { sub(/[ \t]*$/, ""); print $0 "----------|"; next }
          /^\|/ { sub(/[ \t]*$/, ""); print $0 " 0/- |"; next }
          { print }' "$T" > "$T.o" && mv "$T.o" "$T" || { rm -f "$T" "$T.o"; squad_fail 20 "cannot write $REL"; }
      fi
      # ENVIRON, not -v: -v interprets backslash escapes in the value.
      SQUAD_COL="$COL" SQUAD_VAL="$VAL" SQUAD_ID="#$ID" awk '
        BEGIN { col = ENVIRON["SQUAD_COL"]; val = ENVIRON["SQUAD_VAL"]; id = ENVIRON["SQUAD_ID"] }
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^\|/ {
          n = split($0, c, "|")
          if (!idx) { for (i = 2; i < n; i++) if (trim(c[i]) == col) idx = i; if (idx) { print; next } }
          if (idx && trim(c[2]) == id) {
            out = "|"; for (i = 2; i < n; i++) out = out " " (i == idx ? val : trim(c[i])) " |"
            print out; hit = 1; next
          }
        }
        { print }
        END { exit (idx ? (hit ? 0 : 3) : 4) }' "$T" > "$T.o"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        rm -f "$T" "$T.o"
        [ "$rc" = 4 ] && squad_fail 10 "ralph-run.md has no column '$COL'"
        squad_fail 10 "ralph-run.md has no row for #$ID"
      fi
      mv "$T.o" "$T"
    done
    if cmp -s "$T" "$CUR"; then rm -f "$T"; [ "$CUR" = "$W/$REL" ] || rm -f "$W/$REL"; unchanged; fi
    mv "$T" "$W/$REL" || squad_fail 20 "cannot write $REL"
    done_changed ;;
esac
