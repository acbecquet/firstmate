#!/usr/bin/env bash
# Behavior tests for multi-machine M3: hub-driven REMOTE secondmate spin-up and
# the §5.1 round-trip.
#
#   - bin/fm-spawn.sh --secondmate: when a secondmate's machine= (meta) or
#     machine: (data/secondmates.md) names a non-hub registered box, the hub
#     starts that secondmate's firstmate session ON the box over the transport,
#     inside the box's registry tmux-session, under `claude remote-control`,
#     records machine=/host=/remote_home= meta, delivers the charter pointer, and
#     arms status carry-back.
#   - the §5.1 round-trip: a marked work line routed IN over the transport, and a
#     status line carried BACK into the hub's local state/ (where the watcher's
#     ordinary signal scan wakes on it).
#   - the LOCAL secondmate path (no machine= / machine=hub) is UNCHANGED: it uses
#     local tmux, makes NO ssh call, and writes no machine= meta.
#
# MOCK-ONLY and deterministic: a fake `ssh` on PATH records every transported
# `tmux ...` / `cat ...` command and answers fm-send's composer probes, and a
# fake `tmux` stands in for the local path. NO real ssh and NO real tmux run — a
# real-tmux loopback once killed the shared tmux server that hosts firstmate's
# live supervision, so the committed suite asserts only the constructed command
# strings and the mirrored status file. tests/m3-roundtrip-live.sh is the
# separate, manual, real-isolated round-trip on a private `-L fm-m3-test` server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
MACHINES="$ROOT/bin/fm-machines.sh"

REG_MACHINES='# Machine registry
- cabin-desktop - cabin box, WSL2 (host: cabin-desktop.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)
- pigeonbox - bad harness (host: pigeon.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: codex; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)'

# A remote secondmate registry line (machine: at the END, after `added`), and a
# local one (no machine: field) to prove the routing branch falls out cleanly.
REG_SECONDMATES='# Secondmates
- cabin-sm - RoyBot remote dev (home: /home/cap/firstmate; scope: RoyBot robot control; projects: roybot; added 2026-06-29; machine: cabin-desktop)
- local-sm - local triage (home: HOME_SM_PATH; scope: local triage; projects: alpha; added 2026-06-29)'

# A fake `ssh` that records the transported remote command (its last argv word)
# and answers the two channels: `tmux ...` (window ops + fm-send composer probes)
# and `cat ...` (status carry-back). FAKE_REMOTE_FILE controls what a remote
# `cat` returns; FAKE_REMOTE_MISSING makes it fail (unreachable box). Runs no real
# ssh and no real tmux. A no-op `sleep` keeps the verified-submit loop instant.
make_ssh_stub() {  # <dir> <logfile> -> echoes fakebin dir
  local fb="$1/fakebin" log=$2
  mkdir -p "$fb"
  cat > "$fb/ssh" <<EOF
#!/usr/bin/env bash
set -u
cmd=""
for cmd; do :; done   # last positional arg is the remote command string
printf '%s\n' "\$cmd" >> "$log"
case "\$cmd" in
  "cat "*)
    [ -n "\${FAKE_REMOTE_MISSING:-}" ] && exit 1
    [ -n "\${FAKE_REMOTE_FILE:-}" ] && cat "\$FAKE_REMOTE_FILE"
    ;;
  *has-session*)  exit 0 ;;          # the box's session already exists
  *list-windows*) : ;;               # no window pre-exists on the box
  *cursor_y*)     printf '0\n' ;;     # composer probe: numeric cursor row
  *capture-pane*) : ;;               # empty composer / empty pane
  *)              : ;;               # new-window / new-session / send-keys
esac
exit 0
EOF
  chmod +x "$fb/ssh"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# A home with the machine + secondmate registries and an empty state/ dir.
make_remote_home() {  # -> echoes home dir
  local home
  home=$(fm_test_tmproot fm-m3)
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$REG_MACHINES" > "$home/data/machines.md"
  printf '%s\n' "$REG_SECONDMATES" > "$home/data/secondmates.md"
  printf '%s\n' "$home"
}

# Run fm-spawn against the real bin/ (FM_ROOT defaults to $ROOT) with the test
# home's data/state and the fake ssh on PATH. Settles are zeroed for determinism.
run_remote_spawn() {  # <fakebin> <home> [spawn-args...]
  local fb=$1 home=$2; shift 2
  env PATH="$fb:$PATH" TMUX='' \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_MACHINES_BIN="$MACHINES" \
    FM_SPAWN_NO_GUARD=1 FM_SPAWN_REMOTE_SETTLE=0 FM_SEND_SETTLE=0 \
    "$SPAWN" "$@"
}

