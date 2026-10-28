#!/usr/bin/env bash
# squad-lint.sh — parity and contract lint for the claude/ and codex/ trees.
#
# Turns the exhortation in CLAUDE.md ("grep both trees before declaring
# done") into a gate. Eleven checks, each independent and each able to fail
# the run on its own:
#
#   1. path-resolution protocol presence in every skill and agent
#   2. claude/codex file-set parity, plus a narrow semantic-drift check,
#      both checked against the PLATFORM_DIFFERENCES.md allowlist
#   3. chisel-config.json field cross-references (a field read somewhere
#      must be written somewhere)
#   4. dangling documentation pointers (referenced files must exist)
#   5. delegation tool: a SKILL.md whose body delegates to an agent must list
#      `Agent` in allowed-tools, and no skill may use the legacy `Task` name
#   6. gh write ban: every `gh <sub>` in claude/skills and claude/agents must
#      be a read form, carry <!-- lint:gh-ok -->, or match an entry in
#      scripts/lint-allowlist-1b.txt (each entry must name its retiring batch)
#   7. label-doc/test tie: every LABEL_STATE_MACHINE.md row whose "Performed
#      by" cell names squad-labels.sh has a test in scripts/test-squad-labels.sh
#      whose name starts with its id (L<n> , or D- for the id "D"), and every
#      such test id has a script-performed row
#   8. hook refs exist: every ${CLAUDE_PLUGIN_ROOT}/hooks/<x>.sh referenced in
#      claude/skills/** or claude/agents/*.md must exist as claude/hooks/<x>.sh,
#      and no copy-install ~/.claude/hooks/ reference may remain
#   9. plugin layout: plugin.json has name/version/description, every script
#      claude/hooks/hooks.json registers exists, and no agent sets a
#      frontmatter key plugin subagents ignore (hooks, mcpServers,
#      permissionMode, initialPrompt)
#  10. description drift: reven.md must keep the mandatory `## Description
#      drift` section in its output template, with the `none:` form, and
#      ralph/SKILL.md must apply it through squad-pr-desc.sh
#  11. safe test tmp root: scripts/test-*.sh must not run `$(mktemp ...)`
#      outside a `$TMPROOT`/`$TMP`/`$tmp` parent, and must not install a raw
#      `trap 'rm -rf ...'`; they source scripts/lib/test-tmp.sh instead (an
#      empty mktemp result otherwise turns the EXIT trap into rm -rf of the
#      working directory). Escape: `# lint:tmp-ok` on the same line.
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
# Check 1: path-resolution env fallback present (full protocol block forbidden)
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
  # Stateless agents/skills (never touch the vault) opt out explicitly with
  # the marker "squad-lint: stateless" (put it in an HTML comment). A bare
  # mention of path-resolve.sh no longer passes: the file must contain an
  # actual invocation, "bash <path>/path-resolve.sh".
  hits=0
  for f in $target_files; do
    hits=$((hits + 1))
    if grep -q "squad-lint: stateless" "$f"; then
      ok "$f: explicit stateless opt-out (squad-lint: stateless) — never touches the vault, skipping"
      continue
    fi
    if grep -qi "does no work itself" "$f"; then
      ok "$f: pure delegating wrapper (explicitly does no work itself) — path resolution belongs to the agent it hands off to, skipping"
      continue
    fi
    # The protocol block moved into hooks/squad-env.sh (SessionStart exports
    # SQUAD_* once). A file may no longer carry the full block (run the script,
    # read the five keys from its output) and must carry the env fallback:
    # $SQUAD_PROJECT_ROOT plus "bash <path>/path-resolve.sh" for sessions
    # started without the hook (claude -p, evals).
    if grep -Eq 'Path resolution protocol|path-resolve\.sh`? ?(and read|; read)|from the `path-resolve\.sh` output' "$f"; then
      fail "$f: carries the full path-resolution protocol block — replace it with the SQUAD_* env fallback line"
    elif ! grep -q 'SQUAD_PROJECT_ROOT' "$f" || ! grep -Eq "bash [^ ]*path-resolve\.sh" "$f"; then
      fail "$f: no env fallback (\$SQUAD_PROJECT_ROOT plus 'bash .../path-resolve.sh') and no 'squad-lint: stateless' marker — the path-resolution fallback line is missing"
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

