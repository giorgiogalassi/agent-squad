#!/usr/bin/env bash
# squad-lint.sh — parity and contract lint for the claude/ and codex/ trees.
#
# Turns the exhortation in CLAUDE.md ("grep both trees before declaring
# done") into a gate. Four checks, each independent and each able to fail
# the run on its own:
#
#   1. path-resolution protocol presence in every skill and agent
#   2. claude/codex file-set parity, plus a narrow semantic-drift check,
#      both checked against the PLATFORM_DIFFERENCES.md allowlist
#   3. chisel-config.json field cross-references (a field read somewhere
#      must be written somewhere)
#   4. dangling documentation pointers (referenced files must exist)
#
# Exit code is non-zero if any check reports a violation. No external
# dependency beyond bash, grep, find, and diff — all already required by
# the rest of this repo's tooling.
#
# Usage: scripts/squad-lint.sh [--repo-root <path>]

set -uo pipefail

REPO_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$REPO_ROOT" || { echo "Cannot cd to repo root: $REPO_ROOT" >&2; exit 2; }

VIOLATIONS=0
CHECK_NAME=""

section() {
  CHECK_NAME="$1"
  printf '\n== %s ==\n' "$1"
}

fail() {
  VIOLATIONS=$((VIOLATIONS + 1))
  printf '[FAIL] [%s] %s\n' "$CHECK_NAME" "$1"
}

ok() {
  printf '[ok] %s\n' "$1"
}

# ---------------------------------------------------------------------
# Check 1: path-resolution protocol present in every skill and agent
# ---------------------------------------------------------------------
check_path_resolution_protocol() {
  section "1. path-resolution protocol"

  target_files=""
  if [ -d claude/skills ]; then
    target_files="$target_files $(find claude/skills -name SKILL.md)"
  fi
  if [ -d codex/skills ]; then
    target_files="$target_files $(find codex/skills -name SKILL.md)"
  fi
  if [ -d claude/agents ]; then
    target_files="$target_files $(find claude/agents -name '*.md')"
  fi
  if [ -d codex/agents ]; then
    target_files="$target_files $(find codex/agents -name '*.toml')"
  fi

  # A skill that is a pure delegating wrapper -- it forwards straight to
  # an agent and performs no actions of its own -- cannot run
  # path-resolve.sh and does not need to: the agent it hands off to owns
  # path resolution instead. This is detected structurally, not by
  # filename: both claude/skills/lore/SKILL.md and codex/skills/lore/SKILL.md
  # say, verbatim, that the skill "does no work itself" -- the same
  # marker phrase is what lets Ralph's own delegation notes describe it.
  # A skill that does real work (e.g. codex/skills/reven/SKILL.md, which
  # reads the diff and vault files itself, not via a Task/sub-agent
  # handoff) never carries this marker and is still checked normally.
  # This is deliberately not keyed on the claude-only `allowed-tools`
  # frontmatter field, since codex skills never declare that field at
  # all -- keying on it would silence every codex skill, not just the
  # delegating ones.
  hits=0
  for f in $target_files; do
    hits=$((hits + 1))
    if grep -qi "does no work itself" "$f"; then
      ok "$f: pure delegating wrapper (explicitly does no work itself) — path resolution belongs to the agent it hands off to, skipping"
      continue
    fi
    if ! grep -q "path-resolve\.sh" "$f"; then
      fail "$f: no reference to path-resolve.sh — the path-resolution protocol block is missing or was not carried over"
    fi
  done

  if [ "$hits" -eq 0 ]; then
    fail "no skill or agent files found under claude/ or codex/ — check the repo layout, this check should never see zero targets"
  fi
}

# ---------------------------------------------------------------------
# Check 2: claude/codex file-set parity + semantic-drift allowlist
# ---------------------------------------------------------------------

# Reads PLATFORM_DIFFERENCES.md's "## Parity Allowlist" section and
# returns 0 (found) if the given "<kind>: <path>" pair is present.
# kind is one of: claude-only, codex-only, semantic-diff.
is_allowlisted() {
  kind="$1"
  path="$2"
  [ -f PLATFORM_DIFFERENCES.md ] || return 1
  grep -Eq "^- \`?${kind}: ${path//\//\\/}\`?( |$|\`)" PLATFORM_DIFFERENCES.md
}