# ---------------------------------------------------------------------------
# Remote spin-up constructs the box-side Remote Control launch over the wire.
# ---------------------------------------------------------------------------
test_remote_spawn_constructs_commands() {
  local home fb log out meta
  home=$(make_remote_home)
  log="$home/ssh.log"
  fb=$(make_ssh_stub "$home" "$log")

  out=$(run_remote_spawn "$fb" "$home" cabin-sm claude --secondmate 2>"$home/spawn.err") \
    || { echo "--- spawn stderr ---"; cat "$home/spawn.err"; fail "remote spawn exited non-zero"; }

  # 1. The window is created in the box's registry tmux-session, in the box home.
  assert_grep "tmux 'new-window' '-d' '-t' 'firstmate' '-n' 'fm-cabin-sm' '-c' '/home/cap/firstmate'" \
    "$log" "remote spawn must create the secondmate window in the box session, in the box home"

  # 2. The launch is `claude remote-control` (ride-along), scoped to the box home,
  #    sent as a single send-keys -l literal.
  assert_grep "claude remote-control --name fm-cabin-sm --permission-mode bypassPermissions" \
    "$log" "remote spawn must launch the box session under claude remote-control"
  # The box-side launch clears the hub overrides and sets FM_HOME to the box home
  # (the home value is single-quoted by shell_quote, so assert the stable,
  # unquoted env-prefix; new-window -c above already proved the box home path).
  assert_grep "FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=" \
    "$log" "the box-side launch must clear the hub overrides and scope FM_HOME to the box"

  # 3. Meta records the routing facts that drive fm-send/fm-peek/fm-status-pull.
  meta="$home/state/cabin-sm.meta"
  assert_present "$meta" "remote spawn must write the secondmate meta"
  assert_grep "kind=secondmate"               "$meta" "meta records kind=secondmate"
  assert_grep "machine=cabin-desktop"         "$meta" "meta records the box machine="
  assert_grep "host=cabin-desktop.ts.net"     "$meta" "meta records the box host="
  assert_grep "remote_home=/home/cap/firstmate" "$meta" "meta records the remote home"
  assert_grep "window=firstmate:fm-cabin-sm"  "$meta" "meta records the box session:window"

  # 4. The charter pointer is delivered as a from-firstmate request over the wire.
  assert_grep "[fm-from-firstmate]" "$log" \
    "the charter pointer must carry the from-firstmate marker"
  assert_grep "Read data/charter.md" "$log" \
    "the charter pointer must tell the box session to read its charter"

  # 5. Status carry-back is armed on the watcher's check cadence.
  assert_present "$home/state/cabin-sm.check.sh" "remote spawn must arm status carry-back"
  assert_grep "fm-status-pull.sh" "$home/state/cabin-sm.check.sh" \
    "the armed check must invoke the status pull"

  # 6. The spawned line reports the machine for the captain-facing trail.
  assert_contains "$out" "machine=cabin-desktop" "the spawned line names the box"
  pass "remote spawn launches the box session under Remote Control and wires routing"
}

# ---------------------------------------------------------------------------
# Registry machine: alone (no meta yet) routes the FIRST spawn remotely.
# ---------------------------------------------------------------------------
test_registry_machine_routes_first_spawn() {
  local home fb log
  home=$(make_remote_home)
  log="$home/ssh.log"
  fb=$(make_ssh_stub "$home" "$log")
  # No state/cabin-sm.meta exists yet: the machine must come from the registry.
  run_remote_spawn "$fb" "$home" cabin-sm claude --secondmate >/dev/null 2>&1 \
    || fail "first remote spawn (registry-only machine) exited non-zero"
  assert_grep "claude remote-control --name fm-cabin-sm" "$log" \
    "a registry machine: with no prior meta must still route the first spawn remotely"
  pass "registry machine: routes the first spawn remotely with no pre-existing meta"
}

# ---------------------------------------------------------------------------
# A box whose registry harness has no Remote Control is refused, not launched.
# ---------------------------------------------------------------------------
test_unsupported_remote_harness_refused() {
  local home fb log err rc
  home=$(make_remote_home)
  # Point local-sm... actually retarget cabin-sm's registry line at pigeonbox via
  # meta machine= (meta wins), whose registry harness is codex (no remote-control).
  fm_write_meta "$home/state/cabin-sm.meta" \
    "window=firstmate:fm-cabin-sm" "kind=secondmate" "home=/home/cap/firstmate" "machine=pigeonbox"
  log="$home/ssh.log"
  fb=$(make_ssh_stub "$home" "$log")
  err="$home/err"
  run_remote_spawn "$fb" "$home" cabin-sm claude --secondmate >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unsupported remote harness must refuse to launch"
  assert_contains "$(cat "$err")" "Remote Control only" \
    "the refusal must explain that only claude Remote Control is supported"
  assert_absent "$log" "a refused remote spawn must make no ssh call"
  pass "remote spawn refuses a box whose harness has no Remote Control"
}

