#!/usr/bin/env bash
# decisions-lint.sh -- one implementation of the decisions.md checks (#327),
# called by the SessionEnd hook (lore-checkpoint.sh), `lore decide`
# (lore-decide.sh) and, later, `lore check` / the SessionStart health block
# (#333). Contract: SCRIPT_CONTRACT.md (stdout is KEY=value lines only,
# one per finding; exit 0 on success even with findings, 2 usage, 20 I/O).
# Exception: check and fix emit findings only, no OUTCOME=/CHANGED= lines;
# callers (lore-checkpoint.sh, lore-decide.sh) consume the finding keys as-is
# and an empty stdout means clean.
#
# Usage:
#   decisions-lint.sh check  <decisions.md> [--new-only]
#   decisions-lint.sh fix    <decisions.md> [--new-only]
#   decisions-lint.sh render                       (KEY=value on stdin -> text)
#
# check is read-only. fix adds the inverse marker to the entry named by a
# Supersedes: / Supersedes in part: line when that entry lacks it (one line
# directly under its heading); it never rewrites or deletes any other text.
# A Supersedes: target is also looked up in decisions-archive.md next to the
# file (lore decide moves fully superseded entries there), so archiving never
# produces DECISIONS_TARGET_NOT_FOUND.
# --new-only restricts the "cites without marker" report to entries absent
# from the file at git HEAD (every entry when the file is not tracked).
#
# Findings (KEY=value):
#   DECISIONS_FILE=missing|empty
#   DECISIONS_BULLETS=<n>                  "- [YYYY-MM-DD]" entries, invisible to the window
#   DECISIONS_MISSING_INVERSE=<entry> -> <target>   (check only)
#   DECISIONS_APPLIED_INVERSE=<entry> -> <target>   (fix only)
#   DECISIONS_TARGET_NOT_FOUND=<entry> names <date> <title>
#   DECISIONS_CITES_WITHOUT_MARKER=<entry> cites [<date>]
#   DECISIONS_OVER_CAP=<n active>          over 60 active entries
#   DECISIONS_OVER_RULE_CAP=<n active>     over 15 active [rule] entries
# Partial supersession: "Supersedes in part:" counts as a marker, its inverse
# is "Superseded in part by:", and only a full "Superseded by:" deactivates.
set -u

die() { echo "$1" >&2; exit "${2:-2}"; }

render() {
  local k v
  while IFS='=' read -r k v; do
    v="${v//\\\\/\\}" # undo the awk esc() doubling of backslashes
    case "$k" in
      DECISIONS_FILE) echo "decisions.md: file is $v" ;;
      DECISIONS_BULLETS) echo "decisions.md: $v entries use '- [YYYY-MM-DD]' bullets, invisible to the Forge/Ralph decisions window; convert to '## [YYYY-MM-DD]' headings" ;;
      DECISIONS_MISSING_INVERSE) echo "decisions.md: $v lacks the inverse marker; lore decide --supersedes or the next SessionEnd adds it" ;;
      DECISIONS_TARGET_NOT_FOUND) echo "decisions.md: $v matches no entry" ;;
      DECISIONS_CITES_WITHOUT_MARKER) echo "decisions.md: entry $v without a Supersedes marker; run lore decide --supersedes or edit" ;;
      DECISIONS_OVER_CAP) echo "decisions.md: over cap ($v active, max 60); supersede or archive" ;;
      DECISIONS_OVER_RULE_CAP) echo "decisions.md: over rule cap ($v active [rule], max 15); supersede one" ;;
    esac
  done
}

# keys <file>: "date title" per entry heading ([rule] tag and trailing space dropped).
keys() {
  grep -E '^## \[[0-9]{4}-[0-9]{2}-[0-9]{2}\]' "$1" 2>/dev/null \
    | sed -E 's/^## \[([0-9-]+)\] *(\[rule\] *)?/\1 /; s/[[:space:]]+$//'
}

# new_keys <file>: "|key|key|" of entries not present at git HEAD, or ALL.
new_keys() {
  local f="$1" dir rel old oldf cur
  dir="$(cd "$(dirname "$f")" && pwd)"
  rel="$(git -C "$dir" ls-files --full-name -- "$(basename "$f")" 2>/dev/null)"
  if [ -z "$rel" ] || ! old="$(git -C "$dir" show "HEAD:$rel" 2>/dev/null)"; then echo ALL; return; fi
  oldf="$(mktemp)"; keys <(printf '%s\n' "$old") > "$oldf"
  cur="$(keys "$f" | while IFS= read -r k; do
    grep -qxF -- "$k" "$oldf" || printf '|%s' "$k"
  done)"
  rm -f "$oldf"
  printf '%s|\n' "$cur"
}