# Check 5: a skill that delegates must pre-approve the Agent tool (renamed
# from Task in Claude Code 2.1.63); without it the delegation prompts.
check_delegation_tool() {
  local f tools body before="$VIOLATIONS"
  section "5. delegation tool in allowed-tools"
  for f in claude/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    tools="$(grep -m1 '^allowed-tools:' "$f" || true)"
    body="$(awk '/^---$/{n++; next} n>=2' "$f")"
    if printf '%s\n' "$tools" | grep -qE '(:|,) *Task *(,|$)'; then
      fail "$f: allowed-tools uses legacy name \"Task\"; use \"Agent\""
    fi
    if printf '%s\n' "$body" | grep -qE 'Agent tool|Task tool|\(Task\)|\(Agent\)|`Task`|`Agent`|subagent|[Ss]pawn(s|ed|ing)? (Cody|Ralph)'; then
      if ! printf '%s\n' "$tools" | grep -qE '(:|,) *Agent *(,|$)'; then
        fail "$f: body delegates to an agent but allowed-tools does not list \"Agent\""
      fi
    fi
  done
  [ "$VIOLATIONS" -eq "$before" ] && ok "delegating skills declare Agent"
}

# ---------------------------------------------------------------------
# Check 6: label (and other tracker) writes live in scripts, not prose.
# Every `gh <subcommand>` token in skill and agent prose must be a read
# form, carry <!-- lint:gh-ok --> on the same line, or match an entry in
# scripts/lint-allowlist-1b.txt. Allowlist line format:
#   <file>|<regex matched against "gh <rest of line>">|retires: <batch>|<YYYY-MM-DD>
# The regex field must not contain '|'. A line lacking the retires tag or
# the date is itself a violation. Tokens whose first word is not lowercase
# ("gh CLI", "gh is") are prose, not commands, and are ignored.
# ---------------------------------------------------------------------
GH_READ_RE='^(issue (view|list)|pr (view|list|checks|diff)|project view|repo view|auth status|stack init|--version)([^[:alnum:]-]|$)'
GH_CMD_RE='^(issue|pr|project|repo|label|api|auth|stack|release|run|workflow|secret|variable|gist|search|ruleset|cache|codespace|extension|alias|config|browse|status|--[a-z]+)([^[:alnum:]-]|$)'
GH_TOKEN_RE='(^|[^[:alnum:]_/.-])gh +([a-z-].*)'

