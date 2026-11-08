#!/usr/bin/env bash
# squad-http.sh -- the HTTP plumbing shared by the REST adapters (tracker/jira.sh,
# vcs/bitbucket.sh). SOURCED (by the adapters); do not execute. Bash 3.2, needs
# curl. The only vendor-facing call is `curl` (the test seam is scripts/curl-shim/).
#
# squad_http_token <keychain service> <account> <env var name>
#   Prints the API token: the environment variable when set, else the macOS
#   keychain item (`security find-generic-password -s <service> -a <account> -w`).
#   Prints nothing (returns 1) when there is none. Never from a file.
# squad_http_call <METHOD> <url> <Authorization header value> [json body]
#   Sets SQUAD_HTTP_CODE (status) and SQUAD_HTTP_BODY (response body), and
#   SQUAD_HTTP_RC (curl's exit code). The credential is handed to curl through a
#   config file descriptor (-K <(...)), so it is on no argv and in no `ps`, and it
#   is never printed. Returns 0 when curl ran (the caller reads the status), 20
#   when it did not or a write was refused by squad_write_guard (non-GET calls
#   pass it first, unless SQUAD_HTTP_UNGUARDED=1: only for a verb the facade
#   documents as not gated on tracker mode, i.e. pr-create). Options by variable: SQUAD_HTTP_ACCEPT (default
#   application/json), SQUAD_HTTP_FOLLOW=1 (follow redirects; curl drops the
#   Authorization header when a redirect leaves the host).

squad_http_token() {
  local t="${!3:-}"
  if [ -z "$t" ] && command -v security >/dev/null 2>&1; then
    t="$(security find-generic-password -s "$1" -a "$2" -w 2>/dev/null)"
  fi
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}

squad_http_call() {
  local m="$1" url="$2" auth="$3" body="${4:-}" tmp opts
  SQUAD_HTTP_CODE=""; SQUAD_HTTP_BODY=""; SQUAD_HTTP_RC=0
  [ "$m" = GET ] || [ "${SQUAD_HTTP_UNGUARDED:-}" = 1 ] || squad_write_guard || return 20
  tmp="$(mktemp "${TMPDIR:-/tmp}/squad-http.XXXXXX")" || { echo "squad: http: mktemp failed" >&2; return 20; }
  opts=(-sS -o "$tmp" -w '%{http_code}' -X "$m" -H "Accept: ${SQUAD_HTTP_ACCEPT:-application/json}")
  [ "${SQUAD_HTTP_FOLLOW:-}" != 1 ] || opts+=(-L)
  if [ -n "$body" ]; then
    SQUAD_HTTP_CODE="$(printf '%s' "$body" | curl "${opts[@]}" \
      -K <(printf 'header = "Authorization: %s"\n' "$auth") \
      -H 'Content-Type: application/json' --data-binary @- "$url")" || SQUAD_HTTP_RC=$?
  else
    SQUAD_HTTP_CODE="$(curl "${opts[@]}" -K <(printf 'header = "Authorization: %s"\n' "$auth") "$url")" || SQUAD_HTTP_RC=$?
  fi
  SQUAD_HTTP_BODY="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
  [ "$SQUAD_HTTP_RC" -eq 0 ] || return 20
  return 0
}
