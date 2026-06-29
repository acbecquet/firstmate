#!/usr/bin/env bash
# Behavior tests for bin/fm-machine-ping.sh — the multi-machine M4 reachability
# probe. The probe runs a cheap non-interactive `ssh <host> true` over each remote
# machine's transport and records the result back into data/machines.md as the
# line's status: (online|offline) and last-seen <date>, leaving the captain-set
# reachability: hint and every other field untouched.
#
# MOCK-ONLY and deterministic: a fake `ssh` on PATH decides reachability by host
# (FAKE_OFFLINE_HOSTS), so NO real ssh and NO real network run. FM_PING_DATE pins
# the recorded date. These pin:
#   - probe-all flips an online and an offline box's status and stamps last-seen;
#   - a local/hub-transport machine is skipped and left untouched;
#   - `reachability:` and other fields are never rewritten;
#   - `check <id>` probes WITHOUT writing and exits 0 online / 1 offline;
#   - a missing status:/last-seen field is inserted rather than left stale;
#   - an absent registry / unknown id fails cleanly (always exit 0 for the probe).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PING="$ROOT/bin/fm-machine-ping.sh"
MACHINES="$ROOT/bin/fm-machines.sh"

REG_FIXTURE='# Machine registry
- cabin-desktop - cabin box, WSL2 (host: cabin-desktop.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: offline; last-seen 2026-01-01)
- sleepy-box - sometimes-off box (host: sleepy.ts.net; transport: tailscale-ssh; reachability: intermittent; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-01-01)
- the-hub - the hub itself (host: localhost; transport: hub; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: none; status: online; last-seen 2026-01-01)'

# A fake `ssh` whose reachability is host-driven: it exits non-zero (unreachable)
# when any of its argv words is listed in FAKE_OFFLINE_HOSTS, else exits 0. The
# probe runs `ssh <opts> <host> true`, so the host word is in argv. No real ssh.
make_ssh_stub() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/ssh" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  for off in ${FAKE_OFFLINE_HOSTS:-}; do
    [ "$a" = "$off" ] && exit 255
  done
done
exit 0
SH
  chmod +x "$fb/ssh"
  printf '%s\n' "$fb"
}

setup_home() {  # -> echoes a fresh home with registry
  local home
  home=$(fm_test_tmproot fm-machine-ping)
  mkdir -p "$home/data"
  printf '%s\n' "$REG_FIXTURE" > "$home/data/machines.md"
  printf '%s\n' "$home"
}

run_ping() {  # <fakebin> <home> [env=val...] -- <ping args...>
  local fb=$1 home=$2; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_MACHINES_BIN="$MACHINES" FM_PING_DATE=2026-06-29 \
    "${envs[@]}" "$PING" "$@"
}

reg_line() {  # <home> <id> -> the registry line for <id>
  grep -E "^- $2 " "$1/data/machines.md"
}

test_probe_all_flips_status_and_stamps_date() {
  local home fb out
  home=$(setup_home)
  fb=$(make_ssh_stub "$home")
  # sleepy is offline; cabin is online.
  out=$(run_ping "$fb" "$home" FAKE_OFFLINE_HOSTS="sleepy.ts.net" -- 2>/dev/null)
  assert_contains "$out" "cabin-desktop: online" "an answering box should report online"
  assert_contains "$out" "sleepy-box: offline" "a non-answering box should report offline"
  # cabin flips offline->online, sleepy flips online->offline; both stamp the date.
  assert_contains "$(reg_line "$home" cabin-desktop)" "status: online" "cabin status should be rewritten online"
  assert_contains "$(reg_line "$home" cabin-desktop)" "last-seen 2026-06-29" "cabin last-seen should be stamped"
  assert_contains "$(reg_line "$home" sleepy-box)" "status: offline" "sleepy status should be rewritten offline"
  assert_contains "$(reg_line "$home" sleepy-box)" "last-seen 2026-06-29" "sleepy last-seen should be stamped"
  pass "probe-all flips each remote box's status and stamps last-seen"
}

test_hub_machine_untouched() {
  local home fb before after
  home=$(setup_home)
  fb=$(make_ssh_stub "$home")
  before=$(reg_line "$home" the-hub)
  run_ping "$fb" "$home" -- >/dev/null 2>&1
  after=$(reg_line "$home" the-hub)
  [ "$before" = "$after" ] || fail "a hub/local-transport machine must be left untouched by the probe"
  pass "probe skips and never rewrites a local/hub machine"
}

