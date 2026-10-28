#!/usr/bin/env bash
# Tests claude/hooks/lore-map.sh (#372). Plain bash 3.2; fixture vaults only.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-lore-map.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2] in [$3])" ;; esac; }

export SQUAD_INCIDENTS=off
mkdir -p "$TMPROOT/hooks"
cp "$REPO_ROOT"/claude/hooks/{lore-map.sh,path-resolve.sh,squad-incidents.sh,squad-common.sh} "$TMPROOT/hooks/"
LM="$TMPROOT/hooks/lore-map.sh"

mkvault() {  # mkvault <dir>: git vault, tracked config, ignore rule for projects/secret/
  mkdir -p "$1/projects/shared" "$1/projects/secret"
  printf '{"projects":{"/other":"other"},"vault_main":"direct"}\n' > "$1/lore-config.json"
  printf 'projects/secret/\n' > "$1/.gitignore"
  echo x > "$1/projects/shared/status.md"; echo x > "$1/projects/secret/status.md"
  git -C "$1" init -q -b main
  git -C "$1" add -A && git -C "$1" -c user.email=t@t -c user.name=t commit -qm init
}

# 1. Ignored project folder -> local file only, tracked config byte-identical.
V="$TMPROOT/v1"; mkvault "$V"
cp "$V/lore-config.json" "$TMPROOT/cfg.before"; HEAD0="$(git -C "$V" rev-parse HEAD)"
out="$(bash "$LM" set --vault "$V" --root /w/secret --name secret)"; rc=$?
check "ignored: exit 0" 0 "$rc"
has "ignored: target local" "TARGET=local" "$out"
has "ignored: applied" "OUTCOME=applied" "$out"
check "ignored: local file has mapping" "secret" "$(jq -r '.projects["/w/secret"]' "$V/lore-config.local.json")"
cmp -s "$V/lore-config.json" "$TMPROOT/cfg.before" && ok "ignored: tracked config byte-identical" || bad "ignored: tracked config changed"
check "ignored: local file never tracked" "" "$(git -C "$V" ls-files lore-config.local.json)"
check "ignored: only .gitignore committed" ".gitignore" "$(git -C "$V" diff --name-only "$HEAD0" HEAD)"
check "ignored: .gitignore lists local file" 1 "$(grep -cxF 'lore-config.local.json*' "$V/.gitignore")"
check "ignored: local file untracked+ignored" "lore-config.local.json" "$(git -C "$V" check-ignore lore-config.local.json)"
check "ignored: name absent from git history" 0 "$(git -C "$V" log -p | grep -c '/w/secret')"

# 2. --local forces the local file even for a shared project.
V="$TMPROOT/v2"; mkvault "$V"
cp "$V/lore-config.json" "$TMPROOT/cfg.before"; HEAD0="$(git -C "$V" rev-parse HEAD)"
out="$(bash "$LM" set --vault "$V" --root /w/shared --name shared --local)"
has "--local: target local" "TARGET=local" "$out"
check "--local: local mapping" "shared" "$(jq -r '.projects["/w/shared"]' "$V/lore-config.local.json")"
cmp -s "$V/lore-config.json" "$TMPROOT/cfg.before" && ok "--local: tracked config byte-identical" || bad "--local: tracked config changed"
check "--local: local file never tracked" "" "$(git -C "$V" ls-files lore-config.local.json)"
check "--local: lore-config.json not in any new commit" "" "$(git -C "$V" diff --name-only "$HEAD0" HEAD | grep lore-config.json)"

# 3. Shared project -> tracked file, committed, other keys kept.
V="$TMPROOT/v3"; mkvault "$V"
out="$(bash "$LM" set --vault "$V" --root /w/shared --name shared)"
has "shared: target tracked" "TARGET=tracked" "$out"
check "shared: mapping written" "shared" "$(jq -r '.projects["/w/shared"]' "$V/lore-config.json")"
check "shared: other entry kept" "other" "$(jq -r '.projects["/other"]' "$V/lore-config.json")"
check "shared: other key kept" "direct" "$(jq -r '.vault_main' "$V/lore-config.json")"
check "shared: committed" "[lore] map project shared" "$(git -C "$V" log -1 --format=%s)"
check "shared: tree clean" "" "$(git -C "$V" status --porcelain)"
check "shared: no local file" 0 "$([ -e "$V/lore-config.local.json" ] && echo 1 || echo 0)"
out="$(bash "$LM" set --vault "$V" --root /w/shared --name shared)"
has "shared: rerun unchanged" "OUTCOME=unchanged" "$out"
check "shared: rerun no extra commit" 2 "$(git -C "$V" rev-list --count HEAD)"

