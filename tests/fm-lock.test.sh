#!/usr/bin/env bash
# Behavior tests for bin/fm-lock.sh - the per-home firstmate session lock. These
# pin two liveness invariants that both regressed live:
#
#   1. A defunct (zombie) holder must be treated as STALE. `kill -0` succeeds on a
#      zombie whose PID lingers in the process table, and `ps -o comm=` preserves
#      the harness command name on a defunct process, so the old holder check
#      false-positived a dead session as a live one and refused takeover.
#   2. Acquisition must still find an honest identity when the tool shell has no
#      harness in its ancestry (a background/chat session whose shells are spawned
#      by a pty-host daemon). The ancestry walk returns nothing there, so the lock
#      falls back to an FM_LOCK_PID override or to the live harness process that
#      carries this session id (CLAUDE_CODE_SESSION_ID) in its args.
#
# MOCK-ONLY and deterministic. No real zombie and no real harness are required:
# a `ps` shim on PATH reproduces the exact signals fm-lock.sh reads.
#   FM_PS_PPID1=1      -> answer the ancestry walk's `ppid=` query with 1, so the
#                        walk terminates with no harness ancestor (the pty-host case).
#   FM_PS_ZOMBIE=<pid> -> answer a `state=`/`stat=` query for <pid> with Z, so a
#                        real live pid presents as defunct while kill -0 still passes.
# Every other ps query delegates to the real ps (via FM_REAL_PS), so a live fake
# harness reports its genuine comm/args/state. CLAUDE_CODE_SESSION_ID is pinned per
# run so the ambient session id never leaks into a case that must not session-match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK_SH="$ROOT/bin/fm-lock.sh"
REAL_PS="$(command -v ps)"

TMP_ROOT=$(fm_test_tmproot fm-lock-tests)

# --- fixtures ---------------------------------------------------------------

# Track spawned fake-harness pids so the EXIT trap reaps them. The spawners run
# inside command substitutions, so an in-memory array would only mutate a subshell
# copy; append to a file instead, which survives the subshell. lib.sh installs its
# own fm_test_cleanup EXIT trap on the first fm_test_tmproot call above; override
# it with one that kills the recorded processes, then delegates to fm_test_cleanup.
FAKE_PID_FILE="$TMP_ROOT/fake-pids"
cleanup_all() {
  local p
  if [ -f "$FAKE_PID_FILE" ]; then
    while read -r p; do
      [ -n "$p" ] && kill "$p" 2>/dev/null
    done < "$FAKE_PID_FILE"
  fi
  fm_test_cleanup
}
trap cleanup_all EXIT

# make_case <name> -> echoes a fresh case dir with state/ and a ps-shimmed fakebin.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
# Test ps shim (see file header). Two opt-in overrides, else delegate to real ps.
set -u
want_ppid=0; want_state=0; target=""; prev=""
for a in "$@"; do
  case "$a" in
    ppid=) want_ppid=1 ;;
    state=|stat=) want_state=1 ;;
  esac
  [ "$prev" = "-p" ] && target="$a"
  prev="$a"
done
if [ "${FM_PS_PPID1:-}" = "1" ] && [ "$want_ppid" = "1" ]; then
  printf '1\n'; exit 0
fi
if [ -n "${FM_PS_ZOMBIE:-}" ] && [ "$want_state" = "1" ] && [ "$target" = "${FM_PS_ZOMBIE}" ]; then
  printf 'Z\n'; exit 0
fi
exec "${FM_REAL_PS:?FM_REAL_PS unset}" "$@"
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$dir"
}

# spawn_fake_harness <dir> [args...] -> echoes the pid of a live, non-zombie
# process whose command word is `claude` (bash symlinked as `claude`, running an
# endless loop script), so both the comm/args harness checks and the session
# match's first-argv-token rule see a genuine harness. Any args (e.g. --resume
# <sid>) stay visible as whole tokens in its cmdline.
spawn_fake_harness() {
  local dir=$1; shift
  local hbin="$dir/hbin" pid i
  mkdir -p "$hbin"
  if [ ! -x "$hbin/claude" ]; then
    ln -s "$(command -v bash)" "$hbin/claude"
    cat > "$hbin/harness-loop.sh" <<'SH'
trap 'exit 0' TERM INT
while :; do sleep 0.5; done
SH
  fi
  # Redirect the fake's stdio away from any command-substitution pipe capturing
  # this function, or `$(spawn_fake_harness ...)` would block until the (endless)
  # fake exits.
  "$hbin/claude" "$hbin/harness-loop.sh" "$@" >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$FAKE_PID_FILE"
  # Settle until the process's cmdline is populated (harness match relies on it).
  i=0
  while [ "$i" -lt 40 ]; do
    case "$("$REAL_PS" -o args= -p "$pid" 2>/dev/null)" in
      *claude*) break ;;
    esac
    sleep 0.05; i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