# ---------------------------------------------------------------------------
# §5.1 ROUND-TRIP: a marked work line IN, a status line carried BACK.
# ---------------------------------------------------------------------------
test_roundtrip_in_and_back() {
  local home fb log status_local
  home=$(make_remote_home)
  log="$home/ssh.log"
  fb=$(make_ssh_stub "$home" "$log")
  # A remote secondmate already running on the box (meta as fm-spawn would write).
  fm_write_meta "$home/state/cabin-sm.meta" \
    "window=firstmate:fm-cabin-sm" "kind=secondmate" "harness=claude" \
    "machine=cabin-desktop" "host=cabin-desktop.ts.net" "remote_home=/home/cap/firstmate"

  # IN: route a marked work line to the box. fm-send re-derives the transport from
  # meta machine= and marks it from-firstmate, then transports send-keys over ssh.
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_MACHINES_BIN="$MACHINES" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" fm-cabin-sm "ROUNDTRIP_WORK_77" >/dev/null 2>&1 \
    || fail "routing a work line to the remote secondmate failed"
  assert_grep "send-keys" "$log" "the work line must be transported as a remote tmux send-keys"
  assert_grep "ROUNDTRIP_WORK_77" "$log" "the work line text must reach the box over the wire"
  assert_grep "[fm-from-firstmate]" "$log" "the work line must be marked from-firstmate"

  # BACK: the box appended to its own state/<id>.status; the hub pulls + mirrors it
  # into the hub-local state/<id>.status, where scan_signals wakes on it.
  printf 'working: on it\ndone: PR https://example.invalid/pr/9\n' > "$home/remote-status"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_MACHINES_BIN="$MACHINES" \
    FAKE_REMOTE_FILE="$home/remote-status" \
    "$ROOT/bin/fm-status-pull.sh" cabin-sm >/dev/null 2>&1 \
    || fail "status carry-back pull failed"
  status_local="$home/state/cabin-sm.status"
  assert_present "$status_local" "the carried-back status must land in the hub-local state file"
  assert_grep "done: PR https://example.invalid/pr/9" "$status_local" \
    "the box's escalation must be mirrored into the hub-local status file"
  pass "round-trip: a marked work line goes in over ssh and a status line is carried back"
}

# ---------------------------------------------------------------------------
# LOCAL path UNCHANGED: a secondmate with no machine= uses local tmux, makes NO
# ssh call, and writes no machine= meta.
# ---------------------------------------------------------------------------
test_local_secondmate_path_unchanged() {
  local home hub sm fb_ssh ssh_log tmux_log meta
  home=$(fm_test_tmproot fm-m3-local)
  hub="$home/hub"
  sm="$home/sm"
  mkdir -p "$hub/state" "$hub/data"
  # A minimal, valid local secondmate home (marker + AGENTS.md + bin/ + charter).
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' sm > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  # Registry: a LOCAL secondmate line (no machine: field) pointing at the home.
  printf -- '- sm - local dev (home: %s; scope: local dev; projects: alpha; added 2026-06-29)\n' \
    "$sm" > "$hub/data/secondmates.md"

  # Fake ssh (must NOT be called) + fake tmux (the local window path) on PATH.
  ssh_log="$home/ssh.log"
  fb_ssh=$(make_ssh_stub "$home" "$ssh_log")
  tmux_log="$home/tmux.log"
  cat > "$fb_ssh/tmux" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$tmux_log"
case "\${1:-}" in
  list-windows) ;;                 # no window pre-exists
  has-session)  exit 0 ;;
  display-message) printf 'firstmate\n' ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$fb_ssh/tmux"

  # FM_ROOT = the real repo so primary_head_commit resolves (the local secondmate
  # home is not a git worktree, so the pre-launch sync simply warns and launches
  # unchanged — the path being exercised is the LOCAL window launch, not the FF).
  env PATH="$fb_ssh:$PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$hub" \
    FM_STATE_OVERRIDE="$hub/state" FM_DATA_OVERRIDE="$hub/data" \
    FM_PROJECTS_OVERRIDE="$hub/projects" FM_CONFIG_OVERRIDE="$hub/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" sm "$sm" claude --secondmate >/dev/null 2>&1 || true

  # The local window path ran on local tmux...
  assert_grep "new-window" "$tmux_log" "the local secondmate path must create a local tmux window"
  # ...and NOTHING was transported over ssh.
  assert_absent "$ssh_log" "the local secondmate path must make no ssh call"
  # ...and the meta carries no machine= (so routing stays local).
  meta="$hub/state/sm.meta"
  assert_present "$meta" "the local secondmate meta must be written"
  assert_grep "kind=secondmate" "$meta" "the local secondmate meta records kind=secondmate"
  assert_no_grep "machine=" "$meta" "the local secondmate meta must carry no machine= (stays local)"
  pass "local secondmate spawn is unchanged: local tmux, no ssh, no machine= meta"
}

test_remote_spawn_constructs_commands
test_registry_machine_routes_first_spawn
test_unsupported_remote_harness_refused
test_roundtrip_in_and_back
test_local_secondmate_path_unchanged

echo "# all fm-spawn-remote-secondmate (multi-machine M3) tests passed"
