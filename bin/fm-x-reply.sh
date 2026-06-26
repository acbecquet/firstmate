#!/usr/bin/env bash
# Post firstmate's composed answer back to the relay for a pending X mention.
#
# Usage: fm-x-reply.sh <request_id> <text>
#        fm-x-reply.sh <request_id> --text-file <path>   # read the reply from a file
#        fm-x-reply.sh <request_id> -                    # read the reply from stdin
#
# The --text-file / stdin forms exist so a caller never has to inline reply text
# (which may be influenced by a public mention) into a shell command, where shell
# expansion or quote-breakage could bite. fmx-respond uses them; the positional
# <text> form is kept for back-compat and tests.
#
# POSTs {request_id, text} to $RELAY/connector/answer with the bearer token. The
# relay binds the reply to the exact tweet it recorded for that request_id, so
# this client only ever echoes the relay-issued request_id and NEVER names a
# tweet id. On success it echoes ONLY that request_id; on a non-2xx (or transport
# failure) it exits non-zero so the caller knows the post did not land.
#
# Config (home .env or env): FMX_PAIRING_TOKEN (required), FMX_RELAY_URL
# (default https://myfirstmate.io). Auth: Authorization: Bearer <token>.
#
# Preview / dry-run: with FMX_DRY_RUN set (truthy), the reply is NOT posted.
# Instead the would-be POST body {request_id, text} is recorded to
# state/x-outbox/<request_id>.json and a one-line "DRY RUN" summary is printed to
# stderr; stdout still echoes the request_id and the exit is 0, so the loop runs
# end to end without a public tweet. Dry-run needs neither a token nor the relay.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

REQ=${1:-}
if [ -z "$REQ" ] || [ "$#" -lt 2 ]; then
  echo "usage: fm-x-reply.sh <request_id> <text> | <request_id> --text-file <path> | <request_id> -" >&2
  exit 2
fi
shift
case "$1" in
  --text-file)
    if [ "$#" -lt 2 ]; then
      echo "usage: fm-x-reply.sh <request_id> --text-file <path>" >&2
      exit 2
    fi
    TEXT=$(cat -- "$2") || { echo "fm-x-reply: cannot read text file: $2" >&2; exit 1; }
    ;;
  -)
    TEXT=$(cat)
    ;;
  *)
    TEXT=$1
    ;;
esac
if [ -z "$TEXT" ]; then
  echo "fm-x-reply: empty reply text" >&2
  exit 2
fi

fmx_load_config

# The request_id becomes a filename (inbox/outbox record), so never trust it into
# a path even though the relay issues it.
case "$REQ" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-reply: unsafe request_id: $REQ" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-x-reply: jq not found" >&2; exit 1; }
# Build the body with jq so the text is correctly JSON-escaped. This is exactly
# what would be POSTed (and, in dry-run, exactly what we record/preview).
PAYLOAD=$(jq -nc --arg rid "$REQ" --arg text "$TEXT" '{request_id:$rid, text:$text}') || {
  echo "fm-x-reply: failed to build request payload" >&2
  exit 1
}

# Preview / dry-run: surface what we WOULD post and stop, without auth or network.
if [ -n "$FMX_DRY" ]; then
  recorded=""
  if mkdir -p "$STATE/x-outbox" 2>/dev/null; then
    printf '%s\n' "$PAYLOAD" > "$STATE/x-outbox/$REQ.json" 2>/dev/null \
      && recorded=" (recorded: state/x-outbox/$REQ.json)"
  fi
  printf 'fm-x-reply: DRY RUN - would POST to %s/connector/answer%s: %s\n' \
    "$FMX_RELAY" "$recorded" "$TEXT" >&2
  printf '%s\n' "$REQ"
  exit 0
fi

if [ -z "$FMX_TOKEN" ]; then
  echo "fm-x-reply: X mode not configured (no FMX_PAIRING_TOKEN)" >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "fm-x-reply: curl not found" >&2; exit 1; }
AUTH_HEADER_FILE=$(fmx_auth_header_file) || {
  echo "fm-x-reply: invalid FMX_PAIRING_TOKEN" >&2
  exit 1
}
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT

code=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
  -X POST \
  -H "@$AUTH_HEADER_FILE" \
  -H 'Content-Type: application/json' \
  --data "$PAYLOAD" \
  "$FMX_RELAY/connector/answer" 2>/dev/null) || {
  echo "fm-x-reply: request to relay failed" >&2
  exit 1
}

case "$code" in
  2[0-9][0-9]) printf '%s\n' "$REQ" ;;
  *) echo "fm-x-reply: relay returned HTTP $code" >&2; exit 1 ;;
esac
