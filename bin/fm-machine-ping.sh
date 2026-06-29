#!/usr/bin/env bash
# fm-machine-ping.sh — reachability probe for the multi-machine fleet (M4).
#
# Probe a registered machine over its transport (a cheap non-interactive `ssh
# <host> true`) and record the result back into the registry data/machines.md as
# the line's `status:` (online|offline) and `last-seen <date>` fields. The probe
# is the live-state maintainer for those two fields; the captain-set `reachability:`
# hint is never touched. The wire lives ONLY here and ONLY on the slow cadence
# (bootstrap once per session, the watcher heartbeat review by hand); it never runs
# on the tight signal/stale poll. A sleeping or off-tailnet box fails CLEANLY and
# fast (BatchMode + ConnectTimeout, baked into the ssh-prefix) and is recorded
# offline — never a confusing hang. The whole probe is non-fatal: every path exits
# 0 so it is safe to wire into bootstrap and the heartbeat.
#
# Offline routing (AGENTS.md §§8, 10, 14): an offline box does not fail a dispatch.
# Work routed to it is queued in the backlog with an `awaiting-machine: <id>`
# blocker (mirroring `blocked-by:`); the next probe that flips the box online lets
# the heartbeat re-dispatch it. This script only maintains the status truth the
# captain/heartbeat acts on; it never edits the backlog itself.
#
# Usage:
#   fm-machine-ping.sh                 probe + record every REMOTE registered machine
#                                      (local/hub-transport machines are skipped).
#                                      Prints one "<id>: online|offline" line each.
#   fm-machine-ping.sh <id>...         probe + record the named machine(s).
#   fm-machine-ping.sh check <id>      probe ONLY (no registry write); exit 0 if the
#                                      box answered, non-zero if not. Prints
#                                      "<id>: online|offline". For a caller that
#                                      needs a clean reachability yes/no before it
#                                      routes work (e.g. fm-spawn's remote path).
#
# Determinism for tests: FM_PING_DATE overrides the recorded last-seen date, and
# FM_MACHINES_BIN overrides the registry-parser path. The probe command itself is a
# plain `ssh ... true`, so a fake `ssh` on PATH exercises every branch with no real
# network.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/machines.md"
FM_MACHINES_BIN="${FM_MACHINES_BIN:-$SCRIPT_DIR/fm-machines.sh}"

# Per-probe wall-clock bound. The ssh-prefix already bakes in ConnectTimeout, but a
# wrapper timeout caps a box that accepts the connection then stalls. Bounded but
# generous so a slow-but-live box is not misreported offline.
PING_TIMEOUT=${FM_PING_TIMEOUT:-10}

today() {
  if [ -n "${FM_PING_DATE:-}" ]; then
    printf '%s\n' "$FM_PING_DATE"
  else
    date +%F
  fi
}

# Probe one machine over its transport. Echoes nothing; returns 0 iff the box
# answered. A local/hub machine (no ssh transport) has no remote to probe, so it is
# treated as not-probeable and returns 2 (caller skips it).
probe_machine() {  # <id>
  local id=$1 prefix
  if ! prefix=$("$FM_MACHINES_BIN" ssh-prefix "$id" 2>/dev/null) || [ -z "$prefix" ]; then
    return 2
  fi
  # shellcheck disable=SC2086  # prefix is a deliberate ssh command word list.
  if command -v timeout >/dev/null 2>&1; then
    timeout "$PING_TIMEOUT" $prefix true </dev/null >/dev/null 2>&1
  else
    $prefix true </dev/null >/dev/null 2>&1
  fi
}

# Rewrite the matching registry line's status: and last-seen fields in place. Both
# fields are replaced when present, or inserted before the closing ")" when absent,
# so a hand-written line missing them is upgraded rather than left stale. Atomic
# temp-then-rename; reachability: and every other field are untouched.
record_status() {  # <id> <status> <date>
  local id=$1 status=$2 date=$3 tmp
  [ -f "$REG" ] || return 0
  tmp="$REG.tmp.$$"
  if awk -v id="$id" -v st="$status" -v dt="$date" '
    $1=="-" && $2==id && $0 ~ /\(/ {
      line=$0
      if (line ~ /status:[ ]*[^;)]*/) sub(/status:[ ]*[^;)]*/, "status: " st, line)
      else                            sub(/\)[[:space:]]*$/, "; status: " st ")", line)
      if (line ~ /last-seen[ ]+[^;)]*/) sub(/last-seen[ ]+[^;)]*/, "last-seen " dt, line)
      else                              sub(/\)[[:space:]]*$/, "; last-seen " dt ")", line)
      print line
      next
    }
    { print }
  ' "$REG" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$REG"
  else
    rm -f "$tmp"
  fi
}

# Probe one machine and record the result. Echoes "<id>: online|offline".
ping_and_record() {  # <id>
  local id=$1 rc
  probe_machine "$id"; rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "$id: skipped (local/hub machine, nothing to probe)" >&2
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    record_status "$id" online "$(today)"
    echo "$id: online"
  else
    record_status "$id" offline "$(today)"
    echo "$id: offline"
  fi
  return 0
}

cmd=${1:-}
case "$cmd" in
  check)
    id=${2:?usage: fm-machine-ping.sh check <id>}
    if ! "$FM_MACHINES_BIN" validate "$id" >/dev/null 2>&1; then
      echo "$id: not a registered machine" >&2
      exit 2
    fi
    if probe_machine "$id"; then
      echo "$id: online"
      exit 0
    fi
    echo "$id: offline"
    exit 1
    ;;
  -h|--help|help)
    sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  '')
    # Probe every remote machine in the registry. Local/hub machines (no ssh
    # transport) are skipped by probe_machine's rc=2.
    [ -f "$REG" ] || { echo "note: no machine registry at $REG; nothing to probe" >&2; exit 0; }
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      ping_and_record "$id"
    done < <("$FM_MACHINES_BIN" list 2>/dev/null)
    ;;
  *)
    # One or more explicit machine ids.
    for id in "$@"; do
      if ! "$FM_MACHINES_BIN" validate "$id" >/dev/null 2>&1; then
        echo "$id: not a registered machine" >&2
        continue
      fi
      ping_and_record "$id"
    done
    ;;
esac
exit 0