check_parity() {
  section "2. claude/codex file-set parity and semantic drift"

  if [ ! -d claude ] || [ ! -d codex ]; then
    ok "one of claude/ or codex/ does not exist — parity check has no subject, skipping (see issue #118 note on dropping a distribution)"
    return
  fi

  claude_raw="$(find claude -type f | sed 's#^claude/##' | sort)"
  codex_raw="$(find codex -type f | sed 's#^codex/##' | sort)"

  # Normalize agent file extensions: agents/<name>.md and agents/<name>.toml
  # are the documented structural difference (PLATFORM_DIFFERENCES.md
  # "Agent Format" table), not a per-file allowlist matter.
  claude_norm="$(printf '%s\n' "$claude_raw" | sed -E 's#^(agents/[^/]+)\.md$#\1#')"
  codex_norm="$(printf '%s\n' "$codex_raw" | sed -E 's#^(agents/[^/]+)\.toml$#\1#')"

  only_claude="$(comm -23 <(printf '%s\n' "$claude_norm") <(printf '%s\n' "$codex_norm"))"
  only_codex="$(comm -13 <(printf '%s\n' "$claude_norm") <(printf '%s\n' "$codex_norm"))"

  if [ -n "$only_claude" ]; then
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      if is_allowlisted "claude-only" "$p"; then
        ok "claude/$p has no codex counterpart (allowlisted in PLATFORM_DIFFERENCES.md)"
      else
        fail "claude/$p has no codex counterpart and is not in PLATFORM_DIFFERENCES.md's Parity Allowlist — add a codex twin or add 'claude-only: $p' to the allowlist"
      fi
    done <<EOF
$only_claude
EOF
  fi

  if [ -n "$only_codex" ]; then
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      if is_allowlisted "codex-only" "$p"; then
        ok "codex/$p has no claude counterpart (allowlisted in PLATFORM_DIFFERENCES.md)"
      else
        fail "codex/$p has no claude counterpart and is not in PLATFORM_DIFFERENCES.md's Parity Allowlist — add a claude twin or add 'codex-only: $p' to the allowlist"
      fi
    done <<EOF
$only_codex
EOF
  fi

  # --- Semantic drift: cross-skill slash notation left in codex/ -------
  # claude/ establishes "/name" as its own trigger convention (every
  # skill's frontmatter says "Triggers: /name"), so slash references to
  # other skills there are the house style, not drift.
  # codex/ establishes "use the `name` skill" as its convention instead
  # (see every codex SKILL.md's "Triggers:" line). A codex file that
  # still uses "/name" to refer to *another* skill is leftover notation
  # from before the conversion, not intentional style.
  skill_names="chisel ralph forge archy seed sidecar reven cody lore"
  if [ -d codex/skills ]; then
    for f in $(find codex/skills -name SKILL.md); do
      self="$(basename "$(dirname "$f")")"
      for name in $skill_names; do
        [ "$name" = "$self" ] && continue
        # Require the slash to be at a token boundary (not part of a
        # longer path like ".squad/forge/output.yaml") and the name to
        # not continue into a longer identifier (not part of a filename
        # like "lore-config.json").
        matches="$(grep -noE "(^|[^A-Za-z0-9_./-])/${name}([^A-Za-z0-9_.-]|\$)" "$f" || true)"
        [ -z "$matches" ] && continue
        while IFS= read -r m; do
          [ -z "$m" ] && continue
          line="${m%%:*}"
          rel="$f"
          if is_allowlisted "semantic-diff" "skills/$self/SKILL.md"; then
            ok "$f:$line: /${name} slash notation (allowlisted in PLATFORM_DIFFERENCES.md)"
          else
            fail "$f:$line: uses '/${name}' slash notation to reference another skill, but codex/'s own convention here is 'use the \`${name}\` skill' (see other codex Triggers: lines) — update the wording or add 'semantic-diff: skills/$self/SKILL.md' to the allowlist if intentional"
          fi
        done <<EOF
$matches
EOF
      done
    done
  fi
}