lint() { # lint <check|fix> <file> <newkeys>
  local mode="$1" f="$2" newk="$3" out=""
  [ "$mode" = fix ] && out="$f.lint.$$"
  awk -v mode="$mode" -v out="$out" -v newk="$newk" -v archk="$ARCHK" '
  function esc(s) { gsub(/\\/, "\\\\", s); return s }
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
  function archived(d, t,   n, a, m, p, ad, at) {
    n = split(archk, a, "|")
    for (m = 1; m <= n; m++) {
      if (a[m] == "") continue
      ad = substr(a[m], 1, 10); at = substr(a[m], 12)
      if (ad != d) continue
      if (t == "" || at == t || index(at, t) == 1) return 1
    }
    return 0
  }
  function label(i) { return "[" date[i] "] " title[i] }
  function prepare(   i, k, j, c, n, seen, cs, d, ln, tgt) {
    for (i = 1; i <= n_e; i++) dset[date[i]] = 1
    for (i = 1; i <= n_e; i++) {
      for (k = 1; k <= nsup[i]; k++) {
        tgt = 0
        for (j = 1; j <= n_e; j++) {
          if (j == i || date[j] != sd[i, k]) continue
          if (st[i, k] == "" || title[j] == st[i, k] || index(title[j], st[i, k]) == 1) { tgt = j; break }
        }
        if (!tgt && archived(sd[i, k], st[i, k])) continue
        if (!tgt) { print "DECISIONS_TARGET_NOT_FOUND=" esc(label(i)) " names " sd[i, k] " " esc(st[i, k]); continue }
        if (index(sbd[tgt], " " date[i] " ")) continue
        sbd[tgt] = sbd[tgt] " " date[i] " "
        ln = (part[i, k] ? "Superseded in part by: [" : "Superseded by: [") date[i] "] " title[i]
        ins[tgt] = ins[tgt] ln "\n"
        print (mode == "fix" ? "DECISIONS_APPLIED_INVERSE=" : "DECISIONS_MISSING_INVERSE=") esc(label(i)) " -> " esc(label(tgt))
      }
    }
    for (i = 1; i <= n_e; i++) {
      if (nsup[i] > 0) continue
      if (newk != "ALL" && !index(newk, "|" date[i] " " title[i] "|")) continue
      split("", seen)
      n = split(cites[i], cs, " ")
      for (c = 1; c <= n; c++) {
        d = cs[c]
        if (d < date[i] && (d in dset) && !(d in seen)) {
          seen[d] = 1
          print "DECISIONS_CITES_WITHOUT_MARKER=" esc(label(i)) " cites [" d "]"
        }
      }
    }
    for (i = 1; i <= n_e; i++) if (!full[i]) { act++; if (rule[i]) actr++ }
    if (act > 60) print "DECISIONS_OVER_CAP=" act
    if (actr > 15) print "DECISIONS_OVER_RULE_CAP=" actr
    if (bullets > 0) print "DECISIONS_BULLETS=" bullets
  }
  FNR == 1 { pass++; if (pass == 2) prepare() }
  pass == 1 {
    if ($0 ~ /^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/) {
      n_e++; cur = n_e
      date[n_e] = substr($0, 5, 10)
      r = trim(substr($0, 16))
      if (r ~ /^\[rule\]/) { rule[n_e] = 1; r = trim(substr(r, 7)) }
      title[n_e] = r
      next
    }
    if ($0 ~ /^#+ /) { cur = 0; next }
    if (cur == 0) { if ($0 ~ /^- \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/) bullets++; next }
    if ($0 ~ /^Supersedes( in part)?: /) {
      isp = ($0 ~ /^Supersedes in part:/)
      body = $0; sub(/^Supersedes( in part)?: */, "", body)
      k = ++nsup[cur]; part[cur, k] = isp
      if (match(body, /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) {
        sd[cur, k] = substr(body, 2, 10); st[cur, k] = trim(substr(body, 13))
      } else { sd[cur, k] = ""; st[cur, k] = trim(body) }
      next
    }
    if ($0 ~ /^Superseded (in part )?by: /) {
      if ($0 ~ /^Superseded by:/) full[cur] = 1
      if (match($0, /\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) sbd[cur] = sbd[cur] " " substr($0, RSTART + 1, 10) " "
      next
    }
    line = $0
    while (match(line, /\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) {
      cites[cur] = cites[cur] " " substr(line, RSTART + 1, 10)
      line = substr(line, RSTART + RLENGTH)
    }
    next
  }
  pass == 2 && out != "" {
    print > out
    if ($0 ~ /^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/) {
      hn++
      if (ins[hn] != "") printf "%s", ins[hn] > out
    }
  }
  ' "$f" "$f"
  if [ -n "$out" ]; then
    if cmp -s "$f" "$out"; then rm -f "$out"; else mv "$out" "$f" || { rm -f "$out"; die "decisions-lint: write failed" 20; }; fi
  fi
}

SUB="${1:-}"; shift 2>/dev/null || true
case "$SUB" in
  render) render; exit 0 ;;
  check|fix) ;;
  *) die "usage: decisions-lint.sh check|fix <decisions.md> [--new-only] | render" ;;
esac
FILE="${1:-}"; shift 2>/dev/null || true
[ -n "$FILE" ] || die "decisions-lint: file required"
NEWONLY=0
for a in "$@"; do
  case "$a" in --new-only) NEWONLY=1 ;; *) die "decisions-lint: unknown argument $a" ;; esac
done

if [ ! -f "$FILE" ]; then echo "DECISIONS_FILE=missing"; exit 0; fi
if ! grep -q '[^[:space:]]' "$FILE"; then echo "DECISIONS_FILE=empty"; exit 0; fi

NEWK=ALL
[ "$NEWONLY" = 1 ] && NEWK="$(new_keys "$FILE")"
ARCHK=""
ARCHF="$(dirname "$FILE")/decisions-archive.md"
[ -f "$ARCHF" ] && ARCHK="$(keys "$ARCHF" | tr '\n' '|')"
lint "$SUB" "$FILE" "$NEWK"
exit 0
