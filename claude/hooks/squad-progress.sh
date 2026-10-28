#!/usr/bin/env bash
# squad-progress.sh -- Ralph's vault state writes: progress.txt, session.log and
# ralph-run.md. Contract: SCRIPT_CONTRACT.md. Bash 3.2 compatible; no jq.
#
# Usage:
#   squad-progress.sh append --issue <ID> --line <text>   progress.txt: "[ID] <text>"
#   squad-progress.sh log --line <text> [--skill ralph]   session.log: "[YYYY-MM-DD HH:MM] [skill] <text>"
#   squad-progress.sh run-write --from <file>             replace ralph-run.md
#   squad-progress.sh run-row --issue <ID> --set <Column>=<value> [--set ...]
#   squad-progress.sh run-status --value <Status>         set the "Status:" header line
#   squad-progress.sh where --file progress|log|run       print the current copy's path
#
# Writes go through squad_vault_commit (lore branch in a PR-mode vault, a commit
# on main otherwise). Reads use the same copy: the lore worktree's when it exists.
# An `append` whose text is `resolved. PR: #N ...` is skipped when the file
# already holds a `[ID] [date] resolved. PR: #N` line (dated or not), whoever wrote it.
# Emits: OUTCOME=applied|unchanged, CHANGED=yes|no (where: FILE=<path>).
# Exit: 0 ok, 2 usage, 10 precondition (no ralph-run.md / row / column), 20 resolve or I/O failure.

. "$(dirname "${BASH_SOURCE[0]}")/squad-common.sh"

VERB="${1:-}"
[ -n "$VERB" ] || squad_fail 2 "usage: squad-progress.sh append|log|run-write|run-row|run-status|where ..."
shift
ISSUE=""; LINE=""; SKILL=ralph; FROM=""; VALUE=""; WHICH=""; SETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --issue|--line|--skill|--from|--value|--file|--set)
      [ $# -ge 2 ] || squad_fail 2 "$1 requires a value"
      case "$1" in
        --issue) ISSUE="$2" ;; --line) LINE="$2" ;; --skill) SKILL="$2" ;;
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
REL_DIR="projects/$PROJ/.squad"

relof() {
  case "$1" in
    progress) echo "$REL_DIR/progress.txt" ;; log) echo "$REL_DIR/session.log" ;;
    run) echo "$REL_DIR/ralph-run.md" ;; *) return 1 ;;
  esac
}
# current <rel>: the copy holding the latest content. In a PR-mode vault the
# written files live on the lore worktree and main is reset to HEAD.
current() {
  local wt
  if [ -d "$V/.git" ] || git -C "$V" rev-parse --git-dir >/dev/null 2>&1; then
    if ! squad_local_only "$V" "$PROJ" && squad_vault_pr_mode "$V"; then
      wt="$(squad_vault_wt "$V" "$PROJ" 2>/dev/null)" && [ -f "$wt/$1" ] && { printf '%s' "$wt/$1"; return; }
    fi
  fi
  printf '%s' "$V/$1"
}
# stage <rel>: make the vault path hold the current content, ready to edit.
stage() {
  local cur base; cur="$(current "$1")"
  mkdir -p "$(dirname "$V/$1")" || return 1
  if [ "$cur" != "$V/$1" ]; then
    base="$V/$1.base.$$"
    if [ -f "$V/$1" ] && [ -f "$cur" ] && ! git -C "$V" diff --quiet HEAD -- "$1" 2>/dev/null; then
      # Vault main holds an uncommitted write (async hook): merge, never overwrite.
      git -C "$V" show "HEAD:$1" > "$base" 2>/dev/null || : > "$base"
      git merge-file -p --union "$cur" "$base" "$V/$1" > "$V/$1.m" 2>/dev/null; mv "$V/$1.m" "$V/$1"
      rm -f "$base"
    else
      cp "$cur" "$V/$1" 2>/dev/null || : > "$V/$1"
    fi
  fi
  [ -f "$V/$1" ] || : > "$V/$1"
}
commit() { squad_vault_commit "$V" "$PROJ" "lore: ralph state $(squad_public_name "$V" "$PROJ")" "$1"; }
done_changed() { squad_emit OUTCOME applied; squad_emit CHANGED yes; exit 0; }
unchanged() { squad_emit OUTCOME unchanged; squad_emit CHANGED no; exit 0; }
norm_id() { local i="${1#\[}"; i="${i%\]}"; i="${i#\#}"; printf '%s' "$i"; }
esc_re() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/-]/\\&/g'; }

