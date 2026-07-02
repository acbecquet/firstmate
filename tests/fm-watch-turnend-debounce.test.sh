#!/usr/bin/env bash
# tests/fm-watch-turnend-debounce.test.sh - turn-end debounce in fm-watch.sh:
# a bare <id>.turn-ended touch wakes only when the crew pane is NOT showing the
# harness busy signature. A busy pane consumes the signal (signature advances,
# no wake, no queue record) because the crewmate is already working again; the
# stale-pane scan remains the settled-idle backstop. Status-file writes always
# wake regardless of pane state, kind=secondmate turn-ends are never suppressed
# (no stale backstop covers them), and a turn-end with no matching meta falls
# back to waking. Queue losslessness for real wakes lives in
# fm-wake-queue.test.sh; this suite covers only the debounce decision.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-turnend-tests)

BUSY_PANE=$(printf 'crunching module output\nstill compiling things\n\xe2\x9c\xbb Cogitating\xe2\x80\xa6\nesc to interrupt\n')
IDLE_PANE=$(printf 'crunching module output\nall finished here\n> \n')

# run_watch <state> <fakebin> <capture> <window> <out> [heartbeat]: one watcher
# run against the fake tmux, tight intervals, checks disabled. Runs in the
# background; caller waits via wait_for_exit "$WATCH_PID".
run_watch() {
  local state=$1 fakebin=$2 capture=$3 window=$4 out=$5 heartbeat=${6:-999999}
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT="$heartbeat" \
    "$WATCH" > "$out" &
  WATCH_PID=$!
}

test_busy_pane_suppresses_bare_turnend() {
  local dir state fakebin out drain_out capture window
  dir=$(make_case turnend-busy)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  capture="$dir/pane.txt"
  window="test:fm-task"
  printf '%s\n' "$BUSY_PANE" > "$capture"
  fm_write_meta "$state/task.meta" "window=$window" "kind=ship" "harness=claude"
  touch "$state/task.turn-ended"
  # FM_HEARTBEAT=3 gives the watcher a deterministic non-signal exit: with the
  # turn-end suppressed and the busy pane never going stale, the heartbeat is
  # the only wake left, so a signal exit here means the debounce failed.
  run_watch "$state" "$fakebin" "$capture" "$window" "$out" 3
  wait_for_exit "$WATCH_PID" 150 || fail "watcher did not exit (expected a heartbeat exit)"
  grep -Fx 'heartbeat' "$out" >/dev/null || fail "watcher exit was not the heartbeat: $(cat "$out")"
  if grep -F 'signal:' "$out" >/dev/null; then
    fail "busy-pane turn-end produced a signal wake: $(cat "$out")"
  fi
  assert_present "$state/.seen-task_turn-ended" "suppressed turn-end signature was not consumed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed"
  if grep "$(printf '\tsignal\t')" "$drain_out" >/dev/null; then
    fail "suppressed turn-end landed in the wake queue: $(cat "$drain_out")"
  fi
  pass "busy pane + bare turn-end touch = no signal wake, signature consumed, nothing queued"
}

test_idle_pane_turnend_wakes() {
  local dir state fakebin out drain_out capture window
  dir=$(make_case turnend-idle)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  capture="$dir/pane.txt"
  window="test:fm-task"
  printf '%s\n' "$IDLE_PANE" > "$capture"
  fm_write_meta "$state/task.meta" "window=$window" "kind=ship" "harness=claude"
  touch "$state/task.turn-ended"
  run_watch "$state" "$fakebin" "$capture" "$window" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "watcher did not wake for an idle-pane turn-end"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null \
    || fail "idle-pane turn-end did not produce a signal wake: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "task.turn-ended" >/dev/null \
    || fail "idle-pane turn-end wake was not queued: $(cat "$drain_out")"
  pass "idle pane + turn-end touch = signal wake, queued as before"
}

test_status_write_wakes_despite_busy_pane() {
  local dir state fakebin out drain_out capture window
  dir=$(make_case status-busy)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  capture="$dir/pane.txt"
  window="test:fm-task"
  printf '%s\n' "$BUSY_PANE" > "$capture"
  fm_write_meta "$state/task.meta" "window=$window" "kind=ship" "harness=claude"
  printf 'needs-decision: pick option A or B\n' > "$state/task.status"
  touch "$state/task.turn-ended"
  run_watch "$state" "$fakebin" "$capture" "$window" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "watcher did not wake for a status write with a busy pane"
  grep -F "signal:" "$out" >/dev/null || fail "status write did not produce a signal wake: $(cat "$out")"
  grep -F "$state/task.status" "$out" >/dev/null \
    || fail "signal wake did not name the status file: $(cat "$out")"
  if grep -F "$state/task.turn-ended" "$out" >/dev/null; then
    fail "busy-pane turn-end rode along in the wake reason: $(cat "$out")"
  fi
  assert_present "$state/.seen-task_turn-ended" "coalesced busy turn-end signature was not consumed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed"
  grep "$(printf '\tsignal\ttask.status\t')" "$drain_out" >/dev/null \
    || fail "status wake was not queued: $(cat "$drain_out")"
  if grep "$(printf '\tsignal\ttask.turn-ended\t')" "$drain_out" >/dev/null; then
    fail "suppressed turn-end landed in the wake queue: $(cat "$drain_out")"
  fi
  pass "status write always wakes; the same turn's busy turn-end is consumed, not queued"
}

