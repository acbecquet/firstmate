#!/usr/bin/env bash
# fm-transport-lib.sh — opt-in resolution of a REMOTE machine target into the
# FM_TMUX_SSH transport prefix consumed by fm_tmux (bin/fm-tmux-lib.sh). Sourced
# by fm-send.sh and fm-peek.sh AFTER they resolve a tmux target, so a target that
# belongs to a remote machine is transported as `ssh <host> tmux ...`, while a
# local target stays byte-for-byte a plain local `tmux` call (FM_TMUX_SSH unset).
#
# Targeting convention — a target resolves to a machine by this precedence,
# first match wins:
#   1. FM_TMUX_SSH already set & non-empty -> used verbatim, no registry lookup
#      (explicit override, loopback tests, hand-driven remote calls).
#   2. FM_TARGET_MACHINE=<id>              -> resolve <id> via fm-machines.sh.
#   3. meta `machine=<id>` for a bare fm-<id> target (the spawned-remote path).
#   Anything resolving to empty or `hub` is LOCAL: FM_TMUX_SSH stays unset and the
#   tmux command path is unchanged.
#
# Stranger-pane guard (AGENTS.md §14): for a registry-resolved machine, the tmux
# SESSION component of the target must equal the machine's registry tmux-session,
# or the call is refused. tmux-session is authoritative; a remote peek can never
# read a window in a session the registry did not sanction. An explicit FM_TMUX_SSH
# override skips this guard — the caller has taken responsibility for the target.

FM_TRANSPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Path to the registry parser; overridable for tests.
FM_MACHINES_BIN="${FM_MACHINES_BIN:-$FM_TRANSPORT_LIB_DIR/fm-machines.sh}"

# fm_transport_arm <raw_target> <resolved_window> <state_dir>
# On success, exports FM_TMUX_SSH for a remote target or leaves it unset for a
# local one, then returns 0. Returns non-zero (with a stderr message) only when a
# remote machine is named but fails validation or the stranger-pane guard.
fm_transport_arm() {
  local raw=$1 win=$2 state=$3 machine='' want sess prefix meta

  # 1. Explicit env override: trust it verbatim, no registry resolution/guard.
  if [ -n "${FM_TMUX_SSH:-}" ]; then
    export FM_TMUX_SSH
    return 0
  fi

  # 2. FM_TARGET_MACHINE, else 3. meta machine= for a bare fm-<id> target.
  machine=${FM_TARGET_MACHINE:-}
  if [ -z "$machine" ]; then
    case "$raw" in
      fm-*)
        meta="$state/${raw#fm-}.meta"
        if [ -f "$meta" ]; then
          machine=$(grep '^machine=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
        fi
        ;;
    esac
  fi

  # Local target: leave FM_TMUX_SSH unset so fm_tmux runs a plain local tmux.
  case "$machine" in
    ''|hub) return 0 ;;
  esac

  if ! "$FM_MACHINES_BIN" validate "$machine" >/dev/null 2>&1; then
    echo "error: target machine \"$machine\" is not a valid registered machine" >&2
    return 1
  fi
  want=$("$FM_MACHINES_BIN" get "$machine" tmux-session 2>/dev/null || true)
  if [ -z "$want" ]; then
    echo "error: machine \"$machine\" has no tmux-session in the registry; refusing remote target" >&2
    return 1
  fi
  sess=${win%%:*}
  if [ "$sess" = "$win" ] || [ "$sess" != "$want" ]; then
    echo "error: refusing remote target \"$win\": tmux session \"$sess\" does not match machine \"$machine\" registry tmux-session \"$want\"" >&2
    return 1
  fi
  if ! prefix=$("$FM_MACHINES_BIN" ssh-prefix "$machine" 2>/dev/null) || [ -z "$prefix" ]; then
    echo "error: could not resolve a transport prefix for machine \"$machine\"" >&2
    return 1
  fi
  FM_TMUX_SSH=$prefix
  export FM_TMUX_SSH
  return 0
}