case "$VERB" in
  where)
    REL="$(relof "$WHICH")" || squad_fail 2 "where requires --file progress|log|run"
    squad_emit FILE "$(current "$REL")"; squad_emit OUTCOME unchanged; squad_emit CHANGED no; exit 0 ;;

  append)
    [ -n "$ISSUE" ] && [ -n "$LINE" ] || squad_fail 2 "append requires --issue and --line"
    REL="$(relof progress)"; ID="$(norm_id "$ISSUE")"; CUR="$(current "$REL")"
    OUTLINE="[$ISSUE] $LINE"; case "$ISSUE" in \[*) OUTLINE="$ISSUE $LINE" ;; esac
    if [ -f "$CUR" ]; then
      PRN="$(printf '%s' "$LINE" | sed -n 's/^resolved\. PR: #\([0-9][0-9]*\).*/\1/p')"
      if [ -n "$PRN" ]; then
        grep -Eq "^\[#?$(esc_re "$ID")\] ([0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9:]+)? )?resolved\. PR: #$PRN( |\.|\$)" "$CUR" && unchanged
      fi
      grep -qxF -- "$OUTLINE" "$CUR" && unchanged
    fi
    stage "$REL" || squad_fail 20 "cannot stage $REL"
    # A file without a final newline would glue the new line onto the last one.
    [ -s "$V/$REL" ] && [ -n "$(tail -c 1 "$V/$REL")" ] && echo >> "$V/$REL"
    printf '%s\n' "$OUTLINE" >> "$V/$REL" || squad_fail 20 "cannot write $REL"
    commit "$REL"; done_changed ;;

  log)
    [ -n "$LINE" ] || squad_fail 2 "log requires --line"
    REL="$(relof log)"
    stage "$REL" || squad_fail 20 "cannot stage $REL"
    [ -s "$V/$REL" ] && [ -n "$(tail -c 1 "$V/$REL")" ] && echo >> "$V/$REL"
    printf '[%s] [%s] %s\n' "$(date "+%Y-%m-%d %H:%M")" "$SKILL" "$LINE" >> "$V/$REL" || squad_fail 20 "cannot write $REL"
    commit "$REL"; done_changed ;;

  run-write)
    [ -n "$FROM" ] || squad_fail 2 "run-write requires --from"
    [ -f "$FROM" ] && [ -r "$FROM" ] || squad_fail 10 "source file missing or unreadable: $FROM"
    REL="$(relof run)"; CUR="$(current "$REL")"
    [ -f "$CUR" ] && cmp -s "$CUR" "$FROM" && unchanged
    mkdir -p "$(dirname "$V/$REL")" && cp "$FROM" "$V/$REL" || squad_fail 20 "cannot write $REL"
    commit "$REL"; done_changed ;;

  run-status)
    [ -n "$VALUE" ] || squad_fail 2 "run-status requires --value"
    REL="$(relof run)"; CUR="$(current "$REL")"
    [ -f "$CUR" ] || squad_fail 10 "ralph-run.md does not exist"
    grep -q '^Status:' "$CUR" || squad_fail 10 "ralph-run.md has no Status line"
    grep -qxF "Status: $VALUE" "$CUR" && unchanged
    stage "$REL" || squad_fail 20 "cannot stage $REL"
    T="$V/$REL.tmp.$$"
    sed "s|^Status:.*|Status: $(printf '%s' "$VALUE" | sed 's/[\\&|]/\\&/g')|" "$V/$REL" > "$T" && mv "$T" "$V/$REL" || squad_fail 20 "cannot write $REL"
    commit "$REL"; done_changed ;;

  run-row)
    [ -n "$ISSUE" ] && [ "${#SETS[@]}" -gt 0 ] || squad_fail 2 "run-row requires --issue and at least one --set"
    REL="$(relof run)"; CUR="$(current "$REL")"; ID="$(norm_id "$ISSUE")"
    [ -f "$CUR" ] || squad_fail 10 "ralph-run.md does not exist"
    stage "$REL" || squad_fail 20 "cannot stage $REL"
    T="$V/$REL.tmp.$$"; cp "$V/$REL" "$T" || squad_fail 20 "cannot write $REL"
    for kv in "${SETS[@]}"; do
      COL="${kv%%=*}"; VAL="${kv#*=}"
      case "$kv" in *=*) ;; *) rm -f "$T"; squad_fail 2 "--set needs Column=value" ;; esac
      case "$VAL" in *"
"*) rm -f "$T"; squad_fail 2 "--set value cannot contain a newline" ;; esac
      case "$VAL" in *'|'*) rm -f "$T"; squad_fail 2 "--set value cannot contain '|'" ;; esac
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
    if cmp -s "$T" "$CUR"; then rm -f "$T"; [ "$CUR" = "$V/$REL" ] || rm -f "$V/$REL"; unchanged; fi
    mv "$T" "$V/$REL" || squad_fail 20 "cannot write $REL"
    commit "$REL"; done_changed ;;
esac
