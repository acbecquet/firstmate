#!/usr/bin/env bash
# Parse the machine registry data/machines.md: the fleet of machines the hub can
# orchestrate crewmate work on (the local hub plus remote boxes reached over a
# transport such as tailscale-ssh). This is the read-only registry parser; it
# never reaches across the network and never mutates the registry.
#
# Registry line format (data/machines.md), one machine per line:
#   - <id> - <desc> (host: <host>; transport: <transport>; reachability: <r>; \
#       fm-home: <path>; harness: <harness>; tmux-session: <session>; \
#       auth: <reference>; status: <status>; last-seen <date>)
#
# Fields are "key: value" separated by "; " inside the parenthesised block,
# except "last-seen <date>" which (like "added <date>" elsewhere) uses a space.
# auth: is ALWAYS a reference (tailnet ACL, ssh-agent, hub key path), never a
# secret; secrets live on each box. tmux-session: is authoritative for any remote
# peek and must be validated so a remote peek can never read a stranger's pane.
#
# Example seed lines (data/machines.md is firstmate-private and gitignored, so
# these live here and in docs/multimachine-onboarding.md as the copy-paste source,
# not as tracked data):
#   - cabin-desktop - cabin Windows box, WSL2 (host: cabin-desktop.tailnet.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)
#   - desktop-bgiv1ph - Charlie's Workstation, Windows/WSL2 (host: desktop-bgiv1ph.tailnet.ts.net; transport: tailscale-ssh; reachability: intermittent; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: offline; last-seen 2026-06-29)
#   - s102000028774 - SDR Windows box, WSL2 (host: s102000028774.tailnet.ts.net; transport: tailscale-ssh; reachability: intermittent; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: offline; last-seen 2026-06-27)
#
# Lines whose first token is not "-" (markdown headers, "#" notes, "<!-- -->"
# comments) are ignored, so the captain can keep commented example/seed lines in
# the file without confusing the parser.
#
# Usage:
#   fm-machines.sh list                 print every machine id, one per line
#   fm-machines.sh get <id> <field>     print one field value for <id>
#   fm-machines.sh fields <id>          print all of <id>'s fields as key=value
#   fm-machines.sh validate <id>        exit 0 iff <id> is a valid, present machine
#   fm-machines.sh ssh-prefix <id>      print the transport command prefix
#                                       (e.g. "ssh <host>") for reaching <id>
#
# Fields: host transport reachability fm-home harness tmux-session auth status
#         last-seen desc
#
# ssh-prefix maps a machine's transport+host to the command words placed before a
# remote `tmux ...` call: for transport tailscale-ssh|ssh it emits
# "ssh <FM_SSH_OPTS> <host>". This stays a pure string resolution — it never
# opens a connection. The emitted prefix is what fm-transport-lib.sh exports as
# FM_TMUX_SSH so fm_tmux (bin/fm-tmux-lib.sh) transports the call.
#
# A missing registry is not fatal: `list` prints nothing and warns to stderr;
# `get`/`fields`/`validate` exit non-zero. An unknown machine id or an absent
# field exits non-zero with a stderr message, so a typo never resolves silently.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/machines.md"

# Default ssh options baked into an ssh-prefix: fail fast and never block on a
# password prompt, so a sleeping or off-tailnet box fails CLEANLY instead of
# hanging a supervision call. Override with FM_SSH_OPTS; set FM_SSH_OPTS= (empty)
# to emit a bare "ssh <host>". Only defaulted when unset, so an explicit empty
# value is honored.
FM_SSH_OPTS=${FM_SSH_OPTS--o BatchMode=yes -o ConnectTimeout=8}

# A machine id is a kebab slug: lowercase alphanumerics and hyphens, starting
# with an alphanumeric. This guards remote-peek targets and registry lookups.
valid_id() {
  case "$1" in
    "" ) return 1 ;;
    *[!a-z0-9-]* ) return 1 ;;
    -* ) return 1 ;;
    * ) return 0 ;;
  esac
}

