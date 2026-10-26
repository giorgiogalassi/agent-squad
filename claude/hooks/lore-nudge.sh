#!/usr/bin/env bash
# lore-nudge.sh -- opt-in Stop hook (#331): at turn end, ask a small model
# whether the turn settled a user-confirmed choice that decisions.md does not
# hold yet, and if so make Claude propose `lore decide "<one line>"`.
#
# Why a command hook and not `type: prompt`: a prompt hook is always a model
# call (no cheap gate) and its only outputs are {ok, reason}; it cannot be
# switched off by a setting. So the gate is this shell script and the judge is
# one `claude -p` call that runs only when the gate is open.
# Why `decision: block`: Stop has no additionalContext field; blocking the stop
# with a `reason` is the supported way to hand Claude text and make it speak
# once more. stop_hook_active ends the loop after that one extra turn.
#
# Gate (cheap, no model): `lore.nudge` is true in <vault>/lore-config.json AND
# the session's project is mapped in `projects`. Otherwise: silent exit 0.
# Never writes: the nudge only asks Claude to propose the command and wait.
# Needs jq and claude on PATH; without either it stays silent.
# Input (stdin, JSON): cwd, transcript_path, stop_hook_active. Exit: always 0.
set -u

[ -z "${LORE_NUDGE_CHILD:-}" ] || exit 0   # the judge's own session must not nudge
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" != true ] || exit 0

VAULT="${SECOND_BRAIN_PATH:-$HOME/second-brain}"
CONFIG="$VAULT/lore-config.json"
[ -f "$CONFIG" ] || exit 0
[ "$(jq -r '.lore.nudge // false' "$CONFIG" 2>/dev/null)" = true ] || exit 0

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$CWD" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RESOLVED="$(bash "$HOOK_DIR/path-resolve.sh" 2>/dev/null)" || exit 0
NAME="$(printf '%s\n' "$RESOLVED" | sed -n 's/^DISPLAY_NAME=//p')"
[ -n "$NAME" ] || exit 0   # not a vault-mapped project
command -v claude >/dev/null 2>&1 || exit 0

# The turn: last real user message plus everything the assistant said after it.
TURN="$(jq -rs '
  def txt: if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end;
  [.[] | select((.type == "user" or .type == "assistant") and (.isSidechain | not))
       | {t: .type, s: (.message.content | txt)} | select(.s != "")] as $m
  | (([range(0; $m | length)] | map(select($m[.].t == "user")) | last) // 0) as $i
  | $m[$i:] | map((if .t == "user" then "USER: " else "ASSISTANT: " end) + .s) | join("\n\n")
' "$TRANSCRIPT" 2>/dev/null | head -c 8000)"
[ -n "$TURN" ] || exit 0

DEC="$VAULT/projects/$NAME/decisions.md"
KNOWN=""
[ -f "$DEC" ] && KNOWN="$(grep -E '^## \[' "$DEC" | tail -n 40)"

PROMPT="You judge one finished turn of a coding conversation.
Question: did this turn settle a choice the USER confirmed (a design, a scope, a rule) that is not yet in the project's decision log?
Answer with exactly one line and nothing else:
NO
or
YES: <short title>: <one-sentence body>
Answer NO for questions, exploration, plans the user has not confirmed, routine edits, and anything already covered by the log headings below.

DECISION LOG HEADINGS:
$KNOWN

TURN:
$TURN"

ANSWER="$(printf '%s' "$PROMPT" | LORE_NUDGE_CHILD=1 claude -p --model haiku 2>/dev/null | sed -n '/^YES:/{p;q;}')"
case "$ANSWER" in "YES: "?*) ;; *) exit 0 ;; esac
LINE="${ANSWER#YES: }"
LINE="$(printf '%s' "$LINE" | tr -d '\n' | head -c 300)"

REASON="Lore noticed a possible unrecorded decision: ${LINE}
In one short sentence, propose recording it with: lore decide \"${LINE}\" -- then stop and wait for the user to confirm or decline. Do not run it yourself and do not write decisions.md."
jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
