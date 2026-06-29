#!/usr/bin/env bash
# Behavior tests for bin/fm-status-pull.sh — status carry-back for REMOTE
# secondmates. A remote secondmate appends its hub-bound status to its OWN home's
# state/<id>.status on the box; this script pulls that file over the transport and
# mirrors it into the hub's LOCAL state/<id>.status so the hub watcher's
# scan_signals wakes on it. These tests are MOCK-ONLY: a fake `ssh` on PATH stands
# in for the wire (it `cat`s a test-controlled "remote" file), so NO real ssh and
# NO real tmux run. They pin:
#   - a first pull mirrors the remote content into the local status file;
#   - a pull writes ONLY when the remote content changed (no spurious wake);
#   - an unreachable box writes nothing, notes it, and still exits 0;
#   - a non-remote (hub / no machine=) id is skipped;
#   - `arm` writes a state/<id>.check.sh that invokes the pull.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PULL="$ROOT/bin/fm-status-pull.sh"
MACHINES="$ROOT/bin/fm-machines.sh"

REG_FIXTURE='# Machine registry
- cabin-desktop - cabin box, WSL2 (host: cabin-desktop.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)'

# A fake `ssh` that emulates the remote `cat <status>`: it prints the contents of
# the file named by FAKE_REMOTE_FILE, or exits non-zero when FAKE_REMOTE_MISSING
# is set (an unreachable box / absent remote file). It ignores the path argument
# on purpose — resolution is exercised by the real ssh-prefix + meta plumbing, and
# the test owns what "the box" returns.
make_ssh_cat_stub() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/ssh" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_REMOTE_MISSING:-}" ]; then exit 1; fi
cat "${FAKE_REMOTE_FILE:?}"
SH
  chmod +x "$fb/ssh"
  printf '%s\n' "$fb"
}

# run_pull <fakebin> <home> [env=val...] -- <pull args...>
# Invokes fm-status-pull.sh with the stub ssh on PATH against <home> (holding
# data/machines.md + state/). Captures stderr (the diagnostics channel) to a file
# whose path is echoed, so a test can assert on the "pulled:"/"unreachable" notes.
run_pull() {
  local fb=$1 home=$2; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_MACHINES_BIN="$MACHINES" \
    "${envs[@]}" "$PULL" "$@"
}

setup_home() {  # -> echoes a fresh home with registry + state
  local home
  home=$(fm_test_tmproot fm-status-pull)
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$REG_FIXTURE" > "$home/data/machines.md"
  printf '%s\n' "$home"
}

test_pull_mirrors_remote() {
  local home fb remote err out
  home=$(setup_home)
  fb=$(make_ssh_cat_stub "$home")
  fm_write_meta "$home/state/cabin-sm.meta" \
    "window=firstmate:fm-cabin-sm" "kind=secondmate" "machine=cabin-desktop"
  remote="$home/remote-status"
  printf 'working: building\ndone: PR up\n' > "$remote"
  err="$home/err1"
  run_pull "$fb" "$home" FAKE_REMOTE_FILE="$remote" -- cabin-sm 2>"$err"
  out=$(cat "$home/state/cabin-sm.status")
  assert_contains "$out" "done: PR up" "first pull should mirror remote status into the local file"
  assert_contains "$(cat "$err")" "pulled:" "first pull should note that it mirrored the status"
  pass "fm-status-pull mirrors a remote secondmate's status into the hub state file"
}

test_pull_only_on_change() {
  local home fb remote err
  home=$(setup_home)
  fb=$(make_ssh_cat_stub "$home")
  fm_write_meta "$home/state/cabin-sm.meta" \
    "window=firstmate:fm-cabin-sm" "kind=secondmate" "machine=cabin-desktop"
  remote="$home/remote-status"
  printf 'working: one\n' > "$remote"
  run_pull "$fb" "$home" FAKE_REMOTE_FILE="$remote" -- cabin-sm 2>/dev/null
  # Second pull, identical remote content: must NOT rewrite (no spurious wake).
  err="$home/err2"
  run_pull "$fb" "$home" FAKE_REMOTE_FILE="$remote" -- cabin-sm 2>"$err"
  assert_not_contains "$(cat "$err")" "pulled:" "an unchanged remote must not rewrite the local file"
  # A real change DOES mirror through.
  printf 'working: one\nblocked: needs key\n' > "$remote"
  err="$home/err3"
  run_pull "$fb" "$home" FAKE_REMOTE_FILE="$remote" -- cabin-sm 2>"$err"
  assert_contains "$(cat "$err")" "pulled:" "a changed remote must mirror through"
  assert_contains "$(cat "$home/state/cabin-sm.status")" "blocked: needs key" "the change should land locally"
  pass "fm-status-pull writes the local file only when the remote content changed"
}

test_unreachable_is_clean() {
  local home fb err rc
  home=$(setup_home)
  fb=$(make_ssh_cat_stub "$home")
  fm_write_meta "$home/state/cabin-sm.meta" \
    "window=firstmate:fm-cabin-sm" "kind=secondmate" "machine=cabin-desktop"
  err="$home/err"
  run_pull "$fb" "$home" FAKE_REMOTE_MISSING=1 FAKE_REMOTE_FILE="$home/none" -- cabin-sm 2>"$err"; rc=$?
  expect_code 0 "$rc" "an unreachable box must still exit 0 (an arming check never errors)"
  assert_contains "$(cat "$err")" "unreachable" "an unreachable box should be noted to stderr"
  assert_absent "$home/state/cabin-sm.status" "an unreachable box must write no local status"
  pass "fm-status-pull fails cleanly on an unreachable box (exit 0, nothing written)"
}

test_non_remote_skipped() {
  local home fb err rc
  home=$(setup_home)
  fb=$(make_ssh_cat_stub "$home")
  fm_write_meta "$home/state/local-sm.meta" \
    "window=firstmate:fm-local-sm" "kind=secondmate" "machine=hub"
  err="$home/err"
  run_pull "$fb" "$home" FAKE_REMOTE_FILE="$home/none" -- local-sm 2>"$err"; rc=$?
  expect_code 0 "$rc" "a hub/local id should be skipped without error"
  assert_contains "$(cat "$err")" "not a remote machine target" "a hub target should be reported skipped"
  assert_absent "$home/state/local-sm.status" "a hub target must write no mirrored status"
  pass "fm-status-pull skips a non-remote (hub) target"
}

test_arm_writes_check() {
  local home fb out
  home=$(setup_home)
  fb=$(make_ssh_cat_stub "$home")
  out=$(run_pull "$fb" "$home" -- arm cabin-sm)
  assert_contains "$out" "armed:" "arm should report it wrote the check script"
  assert_present "$home/state/cabin-sm.check.sh" "arm should write state/<id>.check.sh"
  assert_grep "fm-status-pull.sh" "$home/state/cabin-sm.check.sh" "the check script should invoke the pull"
  pass "fm-status-pull arm writes a watcher check script that runs the pull"
}

test_pull_mirrors_remote
test_pull_only_on_change
test_unreachable_is_clean
test_non_remote_skipped
test_arm_writes_check

echo "# all fm-status-pull (multi-machine M2 carry-back) tests passed"
