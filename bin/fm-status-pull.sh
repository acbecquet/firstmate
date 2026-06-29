#!/usr/bin/env bash
# fm-status-pull.sh — status carry-back for REMOTE secondmates.
#
# A remote secondmate runs as a full firstmate in its own home on another box; the
# hub reaches it over the transport (ssh) for exactly two operations: one marked
# work line IN (fm-send.sh), and one status line OUT (this script). On the box, the
# secondmate appends its hub-bound status/escalation lines to its OWN home's
#   <remote-fm-home>/state/<id>.status
# (the same path the local-secondmate charter retargets escalation to, but on the
# box rather than a shared filesystem). This script pulls that file over ssh and
# mirrors it into the hub's LOCAL state/<id>.status, so the hub watcher's
# scan_signals — a local size:mtime poll — wakes on the new lines through the
# ordinary signal path. No change to the tight 15s watcher loop is needed.
#
# Where the network lives: ONLY here. Run it on the watcher's slow check cadence
# via `arm` (the same mechanism the merged-PR poll uses), or by hand during a
# heartbeat review. It is never called from the 15s signal/stale poll. A pull
# writes the local file only when the remote content actually changed, so an
# unchanged remote produces no spurious wake; the remote status file is
# append-only, so a content mirror is delta-preserving.
#
# Clean failure: an unreachable box (asleep / off the tailnet) writes nothing,
# notes one line to stderr, and still exits 0 — so an arming check never errors
# and the hub simply keeps the last-known status until the box returns.
#
# Per-id resolution (from state/<id>.meta + the machine registry):
#   machine       = meta machine=            (must be a non-hub registered machine)
#   ssh prefix    = fm-machines.sh ssh-prefix <machine>
#   remote home   = meta remote_home=  else registry fm-home for <machine>
#   remote status = meta remote_status= else <remote-home>/state/<id>.status
#
# Usage:
#   fm-status-pull.sh [<id>...]   pull now for the given remote-secondmate ids, or
#                                 for every kind=secondmate meta with a non-hub
#                                 machine= when no id is given. Stdout stays empty.
#   fm-status-pull.sh arm <id>    write state/<id>.check.sh so the watcher runs the
#                                 pull on its check cadence (network off the tight loop).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_MACHINES_BIN="${FM_MACHINES_BIN:-$SCRIPT_DIR/fm-machines.sh}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"   # fm_shquote for safe remote-path quoting

meta_field() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Pull and mirror one remote-secondmate's status. Diagnostics -> stderr only;
# stdout is left empty so this is wake-neutral when run as a watcher check (the
# wake comes from scan_signals noticing the mirrored local file). Always 0.
pull_one() {
  local id=$1
  local meta="$STATE/$id.meta" machine prefix rhome rstatus remote current
  if [ ! -f "$meta" ]; then
    echo "note: no meta for \"$id\"; skipped" >&2
    return 0
  fi
  machine=$(meta_field "$meta" machine)
  case "$machine" in
    ""|hub)
      echo "note: \"$id\" is not a remote machine target (machine=\"$machine\"); skipped" >&2
      return 0 ;;
  esac
  if ! prefix=$("$FM_MACHINES_BIN" ssh-prefix "$machine" 2>/dev/null) || [ -z "$prefix" ]; then
    echo "note: no transport prefix for machine \"$machine\" (id \"$id\"); skipped" >&2
    return 0
  fi
  rhome=$(meta_field "$meta" remote_home)
  [ -n "$rhome" ] || rhome=$("$FM_MACHINES_BIN" get "$machine" fm-home 2>/dev/null || true)
  rstatus=$(meta_field "$meta" remote_status)
  if [ -z "$rstatus" ]; then
    if [ -z "$rhome" ]; then
      echo "note: cannot resolve remote status path for \"$id\" (no remote_home/registry fm-home); skipped" >&2
      return 0
    fi
    rstatus="$rhome/state/$id.status"
  fi

  # cat the remote status file over the transport. ssh failure (unreachable box)
  # or a missing remote file both leave remote unset -> clean skip.
  # shellcheck disable=SC2086  # prefix is a deliberate ssh command word list.
  if ! remote=$(${prefix} "cat $(fm_shquote "$rstatus")" 2>/dev/null); then
    echo "note: machine \"$machine\" unreachable or status absent for \"$id\"; skipped" >&2
    return 0
  fi

  current=''
  [ -f "$STATE/$id.status" ] && current=$(cat "$STATE/$id.status")
  if [ "$remote" != "$current" ]; then
    # Append-only remote: a normal pull is a pure append (current is a prefix of
    # remote); a non-prefix means the box reset its file, so mirror it wholesale.
    # Either way write atomically so scan_signals sees one clean signature change.
    printf '%s\n' "$remote" > "$STATE/$id.status.tmp.$$"
    mv "$STATE/$id.status.tmp.$$" "$STATE/$id.status"
    echo "pulled: \"$id\" status mirrored from \"$machine\"" >&2
  fi
  return 0
}

discover_remote_ids() {
  local meta id machine
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    machine=$(meta_field "$meta" machine)
    case "$machine" in ""|hub) continue ;; esac
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

cmd=${1:-}
case "$cmd" in
  arm)
    id=${2:?usage: fm-status-pull.sh arm <id>}
    cat > "$STATE/$id.check.sh" <<EOF
# Status carry-back for remote secondmate "$id" (written by fm-status-pull.sh arm).
# Mirrors the box's state/$id.status into the hub's local state/$id.status; the
# watcher's scan_signals wakes on the mirrored file. Stdout stays empty here so no
# direct check-wake fires (the signal scan does the waking). Runs on the watcher's
# check cadence (FM_CHECK_INTERVAL), keeping the network off the tight poll loop.
"$SCRIPT_DIR/fm-status-pull.sh" "$id" >/dev/null 2>&1 || true
EOF
    echo "armed: state/$id.check.sh pulls \"$id\" status on the watcher check cadence"
    ;;

  -h|--help|help)
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    # No subcommand: pull. With ids, pull those; without, discover and pull every
    # remote secondmate. ($cmd is $1, so a bare id reaches here as the first arg.)
    if [ "$#" -gt 0 ]; then
      for id in "$@"; do pull_one "$id"; done
    else
      ids=$(discover_remote_ids)
      if [ -n "$ids" ]; then
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          pull_one "$id"
        done <<EOF
$ids
EOF
      fi
    fi
    ;;
esac