# ---------------------------------------------------------------------
# Check 3: chisel-config.json field cross-references
# ---------------------------------------------------------------------
check_config_field_cross_references() {
  section "3. config field cross-references"

  fields="review_label state_labels tracker"
  chisel_skill_files=""
  [ -f claude/skills/chisel/SKILL.md ] && chisel_skill_files="$chisel_skill_files claude/skills/chisel/SKILL.md"
  [ -f codex/skills/chisel/SKILL.md ] && chisel_skill_files="$chisel_skill_files codex/skills/chisel/SKILL.md"

  if [ -z "$chisel_skill_files" ]; then
    fail "neither claude/skills/chisel/SKILL.md nor codex/skills/chisel/SKILL.md found — cannot determine which chisel-config.json fields are written"
    return
  fi

  for field in $fields; do
    written=0
    for f in $chisel_skill_files; do
      if grep -qE "\"${field}\":" "$f"; then
        written=1
      fi
    done

    # Selector-style reads: `field: value` in backticks, e.g. `tracker: github`.
    # This deliberately does not match the bare English word (e.g. "your
    # tracker manually") because it requires the literal "field:" form.
    reads="$(grep -rnE "\`${field}: " claude codex 2>/dev/null || true)"
    [ -z "$reads" ] && continue

    if [ "$written" -eq 1 ]; then
      continue
    fi

    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      loc="${hit%%:*}"
      rest="${hit#*:}"
      lineno="${rest%%:*}"
      fail "$loc:$lineno: reads config field \`${field}\` as a selector but no chisel-config.json schema in claude/skills/chisel/SKILL.md or codex/skills/chisel/SKILL.md writes \`${field}\` — either the schema is missing the field or this reference should be removed"
    done <<EOF
$reads
EOF
  done
}

# ---------------------------------------------------------------------
# Check 4: dangling documentation pointers
# ---------------------------------------------------------------------
check_dangling_doc_pointers() {
  section "4. dangling documentation pointers"

  # JOURNAL.md is an append-only historical log: it narrates past states,
  # including files that were deliberately removed (e.g. the
  # claude/CLAUDE.md.example example-file removal at Iteration ~19-ish).
  # Referencing a since-removed file there in past tense is correct
  # history, not a dangling pointer — see the issue's own warning about
  # not flagging correct post-removal rationale as residue.
  scan_files="README.md PLATFORM_DIFFERENCES.md PATH_RESOLUTION.md CLAUDE.md"
  for d in claude codex; do
    [ -d "$d" ] || continue
    scan_files="$scan_files $(find "$d" -type f \( -name '*.md' -o -name '*.toml' -o -name '*.py' -o -name '*.sh' \))"
  done

  for f in $scan_files; do
    [ -f "$f" ] || continue

    # Pattern A: backtick-quoted repo-relative paths under claude/ or codex/.
    matches="$(grep -noE '\`(claude|codex)/[A-Za-z0-9_./-]+\`' "$f" || true)"
    if [ -n "$matches" ]; then
      while IFS= read -r m; do
        [ -z "$m" ] && continue
        lineno="${m%%:*}"
        raw="${m#*:}"
        path="$(printf '%s' "$raw" | tr -d '`')"
        if [ ! -e "$path" ]; then
          fail "$f:$lineno: references \`$path\`, which does not exist in this repo"
        fi
      done <<EOF
$matches
EOF
    fi

    # Pattern B: bare docs/*.md references not scoped to the vault
    # (i.e. not preceded by "<vault>/"). This repo has no docs/
    # directory, so any bare "docs/foo.md" pointer is dangling by
    # construction; "<vault>/docs/foo.md" is a vault-relative path
    # Seed/Lore create on demand and is out of scope here.
    docmatches="$(grep -noE '[^`[:space:]]*docs/[A-Za-z0-9_.-]+\.md' "$f" || true)"
    if [ -n "$docmatches" ]; then
      while IFS= read -r m; do
        [ -z "$m" ] && continue
        lineno="${m%%:*}"
        raw="${m#*:}"
        case "$raw" in
          *'<vault>'*) continue ;;
        esac
        path="$(printf '%s' "$raw" | sed -E 's#^.*(^|/)(docs/)#\2#')"
        if [ ! -e "$path" ]; then
          fail "$f:$lineno: references \"$path\", which does not exist in this repo (not vault-scoped, no <vault>/ prefix)"
        fi
      done <<EOF
$docmatches
EOF
    fi
  done
}

check_path_resolution_protocol
check_parity
check_config_field_cross_references
check_dangling_doc_pointers

printf '\n== summary ==\n'
if [ "$VIOLATIONS" -gt 0 ]; then
  printf '%d violation(s) found.\n' "$VIOLATIONS"
  exit 1
fi
printf 'No violations found.\n'
exit 0