check_gh_write_ban() {
  local before="$VIOLATIONS" allow=scripts/lint-allowlist-1b.txt
  local f line n rest cmd hit afile are a_rest i start hasmut infence
  local lines=() mut=() a_files=() a_res=()
  section "6. gh write ban in skills and agents"

  if [ -f "$allow" ]; then
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      case "$line" in ''|'#'*) continue ;; esac
      afile="${line%%|*}"; a_rest="${line#*|}"
      are="${a_rest%%|*}"; a_rest="${a_rest#*|}"
      if [ "$a_rest" = "$line" ] || ! printf '%s\n' "$a_rest" | grep -Eq '^retires: *[A-Za-z0-9][A-Za-z0-9._-]*\|[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        fail "$allow:$n: entry lacks 'retires: <batch>' tag and/or date -- want <file>|<regex>|retires: <batch>|<YYYY-MM-DD>"
        continue
      fi
      a_files[${#a_files[@]}]="$afile"
      a_res[${#a_res[@]}]="$are"
    done < "$allow"
  fi

  local targets
  targets="$( { find claude/skills -type f -name '*.md' 2>/dev/null; find claude/agents -maxdepth 1 -type f -name '*.md' 2>/dev/null; } | sort)"
  for f in $targets; do
    lines=(); mut=()
    while IFS= read -r line || [ -n "$line" ]; do lines[${#lines[@]}]="$line"; done < "$f"
    # Flag every line of a fenced block that contains the word "mutation".
    infence=0; start=0; hasmut=0
    for ((i = 0; i < ${#lines[@]}; i++)); do
      mut[$i]=0
      case "${lines[$i]}" in
        *'```'*)
          if [ "$infence" -eq 0 ]; then
            infence=1; start=$i; hasmut=0
          else
            infence=0
            if [ "$hasmut" -eq 1 ]; then
              for ((n = start; n <= i; n++)); do mut[$n]=1; done
            fi
          fi ;;
        *mutation*) [ "$infence" -eq 1 ] && hasmut=1 ;;
      esac
    done
    for ((i = 0; i < ${#lines[@]}; i++)); do
      line="${lines[$i]}"
      case "$line" in *'<!-- lint:gh-ok -->'*) continue ;; esac
      rest="$line"
      while [[ "$rest" =~ $GH_TOKEN_RE ]]; do
        rest="${BASH_REMATCH[2]}"
        [[ "$rest" =~ $GH_CMD_RE ]] || continue   # prose ("gh and", "gh preflight")
        if [[ "$rest" =~ $GH_READ_RE ]]; then continue; fi
        case "$rest" in
          'api graphql'*)
            case "$line" in
              *mutation*) ;;
              *) [ "${mut[$i]}" -eq 0 ] && continue ;;
            esac ;;
          api*'-X GET'*) continue ;;
        esac
        hit=0
        for ((n = 0; n < ${#a_files[@]}; n++)); do
          [ "${a_files[$n]}" = "$f" ] || continue
          if printf '%s\n' "gh $rest" | grep -Eq -- "${a_res[$n]}"; then hit=1; break; fi
        done
        [ "$hit" -eq 1 ] && continue
        cmd="$(printf '%s' "$rest" | cut -c1-50)"
        fail "$f:$((i + 1)): 'gh $cmd' is not a read form, not in $allow, and the line lacks <!-- lint:gh-ok --> -- route writes through a script"
      done
    done
  done
  [ "$VIOLATIONS" -eq "$before" ] && ok "every gh token in skills/agents is a read, lint:gh-ok, or allowlisted"
}

# ---------------------------------------------------------------------
# Check 7: LABEL_STATE_MACHINE.md rows <-> scripts/test-squad-labels.sh.
# Table rows start "| <id> |" (id = L<n> or D); the "Performed by" cell is $5 (the 4th
# visible cell, because of the leading empty field). Tests are `check "<id> ..."` / `check "D-..."` lines.
# ---------------------------------------------------------------------
check_label_doc_tests() {
  local before="$VIOLATIONS" doc=LABEL_STATE_MACHINE.md tf=scripts/test-squad-labels.sh
  local row id by rows tests t
  section "7. label doc rows tied to tests"
  if [ ! -f "$doc" ] || [ ! -f "$tf" ]; then
    fail "$doc or $tf missing -- cannot tie label rows to tests"
    return
  fi
  rows="$(awk -F'|' '/^\| *(L[0-9]+|D) *\|/ {
    id=$2; by=$5; gsub(/^ +| +$/, "", id)
    if (by ~ /squad-labels\.sh/) print id }' "$doc")"
  tests="$(grep -oE 'check "(L[0-9]+ |D-)' "$tf" | sed -E 's/^check "//; s/ $//; s/^D-$/D/' | sort -u)"
  for id in $rows; do
    printf '%s\n' "$tests" | grep -qx "$id" \
      || fail "$doc: script-performed row $id has no test named \"$id ...\" (or \"D-...\") in $tf"
  done
  for t in $tests; do
    printf '%s\n' "$rows" | grep -qx "$t" \
      || fail "$tf: test id $t has no script-performed row in $doc"
  done
  [ "$VIOLATIONS" -eq "$before" ] && ok "every script-performed label row has tests and vice versa"
}

# ---------------------------------------------------------------------
# Check 8: every ${CLAUDE_PLUGIN_ROOT}/hooks/<x>.sh referenced by a skill or
# agent ships as claude/hooks/<x>.sh; the copy-install path is gone.
# ---------------------------------------------------------------------
check_hook_refs_exist() {
  local before="$VIOLATIONS" f ref
  section "8. referenced hooks exist"
  while IFS= read -r f; do
    for ref in $(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/hooks/[A-Za-z0-9_.-]+\.(sh|py)' "$f" | sort -u); do
      [ -f "claude/hooks/${ref##*/}" ] || fail "$f references $ref but claude/hooks/${ref##*/} does not exist"
    done
    if grep -qE '~/\.claude/hooks/' "$f"; then
      fail "$f references ~/.claude/hooks/; use \${CLAUDE_PLUGIN_ROOT}/hooks/ (the plugin root)"
    fi
  done < <(find claude/skills -type f -name '*.md' 2>/dev/null; find claude/agents -maxdepth 1 -type f -name '*.md' 2>/dev/null)
  [ "$VIOLATIONS" -eq "$before" ] && ok "every referenced hook script ships in claude/hooks/"
}

# ---------------------------------------------------------------------
# Check 9: plugin layout. The manifest names the plugin, hooks.json only
# registers scripts that ship, and no agent uses frontmatter keys that plugin
# subagents silently ignore.
# ---------------------------------------------------------------------
check_plugin_layout() {
  local before="$VIOLATIONS" f key cmd script
  section "9. plugin layout"
  if [ ! -f claude/.claude-plugin/plugin.json ]; then
    fail "claude/.claude-plugin/plugin.json is missing"
  else
    for key in name version description; do
      grep -qE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" claude/.claude-plugin/plugin.json \
        || fail "claude/.claude-plugin/plugin.json has no \"$key\" string"
    done
  fi
  if [ ! -f claude/hooks/hooks.json ]; then
    fail "claude/hooks/hooks.json is missing"
  else
    for script in $(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/hooks/[A-Za-z0-9_.-]+' claude/hooks/hooks.json | sort -u); do
      [ -f "claude/hooks/${script##*/}" ] || fail "claude/hooks/hooks.json registers $script but claude/hooks/${script##*/} does not exist"
    done
    grep -q 'lore-orient.sh' claude/hooks/hooks.json || fail "claude/hooks/hooks.json does not register lore-orient.sh"
    grep -q 'lore-checkpoint.sh' claude/hooks/hooks.json || fail "claude/hooks/hooks.json does not register lore-checkpoint.sh"
    grep -q 'cody-checkpoint.sh' claude/hooks/hooks.json || fail "claude/hooks/hooks.json does not register cody-checkpoint.sh"
  fi
  while IFS= read -r f; do
    # Frontmatter only: lines between the first two '---'.
    for key in hooks mcpServers permissionMode initialPrompt; do
      if awk -v k="$key" 'NR==1&&$0!="---"{exit} /^---$/{n++; if(n==2)exit; next} n==1 && $0 ~ "^"k":"{found=1} END{exit !found}' "$f"; then
        fail "$f sets frontmatter key '$key', which plugin subagents ignore"
      fi
    done
  done < <(find claude/agents -maxdepth 1 -type f -name '*.md' 2>/dev/null)
  [ "$VIOLATIONS" -eq "$before" ] && ok "plugin manifest, hooks.json and agent frontmatter are consistent"
}

# ---------------------------------------------------------------------
# Check 10: Reven's description-drift block is mandatory and Ralph applies it
# ---------------------------------------------------------------------
check_description_drift() {
  local before="$VIOLATIONS" r=claude/agents/reven.md k=claude/skills/ralph/SKILL.md
  section "10. description drift section"
  if [ ! -f "$r" ]; then
    fail "$r is missing"
  else
    grep -q '^## Description drift$' "$r" || fail "$r has no '## Description drift' section"
    # Present in the output template (a fenced line) and in the grammar section.
    [ "$(grep -c '^## Description drift' "$r")" -ge 2 ] || fail "$r must carry the section in both its output template and its grammar"
    grep -q -- '- none: ' "$r" || fail "$r does not define the '- none: <reason>' form"
    grep -q -- '- line: ' "$r" && grep -q -- '- add: ' "$r" || fail "$r does not define the line/to and add items"
  fi
  if [ ! -f "$k" ]; then
    fail "$k is missing"
  else
    grep -q 'hooks/squad-pr-desc.sh' "$k" || fail "$k does not apply the block through squad-pr-desc.sh"
  fi
  [ "$VIOLATIONS" -eq "$before" ] && ok "Reven requires the description-drift section; Ralph applies it via squad-pr-desc.sh"
}

# ---------------------------------------------------------------------
# Check 11: test scripts create their scratch root through the safe helper
# ---------------------------------------------------------------------
check_safe_test_tmproot() {
  local before="$VIOLATIONS" f n line
  section "11. safe test tmp root"
  if [ ! -f scripts/lib/test-tmp.sh ]; then
    fail "scripts/lib/test-tmp.sh is missing"
  fi
  for f in scripts/test-*.sh; do
    [ -f "$f" ] || continue
    while IFS= read -r n; do
      line="$(sed -n "${n}p" "$f")"
      case "$line" in *"lint:tmp-ok"*) continue ;; esac
      fail "$f:$n creates a temp dir outside scripts/lib/test-tmp.sh (use test_tmp_init): $line"
    done < <(grep -nE '^[^#]*(\$\(|`)[[:space:]]*mktemp([[:space:]]|\))' "$f" | grep -vE 'mktemp[^)]*"\$\{?(TMPROOT|TMP|tmp)\}?/' | cut -d: -f1)
    while IFS= read -r n; do
      line="$(sed -n "${n}p" "$f")"
      case "$line" in *"lint:tmp-ok"*) continue ;; esac
      fail "$f:$n installs a raw rm -rf trap (use test_tmp_init, whose trap is guarded): $line"
    done < <(grep -nE "^[^#]*trap '[^']*rm -rf" "$f" | cut -d: -f1)
  done
  [ "$VIOLATIONS" -eq "$before" ] && ok "every test script uses the guarded temp root helper"
}

check_path_resolution_protocol
check_parity
check_config_field_cross_references
check_dangling_doc_pointers
check_delegation_tool
check_gh_write_ban
check_label_doc_tests
check_hook_refs_exist
check_plugin_layout
check_description_drift
check_safe_test_tmproot

printf '\n== summary ==\n'
if [ "$VIOLATIONS" -gt 0 ]; then
  printf '%d violation(s) found.\n' "$VIOLATIONS"
  exit 1
fi
printf 'No violations found.\n'
exit 0
