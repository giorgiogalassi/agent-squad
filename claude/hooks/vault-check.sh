#!/usr/bin/env bash
# vault-check.sh -- one implementation of the vault health checks (#333),
# called by the SessionStart orientation (lore-orient.sh, via `render`) and by
# `lore check [--fix] [--all]`. Contract: SCRIPT_CONTRACT.md (stdout is
# KEY=value lines only, one per finding; exit 0 on success even with
# findings, 2 usage). Exception: like decisions-lint.sh, check emits finding
# keys only, no OUTCOME=/CHANGED=; an empty stdout means clean.
#
# Usage:
#   vault-check.sh check [--fix] [--all] [--vault-wide] [--vault <dir>]
#                        [--project <name>] [--context repo]
#   vault-check.sh render                  (KEY=value on stdin -> text block)
#
# Without --vault/--project the current project is resolved with
# path-resolve.sh. Read-only unless --fix. --fix applies only mechanical
# repairs and never touches decision text: INDEX row date, INDEX row added,
# orphaned session starts closed as "closed without teardown", and inverse
# markers through `decisions-lint.sh fix`. Each repair is a function
# (index_set_row, close_orphans) so the INDEX writer (#328) and the session
# closer (#329) can source this file and call the same code.
# --all checks every project plus the vault-wide pass; --vault-wide runs only
# the vault-wide pass (the orientation does this when the vault is small).
#
# Finding keys (project scope, preceded by VAULT_SCOPE=<project>):
#   DECISIONS_*                 passed through from decisions-lint.sh check
#   STATUS_FILE=missing
#   STATUS_STALE=<date>         Last updated older than 7 days
#   STATUS_CHECKPOINT_NEWER=<checkpoint> > <updated>
#   STATUS_OVER_BUDGET=<words>  over 300 words
#   INDEX_FILE=missing
#   INDEX_NO_ROW=<project>
#   INDEX_ROW_BEHIND=<row date> < <status date>
#   SESSION_UNCLOSED=<n> oldest <date> <tag>
#   JOURNAL_POINTER_MISSING=<project>   context: repo only (#330)
# Vault scope (preceded by VAULT_SCOPE=vault):
#   VAULT_STRAY_ROOT=<file>
#   VAULT_PROJECT_NO_INDEX=<project>
# Fix results: FIXED_INDEX_ROW_DATE, FIXED_INDEX_ROW_ADDED,
#   FIXED_SESSION_CLOSED=<n> <tag>, DECISIONS_APPLIED_INVERSE.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KNOWN_ROOT_FILES=" CLAUDE.md INDEX.md lore-config.json squad-incidents.tsv "
STATUS_WORDS_MAX=300

die() { echo "$1" >&2; exit "${2:-2}"; }

now_ts() { echo "${VAULT_CHECK_NOW:-$(date '+%Y-%m-%d %H:%M')}"; }
week_ago() {
  if [ -n "${VAULT_CHECK_NOW:-}" ]; then
    date -j -v-7d -f '%Y-%m-%d %H:%M' "$VAULT_CHECK_NOW" '+%Y-%m-%d %H:%M' 2>/dev/null \
      || date -d "${VAULT_CHECK_NOW} 7 days ago" '+%Y-%m-%d %H:%M' 2>/dev/null
  else
    date -v-7d '+%Y-%m-%d %H:%M' 2>/dev/null || date -d '7 days ago' '+%Y-%m-%d %H:%M' 2>/dev/null
  fi
}

# ---- reusable repairs (also the entry points for #328 and #329) -----------