# Echo the raw registry line for <id> (the last match wins, mirroring the other
# registry parsers), or return 1 if absent.
machine_line() {
  local id=$1 line
  [ -f "$REG" ] || return 1
  line=$(awk -v n="$id" '$1=="-" && $2==n && $0 ~ /\(/ {found=$0} END{if(found!="")print found}' "$REG")
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# Extract one field from a registry line. Handles "key: value" pairs and the
# "last-seen <date>" space form, plus the synthetic "desc" field (the text
# between "- <id> - " and the " (" that opens the field block).
extract_field() {
  local line=$1 field=$2
  if [ "$field" = desc ]; then
    printf '%s\n' "$line" | sed -n 's/^- [^ ]* - \(.*\) (.*/\1/p'
    return 0
  fi
  printf '%s\n' "$line" | awk -v f="$field" '
    {
      s=$0
      i=index(s,"("); if(i==0) exit 1
      s=substr(s,i+1)
      j=index(s,")"); if(j>0) s=substr(s,1,j-1)
      n=split(s,parts,/; */)
      for(k=1;k<=n;k++){
        p=parts[k]
        if (match(p,/^[^: ]+:[ ]*/)) {
          key=substr(p,1,RLENGTH); sub(/:[ ]*$/,"",key)
          val=substr(p,RLENGTH+1)
        } else {
          sp=index(p," ")
          if(sp==0){key=p; val=""} else {key=substr(p,1,sp-1); val=substr(p,sp+1)}
        }
        gsub(/^[ \t]+|[ \t]+$/,"",key); gsub(/^[ \t]+|[ \t]+$/,"",val)
        if(key==f){print val; found=1}
      }
      if(!found) exit 2
    }'
}

cmd=${1:-}
case "$cmd" in
  list)
    if [ ! -f "$REG" ]; then
      echo "warn: no machine registry at $REG" >&2
      exit 0
    fi
    awk '$1=="-" && $0 ~ /\(/ {print $2}' "$REG"
    ;;

  get)
    id=${2:?usage: fm-machines.sh get <id> <field>}
    field=${3:?usage: fm-machines.sh get <id> <field>}
    line=$(machine_line "$id") || { echo "error: machine \"$id\" not in registry $REG" >&2; exit 1; }
    if value=$(extract_field "$line" "$field") && [ -n "$value" ]; then
      printf '%s\n' "$value"
    else
      echo "error: machine \"$id\" has no field \"$field\"" >&2
      exit 1
    fi
    ;;

  fields)
    id=${2:?usage: fm-machines.sh fields <id>}
    line=$(machine_line "$id") || { echo "error: machine \"$id\" not in registry $REG" >&2; exit 1; }
    for f in desc host transport reachability fm-home harness tmux-session auth status last-seen; do
      if value=$(extract_field "$line" "$f") && [ -n "$value" ]; then
        printf '%s=%s\n' "$f" "$value"
      fi
    done
    ;;

  validate)
    id=${2:?usage: fm-machines.sh validate <id>}
    if ! valid_id "$id"; then
      echo "error: \"$id\" is not a valid machine id (lowercase kebab slug expected)" >&2
      exit 1
    fi
    if ! machine_line "$id" >/dev/null; then
      echo "error: machine \"$id\" not in registry $REG" >&2
      exit 1
    fi
    ;;

  ssh-prefix)
    id=${2:?usage: fm-machines.sh ssh-prefix <id>}
    if ! valid_id "$id"; then
      echo "error: \"$id\" is not a valid machine id (lowercase kebab slug expected)" >&2
      exit 1
    fi
    line=$(machine_line "$id") || { echo "error: machine \"$id\" not in registry $REG" >&2; exit 1; }
    transport=$(extract_field "$line" transport 2>/dev/null || true)
    host=$(extract_field "$line" host 2>/dev/null || true)
    [ -n "$host" ] || { echo "error: machine \"$id\" has no host in registry $REG" >&2; exit 1; }
    case "$transport" in
      ""|hub|local)
        echo "error: machine \"$id\" is local (transport=\"$transport\"); no ssh transport prefix" >&2
        exit 1 ;;
      tailscale-ssh|ssh)
        # shellcheck disable=SC2086  # FM_SSH_OPTS is a deliberate word list.
        printf 'ssh %s%s\n' "${FM_SSH_OPTS:+$FM_SSH_OPTS }" "$host" ;;
      *)
        echo "error: machine \"$id\" has unsupported transport \"$transport\" (expected tailscale-ssh|ssh)" >&2
        exit 1 ;;
    esac
    ;;

  ""|-h|--help|help)
    sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
    [ "$cmd" = "" ] && exit 1 || exit 0
    ;;

  *)
    echo "error: unknown command \"$cmd\" (expected: list|get|fields|validate|ssh-prefix)" >&2
    exit 1
    ;;
esac
