#!/usr/bin/env bash
# Shared config resolution for the X-mode connector client (fm-x-poll.sh and
# fm-x-reply.sh). X mode is opt-in: a user drops a non-empty FMX_PAIRING_TOKEN
# into the firstmate home's .env. Until then polling is a hard no-op; replies can
# still run in FMX_DRY_RUN preview mode without a token.
#
# This file is sourced, never executed. It defines:
#   fmx_env_get <key> <file>   - read one KEY=VALUE from a .env-style file
#   fmx_load_config            - resolve FMX_TOKEN, FMX_RELAY, and FMX_DRY
#                                (env wins over .env)
# Callers must have FM_HOME set before calling fmx_load_config.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fmx_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Resolve the X-mode settings into FMX_TOKEN, FMX_RELAY, and FMX_DRY. An explicit
# environment variable always wins over the .env file; the relay URL defaults to
# the production host so a normal user configures only the token. FMX_RELAY has
# any trailing slash trimmed so callers can append "/connector/..." cleanly.
# FMX_DRY is set to "1" when FMX_DRY_RUN is a truthy value (anything other than
# unset/empty/0/false/no/off), and "" otherwise: preview mode, where the client
# composes a reply but records it instead of posting (see fm-x-reply.sh).
fmx_load_config() {
  local env_file="${FMX_ENV_FILE:-$FM_HOME/.env}" dry
  if [ -n "${FMX_PAIRING_TOKEN+x}" ]; then
    FMX_TOKEN=${FMX_PAIRING_TOKEN-}
  else
    FMX_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")
  fi
  if [ -n "${FMX_RELAY_URL+x}" ]; then
    FMX_RELAY=${FMX_RELAY_URL-}
  else
    FMX_RELAY=$(fmx_env_get FMX_RELAY_URL "$env_file")
  fi
  [ -n "$FMX_RELAY" ] || FMX_RELAY="https://myfirstmate.io"
  FMX_RELAY=${FMX_RELAY%/}
  if [ -n "${FMX_DRY_RUN+x}" ]; then
    dry=${FMX_DRY_RUN-}
  else
    dry=$(fmx_env_get FMX_DRY_RUN "$env_file")
  fi
  # shellcheck disable=SC2034 # FMX_DRY is read by callers (fm-x-reply.sh) after sourcing.
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) FMX_DRY="" ;;
    *) FMX_DRY=1 ;;
  esac
}

fmx_auth_header_file() {
  local file
  case "$FMX_TOKEN" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-x-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bearer %s\n' "$FMX_TOKEN" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}
