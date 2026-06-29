#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or
# a standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: <window-targets...>|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""
FF_SEEN_REMOTE=""
MACHINES_BIN="$SCRIPT_DIR/fm-machines.sh"

# Live LOCAL direct reports first: state/<id>.meta with kind=secondmate and an
# empty / hub machine= carries the authoritative home= path. (sweep_live_* now
# skips non-hub machine= homes - those are remote and handled below.)
sweep_live_secondmate_metas "$STATE" origin no

# Live REMOTE direct reports (M5): a machine:-tagged home lives on another box with
# its own object store, so the local fast-forward cannot converge it. It is advanced
# by running the same guarded origin fast-forward ON THE BOX over the transport.
sweep_remote_secondmate_metas "$STATE" "$MACHINES_BIN"

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home. A
# machine:-tagged registry line is routed over the transport like the live remote
# sweep; a local one takes the local origin fast-forward. Remote ids already covered
# by a live meta above are skipped (FF_SEEN_REMOTE).
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    machine=$(printf '%s\n' "$line" | sed -n 's/^.*; machine:[[:space:]]*\([^;)]*\).*/\1/p' | sed 's/[[:space:]]*$//')
    case "$machine" in
      ''|hub)
        process_secondmate "$id" "$home" "" origin no ;;
      *)
        case " $FF_SEEN_REMOTE " in *" $id "*) continue ;; esac
        # The secondmate line's own home: is its home path ON THE BOX and wins;
        # the machine registry fm-home is only a fallback when the line omits it.
        rhome=$home
        [ -n "$rhome" ] || rhome=$("$MACHINES_BIN" get "$machine" fm-home 2>/dev/null || true)
        prefix=$("$MACHINES_BIN" ssh-prefix "$machine" 2>/dev/null || true)
        ff_remote_secondmate "$id" "$machine" "$rhome" "$prefix" "secondmate $id"
        FF_SEEN_REMOTE="$FF_SEEN_REMOTE $id" ;;
    esac
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
