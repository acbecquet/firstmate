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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
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
if [ -z "$FMX_TOKEN" ]; then
  echo "fm-x-reply: X mode not configured (no FMX_PAIRING_TOKEN)" >&2
  exit 1
fi
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "fm-x-reply: $tool not found" >&2; exit 1; }
done

# Build the body with jq so the text is correctly JSON-escaped.
PAYLOAD=$(jq -nc --arg rid "$REQ" --arg text "$TEXT" '{request_id:$rid, text:$text}') || {
  echo "fm-x-reply: failed to build request payload" >&2
  exit 1
}
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