# 4. Missing config -> created; invalid config -> exit 10, untouched.
V="$TMPROOT/v4"; mkdir -p "$V"; git -C "$V" init -q -b main
bash "$LM" set --vault "$V" --root /w/a --name a >/dev/null
check "fresh: created" "a" "$(jq -r '.projects["/w/a"]' "$V/lore-config.json")"
printf 'not json' > "$V/lore-config.json"
bash "$LM" set --vault "$V" --root /w/b --name b >/dev/null 2>&1; rc=$?
check "invalid config: exit 10" 10 "$rc"
check "invalid config: untouched" "not json" "$(cat "$V/lore-config.json")"

# 5. Usage errors.
bash "$LM" set --vault "$V" --name x >/dev/null 2>&1; check "missing --root: exit 2" 2 "$?"
bash "$LM" bogus >/dev/null 2>&1; check "unknown verb: exit 2" 2 "$?"

# 6. ignore verb: creates, appends, idempotent, keeps existing lines.
V="$TMPROOT/v6"; mkdir -p "$V"
out="$(bash "$LM" ignore --vault "$V")"
has "ignore: created" "OUTCOME=applied" "$out"
check "ignore: content" "lore-config.local.json*" "$(cat "$V/.gitignore")"
out="$(bash "$LM" ignore --vault "$V")"
has "ignore: rerun unchanged" "OUTCOME=unchanged" "$out"
printf 'a\nb' > "$V/.gitignore"; bash "$LM" ignore --vault "$V" >/dev/null
check "ignore: append keeps lines" "a
b
lore-config.local.json*" "$(cat "$V/.gitignore")"

# 7. Unchanged re-run still adds a missing ignore line.
V="$TMPROOT/v7"; mkvault "$V"
bash "$LM" set --vault "$V" --root /w/secret --name secret >/dev/null
printf 'projects/secret/\n' > "$V/.gitignore"; git -C "$V" commit -qam "drop ignore"
out="$(bash "$LM" set --vault "$V" --root /w/secret --name secret)"
has "rerun: ignore re-added reports applied" "OUTCOME=applied" "$out"
has "rerun: CHANGED yes" "CHANGED=yes" "$out"
check "rerun: ignore line restored" 1 "$(grep -cxF 'lore-config.local.json*' "$V/.gitignore")"
out="$(bash "$LM" set --vault "$V" --root /w/secret --name secret)"
has "rerun again: unchanged" "OUTCOME=unchanged" "$out"
has "rerun again: CHANGED no" "CHANGED=no" "$out"

# 8. Temp files of a killed write are ignored.
touch "$V/lore-config.local.json.tmp.1234"
check "temp pattern ignored" "lore-config.local.json.tmp.1234" "$(git -C "$V" check-ignore lore-config.local.json.tmp.1234)"

# 9. Tracked, then mapped locally: entry leaves the tracked file, commit is name-free.
V="$TMPROOT/v9"; mkvault "$V"
bash "$LM" set --vault "$V" --root /w/moved --name movedproj >/dev/null
check "moved: tracked first" movedproj "$(jq -r '.projects["/w/moved"]' "$V/lore-config.json")"
err="$(bash "$LM" set --vault "$V" --root /w/moved --name movedproj --local 2>&1 >/dev/null)"
check "moved: tracked entry removed" null "$(jq -r '.projects["/w/moved"]' "$V/lore-config.json")"
check "moved: other entry kept" other "$(jq -r '.projects["/other"]' "$V/lore-config.json")"
check "moved: local entry written" movedproj "$(jq -r '.projects["/w/moved"]' "$V/lore-config.local.json")"
check "moved: removal committed" "" "$(git -C "$V" status --porcelain)"
check "moved: commit message name-free" 0 "$(git -C "$V" log -1 --format=%B | grep -c movedproj)"
has "moved: history notice" "still in the vault git history" "$err"
check "moved: exactly one notice" 1 "$(printf '%s\n' "$err" | grep -c 'git history')"

# 10. PR-mode vault: tracked write lands on the lore branch, main stays put.
V="$TMPROOT/v10"; mkvault "$V"
printf '{"projects":{},"vault_main":"pr"}\n' > "$V/lore-config.json"
git -C "$V" commit -qam pr
HEAD0="$(git -C "$V" rev-parse main)"
bash "$LM" set --vault "$V" --root /w/shared --name shared >/dev/null
check "pr: main untouched" "$HEAD0" "$(git -C "$V" rev-parse main)"
B="$(git -C "$V" for-each-ref --format='%(refname:short)' 'refs/heads/lore/*' | head -1)"
check "pr: mapping on lore branch" shared "$(git -C "$V" show "$B:lore-config.json" | jq -r '.projects["/w/shared"]')"

