#!/usr/bin/env bash
# Firstmate watcher.
# Blocks until supervision work is due, then exits printing one reason line:
#   signal: <file>...     a crewmate wrote a status line or a turn-end hook fired; signals
#                         landing within FM_SIGNAL_GRACE of each other coalesce into one wake
#   stale: <window>       a crewmate pane stopped changing and shows no busy signature
#   check: <script>: <out> a per-task check script (e.g. merged-PR poll) produced output
#   heartbeat              fleet review due; starts at FM_HEARTBEAT and backs off to FM_HEARTBEAT_MAX
# For normal supervision, re-arm after each wake by running bin/fm-watch-arm.sh
# through the harness's tracked background mechanism. Direct duplicate
# invocations of this script still no-op through the watcher singleton lock.
#
# Turn-end debounce: a bare <id>.turn-ended touch wakes only when the crew pane
# is NOT currently showing the harness busy signature (BUSY_REGEX, same
# footer-area rule as the stale scan). Modern agents chain many short turns
# while driving long background work, and each turn-end wake on a still-busy
# crewmate is a no-op costing firstmate a full turn. A busy pane means the
# crewmate already started its next turn, so the signal is CONSUMED: its
# .seen-* signature advances with no wake and no queue record. Consumption is
# safe because every path out of "busy" still reaches firstmate - the next
# turn's end touches the marker again (a fresh signature, re-evaluated then),
# and a pane that settles idle without another turn-end is caught by the
# existing stale scan, whose wake the busy signature was suppressing anyway.
# Status-file writes always wake regardless of pane state: needs-decision,
# blocked, done, and failed must never be delayed. kind=secondmate turn-ends
# are never suppressed - secondmate windows are exempt from the stale scan, so
# no settled-idle backstop covers them (fm-spawn installs no turn-end hook for
# them anyway) - and a missing meta, window, or pane also falls back to waking.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
trap 'fm_lock_release "$WATCH_LOCK"' EXIT
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat wakes
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working..."
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.'}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# Busy check shared by the stale scan and the turn-end debounce. Reads a pane
# capture on stdin; 0 when the busy signature shows. The match runs on the last
# 6 non-blank lines only (the TUI footer area, where every verified harness
# renders its busy indicator) so busy-looking strings in displayed content
# cannot suppress a wake.
pane_busy_tail() {
  grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
}

# turnend_suppressed <file>: 0 (suppress) only for a bare <id>.turn-ended whose
# task meta names a non-secondmate window whose pane currently shows the busy
# signature (see header: turn-end debounce). Everything else - a status file, a
# missing meta or window, an unreadable pane, kind=secondmate - returns 1
# (wake), so suppression triggers only on a positive busy read.
turnend_suppressed() {
  local f=$1 id meta w kind tail40
  case "$f" in
    *.turn-ended) ;;
    *) return 1 ;;
  esac
  id=$(basename "$f" .turn-ended)
  meta="$STATE/$id.meta"
  [ -e "$meta" ] || return 1
  kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
  [ "$kind" = secondmate ] && return 1
  w=$(grep '^window=' "$meta" | cut -d= -f2- || true)
  [ -n "$w" ] || return 1
  tail40=$(tmux capture-pane -p -t "$w" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | pane_busy_tail
}

# clear_stale_for_turnend <file>: drop the stale-scan dedup marker (.stale-*)
# for the window behind a consumed <id>.turn-ended, so the settled-idle backstop
# still fires when the pane later settles into a byte-identical state the stale
# scan already reported once.
clear_stale_for_turnend() {
  local f=$1 id meta w key
  id=$(basename "$f" .turn-ended)
  meta="$STATE/$id.meta"
  [ -e "$meta" ] || return 0
  w=$(grep '^window=' "$meta" | cut -d= -f2- || true)
  [ -n "$w" ] || return 0
  key=$(printf '%s' "$w" | tr ':/.' '___')
  rm -f "$STATE/.stale-$key"
}

window_kind() {
  local w=$1 meta mw kind
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || continue
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  done
  echo unknown
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Check and heartbeat cadence must survive restarts: the watcher exits on every
# wake and is relaunched, so in-memory counters never reach their threshold on
# a busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. A real wake advances .seen-* only after the wake is
# enqueued, so a watcher killed mid-cycle re-detects that signal rather than
# swallowing it; a busy turn-end instead advances .seen-* on deliberate
# consumption with no wake and no queue record (see the debounce below).
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check() {
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      out=$(run_check "$c")
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # waking: a crewmate's final status write and the same turn's turn-end hook
  # land seconds apart, and reporting them as separate wakes costs a full
  # firstmate turn each. The re-scan also picks up a newer signature for an
  # already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    # Partition changed files into wakes and busy-pane turn-end suppressions
    # (see header: turn-end debounce). The busy read happens here, after the
    # grace re-scan, so the decision uses the pane's current state. Suppressed
    # files are consumed below: their .seen-* advances with no wake and no
    # queue record; real wakes still enqueue before any marker advances.
    files="" suppressed=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files $suppressed " in *" $f "*) continue ;; esac
      if turnend_suppressed "$f"; then
        suppressed="$suppressed $f"
      else
        files="$files $f"
      fi
    done <<EOF
$pending
EOF
    if [ -n "$files" ]; then
      reason="signal:$files"
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case " $suppressed " in *" $f "*) continue ;; esac
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
    fi
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      printf '%s' "$sig" > "$sf"
    done <<EOF
$pending
EOF
    # Consuming a busy turn-end is observed crew activity even though it fires no
    # wake: reset the heartbeat cadence (without touching .last-heartbeat) so the
    # interval does not back off during suppressed-but-active work, and drop each
    # consumed window's stale dedup so the settled-idle backstop still fires.
    if [ -n "$suppressed" ]; then
      echo 0 > "$STATE/.heartbeat-streak"
      for f in $suppressed; do
        clear_stale_for_turnend "$f"
      done
    fi
    if [ -n "$files" ]; then
      wake "$reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale state is reported once (.stale-* remembers the hash already reported).
  while IFS= read -r w; do
    # A secondmate idling on its own watcher is healthy. Its parent supervises
    # it through status writes and heartbeats, not pane-idle staleness.
    [ "$(window_kind "$w")" = secondmate ] && continue
    tail40=$(tmux capture-pane -p -t "$w" -S -40 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && ! printf '%s' "$tail40" | pane_busy_tail; then
        if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
          fm_wake_append stale "$w" "stale: $w" || exit 1
          printf '%s' "$h" > "$sf"
          wake "stale: $w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
    fi
  done < <(recorded_windows)

  # Heartbeat: firstmate reviews the whole fleet at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any other wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    fm_wake_append heartbeat heartbeat heartbeat || exit 1
    touch "$STATE/.last-heartbeat"
    wake "heartbeat"
  fi

  sleep "$POLL"
done