# spawn_fake_bystander <dir> [args...] -> echoes the pid of a live process whose
# command word is NOT a harness (bash running a script named `watcher`) but whose
# args carry the given tokens - e.g. a transcript path containing both "claude"
# and the session id, the lookalike the session match must never pick.
spawn_fake_bystander() {
  local dir=$1; shift
  local bbin="$dir/bbin" pid i
  mkdir -p "$bbin"
  if [ ! -x "$bbin/watcher" ]; then
    cat > "$bbin/watcher" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 0.5; done
SH
    chmod +x "$bbin/watcher"
  fi
  "$bbin/watcher" "$@" >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$FAKE_PID_FILE"
  i=0
  while [ "$i" -lt 40 ]; do
    case "$("$REAL_PS" -o args= -p "$pid" 2>/dev/null)" in
      *watcher*) break ;;
    esac
    sleep 0.05; i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

uniq_sid() { printf 'fmlock-sid-%s-%s\n' "$$" "${RANDOM}${RANDOM}"; }

# --- tests ------------------------------------------------------------------

# (a) A defunct (zombie) holder is treated as stale: acquisition takes over and
# `status` reports the lock stale, instead of a false "another live session".
test_zombie_holder_is_stale() {
  local dir state fakebin holder self err out rc st
  dir=$(make_case zombie-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  holder=$(spawn_fake_harness "$dir")   # a live fake, but presented as defunct
  self=$(spawn_fake_harness "$dir")     # this session's identity (differs from holder)
  printf '%s\n' "$holder" > "$state/.lock"

  # status must call the defunct holder stale (check before takeover overwrites it).
  st=$(PATH="$fakebin:$PATH" FM_REAL_PS="$REAL_PS" FM_STATE_OVERRIDE="$state" \
       FM_PS_ZOMBIE="$holder" "$LOCK_SH" status)
  assert_contains "$st" "stale" "status must report a defunct holder as stale"

  err="$dir/err"
  out=$(PATH="$fakebin:$PATH" FM_REAL_PS="$REAL_PS" FM_STATE_OVERRIDE="$state" \
        FM_PS_ZOMBIE="$holder" CLAUDE_CODE_SESSION_ID="$(uniq_sid)" FM_LOCK_PID="$self" \
        "$LOCK_SH" 2>"$err")
  rc=$?
  expect_code 0 "$rc" "acquisition must succeed over a defunct holder"
  assert_not_contains "$(cat "$err")" "another live firstmate session" \
    "a zombie holder must not be reported as a live session"
  [ "$(cat "$state/.lock")" = "$self" ] || fail "lock was not taken over by this session"
  assert_contains "$out" "lock acquired" "acquisition should confirm it acquired"
  pass "a defunct (zombie) holder is treated as a stale lock"
}

# (b1) Ancestry-failure fallback via session match: with no harness ancestor, the
# lock records the live harness whose args carry this session id.
test_ancestry_fail_session_match_acquires() {
  local dir state fakebin harness sid err out rc
  dir=$(make_case ancestry-session)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sid=$(uniq_sid)
  harness=$(spawn_fake_harness "$dir" --resume "$sid")

  err="$dir/err"
  out=$(PATH="$fakebin:$PATH" FM_REAL_PS="$REAL_PS" FM_STATE_OVERRIDE="$state" \
        FM_PS_PPID1=1 FM_LOCK_PID='' CLAUDE_CODE_SESSION_ID="$sid" \
        "$LOCK_SH" 2>"$err")
  rc=$?
  expect_code 0 "$rc" "session-matched fallback must acquire when ancestry fails"
  [ "$(cat "$state/.lock")" = "$harness" ] || \
    fail "lock must record the session's live harness pid, got '$(cat "$state/.lock")'"
  assert_contains "$out" "lock acquired" "session-matched acquisition should confirm"
  pass "ancestry-failure fallback acquires by matching this session's harness"
}

# (b1b) Session-match lookalikes are rejected: a non-harness process whose args
# merely contain the session id (a transcript-path watcher), and a harness whose
# args embed the sid inside a longer path token, must neither become the holder
# nor trip the non-unique refusal once the genuine `--resume <sid>` harness runs.
test_session_match_rejects_lookalikes() {
  local dir state fakebin sid harness err out rc
  dir=$(make_case session-lookalikes)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sid=$(uniq_sid)
  spawn_fake_bystander "$dir" "$dir/.claude/projects/p/$sid.jsonl" >/dev/null
  spawn_fake_harness "$dir" "$dir/transcripts/$sid.jsonl" >/dev/null

  # With only lookalikes present, no honest identity exists: refuse, write nothing.
  err="$dir/err"
  PATH="$fakebin:$PATH" FM_REAL_PS="$REAL_PS" FM_STATE_OVERRIDE="$state" \
    FM_PS_PPID1=1 FM_LOCK_PID='' CLAUDE_CODE_SESSION_ID="$sid" \
    "$LOCK_SH" >/dev/null 2>"$err"
  rc=$?
  expect_code 1 "$rc" "lookalike processes must not be matched as the session harness"
  assert_absent "$state/.lock" "a lookalike match must not write a lock"
  assert_contains "$(cat "$err")" "cannot locate" "the refusal must report no identity found"

  # With the genuine harness also live, it is the unique match despite the lookalikes.
  harness=$(spawn_fake_harness "$dir" --resume "$sid")
  out=$(PATH="$fakebin:$PATH" FM_REAL_PS="$REAL_PS" FM_STATE_OVERRIDE="$state" \
        FM_PS_PPID1=1 FM_LOCK_PID='' CLAUDE_CODE_SESSION_ID="$sid" \
        "$LOCK_SH" 2>"$err")
  rc=$?
  expect_code 0 "$rc" "the genuine harness must be a unique match despite lookalikes"
  [ "$(cat "$state/.lock")" = "$harness" ] || \
    fail "lock must record the genuine harness pid, got '$(cat "$state/.lock")'"
  assert_contains "$out" "lock acquired" "unique-match acquisition should confirm"
  pass "session match rejects lookalikes and stays unique on the genuine harness"
}

# (b2) Ancestry-failure fallback via explicit override: FM_LOCK_PID names the
# session-stable pid to record.
test_ancestry_fail_env_override_acquires() {
  local dir state fakebin self err out rc
  dir=$(make_case ancestry-override)
  state="$dir/state"
  fakebin="$dir/fakebin"
  self=$(spawn_fake_harness "$dir")

  err="$dir/err"
  out=$(PATH="$fakebin:$PATH" FM_REAL_PS="$REAL_PS" FM_STATE_OVERRIDE="$state" \
        FM_PS_PPID1=1 CLAUDE_CODE_SESSION_ID="$(uniq_sid)" FM_LOCK_PID="$self" \
        "$LOCK_SH" 2>"$err")
  rc=$?
  expect_code 0 "$rc" "FM_LOCK_PID override must acquire when ancestry fails"
  [ "$(cat "$state/.lock")" = "$self" ] || fail "lock must record the FM_LOCK_PID override"
  assert_contains "$out" "lock acquired" "override acquisition should confirm"
  pass "ancestry-failure fallback acquires via the FM_LOCK_PID override"
}

# (c) A genuinely live holder still refuses takeover (the invariant the zombie fix
# must not weaken).
test_live_holder_refuses_takeover() {
  local dir state fakebin holder self err rc
  dir=$(make_case live-refuse)
  state="$dir/state"
  fakebin="$dir/fakebin"
  holder=$(spawn_fake_harness "$dir")   # a genuinely live holder
  self=$(spawn_fake_harness "$dir")     # a different live session attempting takeover
  printf '%s\n' "$holder" > "$state/.lock"

  err="$dir/err"
  PATH="$fakebin:$PATH" FM_REAL_PS="$REAL_PS" FM_STATE_OVERRIDE="$state" \
    CLAUDE_CODE_SESSION_ID="$(uniq_sid)" FM_LOCK_PID="$self" \
    "$LOCK_SH" >/dev/null 2>"$err"
  rc=$?
  expect_code 1 "$rc" "acquisition must refuse while a live session holds the lock"
  assert_contains "$(cat "$err")" "another live firstmate session holds the lock" \
    "the refusal must name the live holder"
  [ "$(cat "$state/.lock")" = "$holder" ] || fail "a refused acquisition must not overwrite the lock"
  pass "a genuinely live holder still refuses takeover"
}

# (honesty guard) When ancestry fails and no fallback can honestly identify the
# session, acquisition refuses rather than inventing a pid.
test_ancestry_fail_no_fallback_refuses() {
  local dir state fakebin err rc
  dir=$(make_case ancestry-none)
  state="$dir/state"
  fakebin="$dir/fakebin"

  err="$dir/err"
  PATH="$fakebin:$PATH" FM_REAL_PS="$REAL_PS" FM_STATE_OVERRIDE="$state" \
    FM_PS_PPID1=1 FM_LOCK_PID='' CLAUDE_CODE_SESSION_ID="$(uniq_sid)" \
    "$LOCK_SH" >/dev/null 2>"$err"
  rc=$?
  expect_code 1 "$rc" "no honest identity means acquisition must fail, not fabricate one"
  assert_absent "$state/.lock" "a failed acquisition must not write a lock"
  assert_contains "$(cat "$err")" "cannot locate" "the failure must explain no identity was found"
  pass "acquisition refuses to invent a pid when no honest identity exists"
}

test_zombie_holder_is_stale
test_ancestry_fail_session_match_acquires
test_session_match_rejects_lookalikes
test_ancestry_fail_env_override_acquires
test_live_holder_refuses_takeover
test_ancestry_fail_no_fallback_refuses

echo "# all fm-lock (session lock liveness) tests passed"