# index_set_row <index.md> <project> <status> <date> [set-status]
# With set-status=1 (SessionEnd, #328) an existing row also takes <status> when
# its current status is empty, active or paused (a hand-set blocked or done
# stays), and an up-to-date date no longer short-circuits a status change.
# Prints CHANGED/ADDED/NONE-style result on stdout: "date", "added" or "".
# Updates the date of the project's row when behind, or appends a row at the
# end of the Projects table when there is none. Never touches other rows.
index_set_row() {
  local idx="$1" name="$2" st="$3" date="$4" setst="${5:-0}" tmp res
  [ -f "$idx" ] || return 0
  tmp="$idx.vc.$$"
  res="$(IDX_NAME="$name" IDX_ST="$st" IDX_DATE="$date" IDX_SET="$setst" awk -v out="$tmp" '
    BEGIN { name = ENVIRON["IDX_NAME"]; st = ENVIRON["IDX_ST"]; date = ENVIRON["IDX_DATE"]; setst = ENVIRON["IDX_SET"]
            key = "[[projects/" name "/status"; res = "" }
    { lines[++n] = $0
      if ($0 ~ /^## /) insec = ($0 == "## Projects")
      if (insec && substr($0, 1, 1) == "|") last = n
      if (insec && index($0, key) > 0 && substr($0, 1, 1) == "|") {
        row = n; c = split($0, f, "|"); old = f[c - 1]; gsub(/^ +| +$/, "", old)
        ost = f[c - 2]; gsub(/^ +| +$/, "", ost) } }
    END {
      if (row) {
        chgd = (old < date); chgs = (setst == 1 && ost != st && (ost == "" || ost == "active" || ost == "paused"))
        if (!chgd && !chgs) exit
        l = lines[row]; c = split(l, f, "|")
        if (chgd) f[c - 1] = " " date " "
        if (chgs) f[c - 2] = " " st " "
        s = ""; for (i = 2; i < c; i++) s = s "|" f[i]
        lines[row] = s "|"; res = (chgd ? "date" : "status")
      } else if (last) {
        new = "| [[projects/" name "/status\\|" name "]] | " st " | " date " |"
        for (i = n; i > last; i--) lines[i + 1] = lines[i]
        lines[last + 1] = new; n++; res = "added"
      } else exit
      for (i = 1; i <= n; i++) print lines[i] > out
      print res
    }' "$idx")" || res=""
  if [ -n "$res" ] && [ -s "$tmp" ]; then mv "$tmp" "$idx"; else rm -f "$tmp"; res=""; fi
  echo "$res"
}

# index_set_active <index.md> <project> [<date>]: points the "## Active project"
# section at <project> (Name, Status wikilink, and Last worked when the line
# exists). Replaces those lines only; prints "set" when the file changed.
index_set_active() {
  local idx="$1" name="$2" date="${3:-}" tmp
  [ -f "$idx" ] || return 0
  grep -q '^## Active project' "$idx" || return 0
  tmp="$idx.va.$$"
  IDX_NAME="$name" IDX_DATE="$date" awk '
    BEGIN { name = ENVIRON["IDX_NAME"]; date = ENVIRON["IDX_DATE"] }
    /^## / { insec = ($0 == "## Active project") }
    insec && /^Name:/ { print "Name: " name; next }
    insec && /^Status:/ { print "Status: [[projects/" name "/status]]"; next }
    insec && date != "" && /^Last worked:/ { print "Last worked: " date; next }
    { print }' "$idx" > "$tmp" || { rm -f "$tmp"; return 0; }
  if cmp -s "$tmp" "$idx"; then rm -f "$tmp"; else mv "$tmp" "$idx" && echo set; fi
}

# session_orphans <session.log> [<before-date>]: "ts<TAB>tag" per start with no
# end. A closure line ("... end — closed without teardown (start <ts>)") closes
# exactly the start it names; a plain end closes the most recent open start of
# its tag. A closure whose named start is absent closes nothing, so it can
# never swallow a live session's start. With <before-date> only starts dated
# before it are listed, so a session running today is never reported or closed.
session_orphans() {
  [ -f "$1" ] || return 0
  awk -v before="${2:-9999-99-99}" '
    match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}\] \[[^]]+\] (start|end)/) {
      ts = substr($0, 2, 16); rest = substr($0, 21)
      tag = rest; sub(/\].*/, "", tag)
      if (rest ~ /\] start/) {
        c[tag]++; st[tag, c[tag]] = ts
        if (!(tag in seen)) { seen[tag] = 1; tags[++nt] = tag }
      } else {
        ref = ""
        if (match($0, /\(start [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}\)$/)) ref = substr($0, RSTART + 7, 16)
        if (ref != "") {
          for (j = 1; j <= c[tag]; j++) if (!cl[tag, j] && st[tag, j] == ref) { cl[tag, j] = 1; break }
        } else {
          for (j = c[tag]; j >= 1; j--) if (!cl[tag, j]) { cl[tag, j] = 1; break }
        }
      }
    }
    END { for (i = 1; i <= nt; i++) for (j = 1; j <= c[tags[i]]; j++)
            if (!cl[tags[i], j] && substr(st[tags[i], j], 1, 10) < before) print st[tags[i], j] "\t" tags[i] }' "$1" \
    | sort
}