# 11. Non-git vault: files written, no git needed.
V="$TMPROOT/v11"; mkdir -p "$V"
out="$(bash "$LM" set --vault "$V" --root /w/n --name n --local)"; rc=$?
check "non-git: exit 0" 0 "$rc"
has "non-git: target local" "TARGET=local" "$out"
check "non-git: mapping" n "$(jq -r '.projects["/w/n"]' "$V/lore-config.local.json")"
check "non-git: ignore line" 1 "$(grep -cxF 'lore-config.local.json*' "$V/.gitignore")"

# 12. --local on a non-ignored folder, PR-mode vault: the name never reaches a ref,
# worktree, commit or tracked file; the vault treats the project as local-only.
V="$TMPROOT/v12"; mkvault "$V"; mkdir -p "$V/projects/zzname"; echo x > "$V/projects/zzname/status.md"
printf '{"projects":{"/w/zzname":"zzname"},"vault_main":"pr"}\n' > "$V/lore-config.json"
git -C "$V" commit -qam pr; HEAD0="$(git -C "$V" rev-parse main)"
err="$(bash "$LM" set --vault "$V" --root /w/zzname --name zzname --local 2>&1 >/dev/null)"
check "leak: branch names name-free" 0 "$(git -C "$V" for-each-ref --format='%(refname)' | grep -c zzname)"
check "leak: worktree paths name-free" 0 "$(git -C "$V" worktree list --porcelain | grep -c zzname)"
check "leak: commit messages name-free" 0 "$(git -C "$V" log --all --not "$HEAD0" --format=%B | grep -c zzname)"
check "leak: added lines name-free" 0 "$(git -C "$V" log --all --not "$HEAD0" -p | grep '^+[^+]' | grep -c zzname)"
check "leak: tracked .gitignore name-free" 0 "$(grep -c zzname "$V/.gitignore")"
git -C "$V" ls-files | grep -q zzname && bad "leak: tracked paths" || ok "leak: tracked paths name-free"
EXC="$(git -C "$V" rev-parse --git-path info/exclude)"; case "$EXC" in /*) ;; *) EXC="$V/$EXC" ;; esac
check "exclude: entry present" 1 "$(grep -cxF 'projects/zzname/' "$EXC")"
. "$TMPROOT/hooks/squad-common.sh"
squad_local_only "$V" zzname && ok "local_only true after --local" || bad "local_only true after --local"
bash "$LM" set --vault "$V" --root /w/zzname --name zzname --local >/dev/null 2>&1
check "exclude: entry not duplicated" 1 "$(grep -cxF 'projects/zzname/' "$EXC")"

# 13. Tracked files under projects/<name>/: one notice, files left alone.
V="$TMPROOT/v13"; mkvault "$V"
err="$(bash "$LM" set --vault "$V" --root /w/shared --name shared --local 2>&1 >/dev/null)"
has "tracked notice: printed" "rm -r --cached" "$err"
check "tracked notice: exactly once" 1 "$(printf '%s\n' "$err" | grep -c 'rm -r --cached')"
check "tracked notice: files kept" "projects/shared/status.md" "$(git -C "$V" ls-files projects/shared)"

# 14. Exclude file without a trailing newline: the entry lands on its own line.
V="$TMPROOT/v14"; mkvault "$V"
EXC="$(git -C "$V" rev-parse --git-path info/exclude)"; case "$EXC" in /*) ;; *) EXC="$V/$EXC" ;; esac
mkdir -p "$(dirname "$EXC")"; printf 'abc' > "$EXC"
bash "$LM" set --vault "$V" --root /w/nl --name nl --local >/dev/null 2>&1; rc=$?
check "no-newline: exit 0" 0 "$rc"
check "no-newline: entry on its own line" 1 "$(grep -cxF 'projects/nl/' "$EXC")"
check "no-newline: old line intact" 1 "$(grep -cxF 'abc' "$EXC")"
squad_local_only "$V" nl && ok "no-newline: local_only true" || bad "no-newline: local_only true"

# 15. Post-check: a .gitignore negation defeats the exclude entry; exit 20, no success.
V="$TMPROOT/v15"; mkvault "$V"
printf '!projects/neg/\n' >> "$V/.gitignore"; git -C "$V" commit -qam neg
err="$(bash "$LM" set --vault "$V" --root /w/neg --name neg --local 2>&1 >/dev/null)"; rc=$?
check "post-check: exit 20" 20 "$rc"
has "post-check: stderr reason" "not ignored" "$err"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