test_reachability_and_other_fields_preserved() {
  local home fb line
  home=$(setup_home)
  fb=$(make_ssh_stub "$home")
  run_ping "$fb" "$home" FAKE_OFFLINE_HOSTS="sleepy.ts.net" -- >/dev/null 2>&1
  line=$(reg_line "$home" sleepy-box)
  assert_contains "$line" "reachability: intermittent" "the captain-set reachability hint must be preserved"
  assert_contains "$line" "host: sleepy.ts.net" "the host field must be preserved"
  assert_contains "$line" "harness: claude" "the harness field must be preserved"
  assert_contains "$line" "tmux-session: firstmate" "the tmux-session field must be preserved"
  pass "the probe rewrites only status:/last-seen, never reachability: or other fields"
}

test_check_no_write_online() {
  local home fb before rc out
  home=$(setup_home)
  fb=$(make_ssh_stub "$home")
  before=$(cat "$home/data/machines.md")
  out=$(run_ping "$fb" "$home" -- check cabin-desktop 2>/dev/null); rc=$?
  expect_code 0 "$rc" "check on a reachable box should exit 0"
  assert_contains "$out" "cabin-desktop: online" "check should report online"
  [ "$before" = "$(cat "$home/data/machines.md")" ] || fail "check must NOT rewrite the registry"
  pass "check probes without writing and exits 0 for a reachable box"
}

test_check_offline_exit_nonzero() {
  local home fb rc out
  home=$(setup_home)
  fb=$(make_ssh_stub "$home")
  out=$(run_ping "$fb" "$home" FAKE_OFFLINE_HOSTS="cabin-desktop.ts.net" -- check cabin-desktop 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "check on an unreachable box must exit non-zero"
  assert_contains "$out" "cabin-desktop: offline" "check should report offline for an unreachable box"
  pass "check exits non-zero and reports offline for an unreachable box"
}

test_inserts_missing_fields() {
  local home fb line
  home=$(fm_test_tmproot fm-machine-ping-bare)
  mkdir -p "$home/data"
  # A hand-written line with NO status: and NO last-seen fields.
  printf '%s\n' '# reg
- bare-box - minimal line (host: bare.ts.net; transport: tailscale-ssh; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl)' \
    > "$home/data/machines.md"
  fb=$(make_ssh_stub "$home")
  run_ping "$fb" "$home" -- bare-box >/dev/null 2>&1
  line=$(reg_line "$home" bare-box)
  assert_contains "$line" "status: online" "a missing status: field should be inserted"
  assert_contains "$line" "last-seen 2026-06-29" "a missing last-seen field should be inserted"
  # The line must still be parseable and end well-formed.
  run_ping "$fb" "$home" -- check bare-box >/dev/null 2>&1 || fail "the upgraded line must stay a valid registry entry"
  pass "the probe inserts a missing status:/last-seen field rather than leaving it stale"
}

test_absent_registry_clean() {
  local home fb rc
  home=$(fm_test_tmproot fm-machine-ping-none)
  mkdir -p "$home/data"   # no machines.md
  fb=$(make_ssh_stub "$home")
  run_ping "$fb" "$home" -- >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "probe with no registry must exit 0 cleanly"
  pass "probe with an absent registry is a clean no-op (exit 0)"
}

test_unknown_id_clean() {
  local home fb rc err
  home=$(setup_home)
  fb=$(make_ssh_stub "$home")
  err="$home/err"
  run_ping "$fb" "$home" -- not-a-machine 2>"$err" >/dev/null; rc=$?
  expect_code 0 "$rc" "probing an unknown id must still exit 0 (non-fatal)"
  assert_contains "$(cat "$err")" "not a registered machine" "an unknown id should be reported"
  pass "probing an unknown machine id fails cleanly without aborting"
}

test_probe_all_flips_status_and_stamps_date
test_hub_machine_untouched
test_reachability_and_other_fields_preserved
test_check_no_write_online
test_check_offline_exit_nonzero
test_inserts_missing_fields
test_absent_registry_clean
test_unknown_id_clean

echo "# all fm-machine-ping (multi-machine M4 reachability probe) tests passed"