# close_orphans <session.log> <before-date>: appends one end line per orphan
# and prints the number closed. Append-only: the log is never rewritten.
close_orphans() {
  local log="$1" before="$2" ts tag n=0 now
  now="$(now_ts)"
  while IFS=$'\t' read -r ts tag; do
    [ -n "$ts" ] || continue
    printf '[%s] [%s] end — closed without teardown (start %s)\n' "$now" "$tag" "$ts" >> "$log" || return 0
    n=$((n + 1))
  done < <(session_orphans "$log" "$before")
  echo "$n"
}

# ---- checks ---------------------------------------------------------------

emit() { printf '%s=%s\n' "$1" "$2"; }

# check_project <vault> <name> <context> <fix:0|1>
check_project() {
  local vault="$1" name="$2" ctx="$3" fix="$4"
  local proj="$vault/projects/$name" idx="$vault/INDEX.md"
  local status="$proj/status.md" log="$proj/.squad/session.log" today out="" r line
  today="$(now_ts)"; today="${today%% *}"
  local fixed="" findings=""

  # status.md: one awk pass -> updated, latest checkpoint, word count, tags
  local updated="" cp="" words=0 paused=0
  if [ -f "$status" ]; then
    line="$(awk '
      /^Last updated:/ && !u { u = substr($0, 15, 16); sub(/ +$/, "", u); got = 1 }
      /^tags:.*paused/ { p = 1 }
      /^## / { insec = ($0 == "## Last checkpoint") }
      insec && match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}\]/) { c = substr($0, 2, 16); if (c > cp) cp = c }
      { w += NF }
      END { printf "%s|%s|%d|%d\n", u, cp, w, p }' "$status")"
    updated="${line%%|*}"; line="${line#*|}"; cp="${line%%|*}"; line="${line#*|}"
    words="${line%%|*}"; paused="${line#*|}"
  fi

  # --fix first, so the findings below describe what is left.
  if [ "$fix" = 1 ]; then
    if [ -f "$status" ] && [ -n "$updated" ]; then
      r="$(index_set_row "$idx" "$name" "$([ "$paused" = 1 ] && echo paused || echo active)" "${updated%% *}")"
      case "$r" in
        date) fixed="${fixed}FIXED_INDEX_ROW_DATE=$name${NL}"; FIXED_FILES="${FIXED_FILES}INDEX.md${NL}" ;;
        added) fixed="${fixed}FIXED_INDEX_ROW_ADDED=$name${NL}"; FIXED_FILES="${FIXED_FILES}INDEX.md${NL}" ;;
      esac
    fi
    if [ -f "$log" ]; then
      r="$(close_orphans "$log" "$today")"
      if [ "${r:-0}" -gt 0 ]; then
        fixed="${fixed}FIXED_SESSION_CLOSED=$r $name${NL}"
        FIXED_FILES="${FIXED_FILES}projects/$name/.squad/session.log${NL}"
      fi
    fi
    if [ -s "$proj/decisions.md" ]; then
      local dsum; dsum="$(cksum < "$proj/decisions.md")"
      r="$(bash "$HERE/decisions-lint.sh" fix "$proj/decisions.md" 2>/dev/null | grep '^DECISIONS_APPLIED_INVERSE=')"
      [ -n "$r" ] && fixed="${fixed}${r}${NL}"
      [ "$(cksum < "$proj/decisions.md")" != "$dsum" ] && FIXED_FILES="${FIXED_FILES}projects/$name/decisions.md${NL}"
    fi
  fi

  # decisions.md (shared implementation)
  if [ -f "$proj/decisions.md" ]; then
    findings="${findings}$(bash "$HERE/decisions-lint.sh" check "$proj/decisions.md" 2>/dev/null | sed '/^DECISIONS_APPLIED_INVERSE=/d')"
  else
    findings="${findings}DECISIONS_FILE=missing"
  fi
  [ -n "$findings" ] && findings="${findings}${NL}"

  # status.md
  if [ ! -f "$status" ]; then
    findings="${findings}STATUS_FILE=missing${NL}"
  else
    local wk; wk="$(week_ago)"
    if [ -n "$updated" ] && [ -n "$wk" ] && [[ "$updated" < "$wk" ]]; then findings="${findings}STATUS_STALE=${updated%% *}${NL}"; fi
    if [ -n "$updated" ] && [ -n "$cp" ] && [[ "$cp" > "$updated" ]]; then findings="${findings}STATUS_CHECKPOINT_NEWER=$cp > $updated${NL}"; fi
    [ "$words" -gt "$STATUS_WORDS_MAX" ] && findings="${findings}STATUS_OVER_BUDGET=$words${NL}"
  fi

  # INDEX.md
  if [ ! -f "$idx" ]; then
    findings="${findings}INDEX_FILE=missing${NL}"
  else
    line="$(awk -v key="[[projects/$name/status" '
      /^## / { insec = ($0 == "## Projects") }
      insec && substr($0, 1, 1) == "|" && index($0, key) > 0 { found = 1; c = split($0, f, "|"); d = f[c - 1]; gsub(/ /, "", d) }
      END { printf "%d|%s\n", found, d }' "$idx")"
    local found="${line%%|*}" rdate="${line#*|}"
    if [ "$found" = 0 ]; then
      [ -f "$status" ] && findings="${findings}INDEX_NO_ROW=$name${NL}"
    elif [ -n "$updated" ] && [[ "$rdate" < "${updated%% *}" ]]; then
      findings="${findings}INDEX_ROW_BEHIND=$rdate < ${updated%% *}${NL}"
    fi
  fi

  # session.log
  if [ -f "$log" ]; then
    local orph first ots n
    orph="$(session_orphans "$log" "$today")"
    if [ -n "$orph" ]; then
      n="$(printf '%s\n' "$orph" | wc -l | tr -d ' ')"
      first="${orph%%$'\n'*}"; ots="${first%%$'\t'*}"
      findings="${findings}SESSION_UNCLOSED=$n oldest ${ots%% *} ${first#*$'\t'}${NL}"
    fi
  fi

  # JOURNAL pointer (#330) for projects whose knowledge lives in the repo
  if [ "$ctx" = repo ] && [ -f "$proj/decisions.md" ] && ! grep -q 'JOURNAL' "$proj/decisions.md"; then
    findings="${findings}JOURNAL_POINTER_MISSING=$name${NL}"
  fi

  out="${fixed}${findings}"
  if [ -n "$out" ]; then emit VAULT_SCOPE "$name"; printf '%s' "$out"; fi
}

# check_vault <vault>: stray root files and projects with no INDEX row.
check_vault() {
  local vault="$1" out="" f b idx="" p n
  [ -f "$vault/INDEX.md" ] && idx="$(cat "$vault/INDEX.md")"
  for f in "$vault"/*; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    case "$KNOWN_ROOT_FILES" in *" $b "*) ;; *) out="${out}VAULT_STRAY_ROOT=$b${NL}" ;; esac
  done
  if [ -n "$idx" ]; then
    for p in "$vault"/projects/*/status.md; do
      [ -f "$p" ] || continue
      n="${p%/status.md}"; n="${n##*/}"
      case "$idx" in *"[[projects/$n/status"*) ;; *) out="${out}VAULT_PROJECT_NO_INDEX=$n${NL}" ;; esac
    done
  fi
  if [ -n "$out" ]; then emit VAULT_SCOPE vault; printf '%s' "$out"; fi
}

