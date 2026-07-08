#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# The lock records a PID whose liveness tracks the firstmate session, so another
# session can tell whether the first is still alive. Identity is resolved in this
# order, and whatever is recorded is always a PID that holder_alive() recognizes
# as a live harness:
#   1. FM_LOCK_PID - an explicit override for environments the automatic paths
#      cannot resolve. Honored only when it names a live harness process, so the
#      recorded PID stays honest and other sessions still recognize the holder.
#   2. Ancestry walk - the harness process that is an ancestor of this tool shell
#      (the normal foreground case). It outlives any single tool call's transient
#      subshell, unlike that subshell's own PID.
#   3. Session match - a background/chat session's tool shells are spawned by a
#      pty-host daemon, so the harness is NOT in our ancestry and the walk finds
#      nothing. Fall back to the one live harness process that carries this
#      session id (CLAUDE_CODE_SESSION_ID, exported into every tool shell) in
#      its args at a token or path boundary - a resumed/background session runs
#      as `claude --resume <session-id>` or, under a versioned install, as
#      `.../claude/versions/<v> --resume .../projects/<slug>/<session-id>.jsonl`.
#      Only a process whose command word names a known harness binary (as its
#      basename or as a path component) qualifies, so a bystander that merely
#      references the session id (a transcript-path tail, a log watcher) can
#      never become the holder. A match that is an ancestor of another match is
#      that match's launcher (the pty-host daemon's own argv embeds the harness
#      command it spawns), not the session, and is filtered out. The surviving
#      process IS the session, so its liveness tracks the session exactly; zero
#      or ambiguous (non-unique) survivors are refused rather than guessed.
#
# Liveness is zombie-aware. kill -0 succeeds on a defunct (zombie) process whose
# PID still lingers in the process table, and ps preserves its harness command
# name, so a dead session would otherwise read as a live holder and wrongly refuse
# takeover. holder_alive() rejects process state Z.
#
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified, together
# with the exact command-word list in session_harness_pid.
HARNESS_RE='claude|codex|opencode|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# harness_like <pid>: true if the pid's command name or full args name a known
# harness. Recognizes a lock holder and this session's own harness process.
harness_like() {
  local pid=$1 comm
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  # comm and args on separate lines so the anchored ^pi$ alternative can match
  # the bare command name; grep matches per line, the rest are unanchored.
  printf '%s\n%s' "$(basename "$comm")" "$(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

holder_alive() {  # true if $1 is a live (non-defunct) process that looks like a harness
  local pid=$1 state
  kill -0 "$pid" 2>/dev/null || return 1
  # kill -0 succeeds on a zombie whose PID lingers in the table; a defunct holder
  # means the session died, so reject state Z as not alive.
  state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  case "$state" in Z*) return 1 ;; esac
  harness_like "$pid"
}

# session_harness_pid: fallback identity when the harness is not in our ancestry
# (a background/chat session behind a pty-host daemon). Locate the one live
# harness process carrying this session id in its args. A candidate must be a
# genuine harness: its command word (first argv token) must name a known harness
# binary as its basename or as a path component (a versioned install runs as
# .../claude/versions/<v>), and the session id must sit at token or [/._=-]
# boundaries - a bare argument, --flag=<sid>, or embedded in a transcript path
# such as --resume .../projects/<slug>/<sid>.jsonl - never as an arbitrary
# substring of a longer token. A candidate that is an ancestor of another
# candidate is that candidate's launcher (a pty-host daemon's argv embeds the
# harness command it spawns, session id and all), not the session: only the
# descendant survives. Zero or multiple survivors fail the resolution rather
# than guess.
session_harness_pid() {
  local sid=${CLAUDE_CODE_SESSION_ID:-} p args word o anc hops match=""
  local -a cands=() launchers=()
  [ -n "$sid" ] || return 1
  while read -r p args; do
    [ -n "$p" ] || continue
    case " $args " in
      *[[:space:]/._=-]"$sid"[[:space:]/._=-]*) : ;;
      *) continue ;;
    esac
    word=${args%% *}
    case "/$word/" in
      */claude/*|*/codex/*|*/opencode/*|*/pi/*) : ;;
      *) continue ;;
    esac
    holder_alive "$p" || continue
    cands+=("$p")
  done < <(ps -eo pid=,args= 2>/dev/null)
  if [ "${#cands[@]}" -gt 1 ]; then
    for o in "${cands[@]}"; do
      anc=$(ps -o ppid= -p "$o" 2>/dev/null | tr -d ' ')
      hops=0
      while [ -n "$anc" ] && [ "$anc" -gt 1 ] && [ "$hops" -lt 8 ]; do
        for p in "${cands[@]}"; do
          [ "$p" = "$anc" ] && launchers+=("$anc")
        done
        anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
        hops=$((hops + 1))
      done
    done
  fi
  for p in "${cands[@]}"; do
    case " ${launchers[*]-} " in *" $p "*) continue ;; esac
    if [ -n "$match" ] && [ "$match" != "$p" ]; then
      return 1
    fi
    match=$p
  done
  [ -n "$match" ] || return 1
  echo "$match"
}

# resolve_self: the PID to record for this session, in the order documented above.
resolve_self() {
  local pid
  if [ -n "${FM_LOCK_PID:-}" ] && holder_alive "$FM_LOCK_PID"; then
    echo "$FM_LOCK_PID"; return 0
  fi
  if pid=$(harness_pid); then echo "$pid"; return 0; fi
  if pid=$(session_harness_pid); then echo "$pid"; return 0; fi
  return 1
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a live harness)"; fi
  exit 0
fi

me=$(resolve_self) || { echo "error: cannot locate a live harness for this session (ancestry, session match, and FM_LOCK_PID all failed)" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