test_secondmate_turnend_never_suppressed() {
  local dir state fakebin out capture window
  dir=$(make_case secondmate-busy)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  capture="$dir/pane.txt"
  window="test:fm-domain"
  printf '%s\n' "$BUSY_PANE" > "$capture"
  fm_write_meta "$state/domain.meta" "window=$window" "kind=secondmate" "harness=claude"
  touch "$state/domain.turn-ended"
  run_watch "$state" "$fakebin" "$capture" "$window" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "watcher did not wake for a secondmate turn-end"
  grep -F "signal: $state/domain.turn-ended" "$out" >/dev/null \
    || fail "secondmate turn-end was suppressed: $(cat "$out")"
  pass "kind=secondmate turn-end wakes even with a busy pane (no stale backstop exists)"
}

test_turnend_without_meta_wakes() {
  local dir state fakebin out capture window
  dir=$(make_case orphan-turnend)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  capture="$dir/pane.txt"
  window="test:fm-task"
  printf '%s\n' "$BUSY_PANE" > "$capture"
  touch "$state/orphan.turn-ended"
  run_watch "$state" "$fakebin" "$capture" "$window" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "watcher did not wake for a meta-less turn-end"
  grep -F "signal: $state/orphan.turn-ended" "$out" >/dev/null \
    || fail "meta-less turn-end was suppressed: $(cat "$out")"
  pass "turn-end with no matching meta falls back to waking"
}

test_settled_idle_backstop_fires_stale() {
  local dir state fakebin out capture window i
  dir=$(make_case settled-idle)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  capture="$dir/pane.txt"
  window="test:fm-task"
  printf '%s\n' "$BUSY_PANE" > "$capture"
  fm_write_meta "$state/task.meta" "window=$window" "kind=ship" "harness=claude"
  touch "$state/task.turn-ended"
  run_watch "$state" "$fakebin" "$capture" "$window" "$out"
  # Wait for the debounce to consume the busy turn-end, then let the pane settle
  # idle with no further signal: the stale scan must still wake firstmate.
  i=0
  until [ -e "$state/.seen-task_turn-ended" ]; do
    sleep 0.1
    i=$((i + 1))
    [ "$i" -lt 100 ] || fail "busy turn-end signature was never consumed"
  done
  printf '%s\n' "$IDLE_PANE" > "$capture"
  wait_for_exit "$WATCH_PID" 150 || fail "watcher did not wake after the pane settled idle"
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "settled-idle pane did not fire the stale backstop: $(cat "$out")"
  pass "suppressed turn-end followed by genuine idleness still wakes via the stale backstop"
}

test_suppressed_turnend_resets_heartbeat_streak() {
  local dir state fakebin out capture window i
  dir=$(make_case turnend-streak-reset)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  capture="$dir/pane.txt"
  window="test:fm-task"
  printf '%s\n' "$BUSY_PANE" > "$capture"
  fm_write_meta "$state/task.meta" "window=$window" "kind=ship" "harness=claude"
  # A backed-off heartbeat cadence left over from a prior idle stretch. Consuming
  # a busy turn-end is observed crew activity and must reset it to the base
  # interval, otherwise heartbeat latency keeps growing during active work.
  printf '5\n' > "$state/.heartbeat-streak"
  touch "$state/task.turn-ended"
  # Default FM_HEARTBEAT (999999) keeps the heartbeat from firing, so the only
  # thing that can zero the streak is the debounce consuming the busy turn-end.
  run_watch "$state" "$fakebin" "$capture" "$window" "$out"
  i=0
  until [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo x)" = 0 ]; do
    sleep 0.1
    i=$((i + 1))
    [ "$i" -lt 100 ] || { kill "$WATCH_PID" 2>/dev/null; fail "consuming a busy turn-end did not reset the heartbeat streak"; }
  done
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  pass "consuming a busy turn-end resets the heartbeat backoff cadence"
}

test_consumed_turnend_clears_stale_dedup() {
  local dir state fakebin out capture window stalekey i
  dir=$(make_case turnend-stale-clear)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  capture="$dir/pane.txt"
  window="test:fm-task"
  stalekey="$state/.stale-test_fm-task"
  printf '%s\n' "$BUSY_PANE" > "$capture"
  fm_write_meta "$state/task.meta" "window=$window" "kind=ship" "harness=claude"
  # The stale scan already reported this idle screen once, so its dedup marker
  # remembers that hash. A byte-identical re-settle after a consumed turn-end
  # would be swallowed unless consumption drops the marker.
  printf '%s' "$(hash_text "$IDLE_PANE")" > "$stalekey"
  touch "$state/task.turn-ended"
  run_watch "$state" "$fakebin" "$capture" "$window" "$out"
  i=0
  until [ ! -e "$stalekey" ]; do
    sleep 0.1
    i=$((i + 1))
    [ "$i" -lt 100 ] || { kill "$WATCH_PID" 2>/dev/null; fail "consuming the busy turn-end did not clear the window's stale dedup"; }
  done
  printf '%s\n' "$IDLE_PANE" > "$capture"
  wait_for_exit "$WATCH_PID" 150 || fail "watcher did not re-fire stale after settling into a previously-reported state"
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "re-settled idle pane did not re-fire the stale backstop: $(cat "$out")"
  pass "consuming a busy turn-end clears the stale dedup so a re-settled idle state still wakes"
}

test_busy_pane_suppresses_bare_turnend
test_idle_pane_turnend_wakes
test_status_write_wakes_despite_busy_pane
test_secondmate_turnend_never_suppressed
test_turnend_without_meta_wakes
test_settled_idle_backstop_fires_stale
test_suppressed_turnend_resets_heartbeat_streak
test_consumed_turnend_clears_stale_dedup