render() {
  local k v hdr=0 any=0 scope=""
  while IFS='=' read -r k v; do
    v="${v//\\\\/\\}"
    case "$k" in
      VAULT_SCOPE) scope="$v"; echo "### Vault health ($v)"; any=1 ;;
      DECISIONS_*) printf '%s=%s\n' "$k" "$v" | bash "$HERE/decisions-lint.sh" render ;;
      STATUS_FILE) echo "status.md: $v" ;;
      STATUS_STALE) echo "status.md: Last updated $v, older than 7 days" ;;
      STATUS_CHECKPOINT_NEWER) echo "status.md: Last checkpoint newer than Last updated ($v)" ;;
      STATUS_OVER_BUDGET) echo "status.md: over budget ($v words); next rebuild compresses" ;;
      INDEX_FILE) echo "INDEX.md: file is $v" ;;
      INDEX_NO_ROW) echo "INDEX.md: no row for $v" ;;
      INDEX_ROW_BEHIND) echo "INDEX.md: row says ${v%% < *}, status.md says ${v##* < }" ;;
      SESSION_UNCLOSED) echo "session.log: ${v%% oldest *} start(s) without end (oldest ${v##* oldest })" ;;
      JOURNAL_POINTER_MISSING) echo "decisions.md: context is repo and $v has no JOURNAL pointer (#330)" ;;
      VAULT_STRAY_ROOT) echo "vault root: stray file $v" ;;
      VAULT_PROJECT_NO_INDEX) echo "INDEX.md: project $v has a status.md and no row" ;;
      FIXED_INDEX_ROW_DATE) echo "fixed: INDEX row date for $v" ;;
      FIXED_INDEX_ROW_ADDED) echo "fixed: INDEX row added for $v" ;;
      FIXED_SESSION_CLOSED) echo "fixed: closed ${v%% *} orphaned session start(s) in ${v#* } as 'closed without teardown'" ;;
      DECISIONS_APPLIED_INVERSE) echo "fixed: decisions.md inverse marker $v" ;;
    esac
  done
  [ "$any" = 1 ] && echo "Fix: lore decide --supersedes ..., or run lore check --fix for the mechanical ones."
  return 0
}

