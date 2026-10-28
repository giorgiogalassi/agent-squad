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
check "ignored: .gitignore lists local file" 1 "$(grep -cxF lore-config.local.json "$V/.gitignore")"
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
check "ignore: content" "lore-config.local.json" "$(cat "$V/.gitignore")"
out="$(bash "$LM" ignore --vault "$V")"
has "ignore: rerun unchanged" "OUTCOME=unchanged" "$out"
printf 'a\nb' > "$V/.gitignore"; bash "$LM" ignore --vault "$V" >/dev/null
check "ignore: append keeps lines" "a
b
lore-config.local.json" "$(cat "$V/.gitignore")"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