NL=$'\n'
FIXED_FILES=""
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    render) render; return 0 ;;
    check) ;;
    *) die "usage: vault-check.sh check [--fix] [--all] [--vault-wide] [--vault <dir>] [--project <name>] [--context repo] | render" ;;
  esac
  local fix=0 all=0 vwide=0 vault="" name="" ctx=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --fix) fix=1 ;;
      --all) all=1 ;;
      --vault-wide) vwide=1 ;;
      --vault) vault="${2:-}"; shift ;;
      --project) name="${2:-}"; shift ;;
      --context) ctx="${2:-}"; shift ;;
      *) die "vault-check.sh: unknown option $1" ;;
    esac
    shift
  done
  if [ -z "$vault" ]; then
    local k v sq=""
    while IFS='=' read -r k v; do
      case "$k" in VAULT_PATH) vault="$v" ;; DISPLAY_NAME) [ -z "$name" ] && name="$v" ;; SQUAD_DIR) sq="$v" ;; esac
    done < <("$HERE/path-resolve.sh" 2>/dev/null)
    [ -n "$sq" ] && [ -n "$name" ] && [ "$sq" != "$vault/projects/$name/.squad" ] && ctx=repo
  fi
  [ -d "$vault" ] || die "vault-check.sh: no vault at $vault" 2
  if [ "$all" = 1 ]; then
    local d
    for d in "$vault"/projects/*/; do
      d="${d%/}"; [ -d "$d" ] || continue
      check_project "$vault" "${d##*/}" "" "$fix"
    done
    check_vault "$vault"
  else
    [ -n "$name" ] || die "vault-check.sh: no project resolved (use --project or run inside a mapped project)" 2
    check_project "$vault" "$name" "$ctx" "$fix"
    [ "$vwide" = 1 ] && check_vault "$vault"
  fi
  # Commit only the files --fix wrote (pathspec leaves the rest of the index
  # and tree alone); nothing fixed, nothing committed.
  if [ "$fix" = 1 ] && [ -n "$FIXED_FILES" ] \
     && [ "$(git -C "$vault" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$vault" && pwd -P)" ]; then
    local f paths=()
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case " ${paths[*]:-} " in *" $f "*) continue ;; esac
      git -C "$vault" add -- "$f" >/dev/null 2>&1 && paths+=("$f")
    done <<< "$FIXED_FILES"
    if [ "${#paths[@]}" -gt 0 ] && ! git -C "$vault" diff --cached --quiet -- "${paths[@]}" 2>/dev/null; then
      git -C "$vault" commit -q -m "[lore] check --fix $(now_ts)" -- "${paths[@]}" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
