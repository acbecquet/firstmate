#!/usr/bin/env bash
# Behavior tests for multi-machine M5: cross-machine self-update. A machine:-tagged
# secondmate home lives on another box with its OWN origin and object store, so the
# hub cannot converge it with a local fast-forward. fm-update.sh (the /updatefirstmate
# mechanics) instead advances it by running the SAME guarded, origin-base,
# fast-forward-only update ON THE BOX over the transport. A local secondmate stays on
# today's local path and makes NO ssh call.
#
# MOCK-ONLY and deterministic: a fake `ssh` on PATH EXECUTES the box-side command it
# is handed against a real LOCAL git clone that stands in for "the box's firstmate
# home" (its remote_home points at that local dir), so the box-side guarded
# fast-forward is exercised for real with NO ssh and NO network. These pin:
#   - a remote secondmate is fast-forwarded over the transport (fetch + ff-only),
#     its box clone actually advances, and an instruction change nudges it;
#   - the box-side update is fast-forward-ONLY and guarded (a diverged box is skipped
#     and its commit preserved);
#   - an unreachable box is a clean skip, not an error, leaving the box unchanged;
#   - a LOCAL secondmate update makes NO ssh call (today's path, unchanged);
#   - a registry-only (no live meta) remote secondmate is routed over the transport.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"
MACHINES="$ROOT/bin/fm-machines.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-xmachine)

REG_MACHINES='# Machine registry
- cabin-desktop - cabin box, WSL2 (host: cabin-desktop.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)'

# A fake `ssh` that EXECUTES the transported box-side command locally. The box-side
# script begins `cd '<remote_home>' && ...`, and the test points remote_home at a
# real local clone, so `git fetch`/`git merge --ff-only` run for real against that
# clone — the high-fidelity stand-in for "the box". The command is also logged so a
# test can assert what crossed the wire. FAKE_OFFLINE makes every ssh fail (an
# asleep / off-tailnet box). No real ssh, no network.
make_ssh_exec_stub() {  # <dir> <logfile> -> echoes fakebin dir
  local fb="$1/fakebin" log=$2
  mkdir -p "$fb"
  cat > "$fb/ssh" <<EOF
#!/usr/bin/env bash
set -u
cmd=""
for cmd; do :; done   # last positional arg is the remote command string
printf '%s\n' "\$cmd" >> "$log"
[ -n "\${FAKE_OFFLINE:-}" ] && exit 255
bash -c "\$cmd"
EOF
  chmod +x "$fb/ssh"
  printf '%s\n' "$fb"
}

# A fake `ssh` that must NEVER run: it records its invocation so a test can prove the
# local path took no transport. Used for the local-secondmate (no machine=) case.
make_ssh_forbidden_stub() {  # <dir> <logfile> -> echoes fakebin dir
  local fb="$1/fakebin" log=$2
  mkdir -p "$fb"
  cat > "$fb/ssh" <<EOF
#!/usr/bin/env bash
printf 'FORBIDDEN ssh call: %s\n' "\$*" >> "$log"
exit 0
EOF
  chmod +x "$fb/ssh"
  printf '%s\n' "$fb"
}

# Build a world: a bare origin (one commit, instruction surface seeded), a firstmate
# repo clone on main (FM_ROOT), and a home with state/ + data/ carrying the machine
# registry. Echoes the world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"   # keep fm-guard quiet
  printf '%s\n' "$REG_MACHINES" > "$w/home/data/machines.md"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$w"
}

# Advance origin by one commit. mode=instr changes the instruction surface.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

# A "box" firstmate home: a standalone clone of origin, on main, at the origin tip
# BEFORE the bump (so a later origin fast-forward advances it). Echoes its path.
make_box_home() {  # <world> <name>
  local w=$1 name=$2 box="$1/box-$2"
  git clone -q "$w/origin.git" "$box"
  git -C "$box" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$box"
}

# Write a remote-secondmate meta (machine= + remote_home= drive the transport route).
write_remote_meta() {  # <world> <id> <box-home>
  fm_write_meta "$1/home/state/$2.meta" \
    "window=firstmate:fm-$2" "kind=secondmate" "harness=claude" \
    "machine=cabin-desktop" "host=cabin-desktop.ts.net" "remote_home=$3"
}

run_update() {  # <world> <fakebin> [env=val...]
  local w=$1 fb=$2; shift 2
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_MACHINES_BIN="$MACHINES" "$@" \
    "$UPDATE" 2>/dev/null
}

# --- A: remote secondmate fast-forwards over the transport, and is nudged ----
test_remote_secondmate_updates_over_transport() {
  local w fb log box out
  w=$(new_world a)
  log="$w/ssh.log"
  fb=$(make_ssh_exec_stub "$w" "$log")
  box=$(make_box_home "$w" cabin)
  write_remote_meta "$w" cabin-sm "$box"
  bump_origin "$w" instr

  out=$(run_update "$w" "$fb")

  # The update was reported as an advance for the remote secondmate...
  assert_contains "$out" "secondmate cabin-sm: updated " "remote secondmate fast-forwarded over the transport"
  # ...the box-side command that crossed the wire was a guarded, ff-only origin sync...
  assert_grep "fetch origin" "$log" "the box-side update must fetch origin"
  assert_grep "merge --ff-only" "$log" "the box-side update must be fast-forward-only"
  # ...the box clone actually advanced to origin/main...
  [ "$(git -C "$box" rev-parse HEAD)" = "$(git -C "$box" rev-parse origin/main)" ] \
    || fail "the box clone did not advance to origin/main over the transport"
  # ...it was a single-parent fast-forward (never a merge commit)...
  [ "$(git -C "$box" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "the box advance is not a single-parent fast-forward"
  # ...and the instruction change nudges it to re-read.
  assert_contains "$out" "nudge-secondmates: firstmate:fm-cabin-sm" "an instruction change nudges the remote secondmate"
  pass "A: remote secondmate fast-forwards over the transport (fetch + ff-only), advances, and is nudged"
}

# --- B: a LOCAL secondmate makes NO ssh call (today's path, unchanged) -------
test_local_secondmate_makes_no_ssh() {
  local w fb log out
  w=$(new_world b)
  log="$w/ssh.log"
  fb=$(make_ssh_forbidden_stub "$w" "$log")
  # A local secondmate: a detached worktree of the firstmate repo, NO machine=.
  git -C "$w/main" worktree add -q --detach "$w/local-sm" main
  printf 'local-sm\n' > "$w/local-sm/.fm-secondmate-home"
  fm_write_meta "$w/home/state/local-sm.meta" \
    "window=main:fm-local-sm" "kind=secondmate" "home=$w/local-sm"
  bump_origin "$w" instr

  out=$(run_update "$w" "$fb")

  assert_contains "$out" "secondmate local-sm: updated " "the local secondmate still fast-forwards locally"
  assert_absent "$log" "the local secondmate path must make NO ssh call"
  [ "$(git -C "$w/local-sm" rev-parse HEAD)" = "$(git -C "$w/local-sm" rev-parse origin/main)" ] \
    || fail "the local secondmate did not advance via the local path"
  pass "B: a local secondmate update stays local and makes no ssh call"
}

# --- C: an unreachable box is a clean skip, box left unchanged ---------------
test_offline_box_clean_skip() {
  local w fb log box out before rc
  w=$(new_world c)
  log="$w/ssh.log"
  fb=$(make_ssh_exec_stub "$w" "$log")
  box=$(make_box_home "$w" cabin)
  write_remote_meta "$w" cabin-sm "$box"
  before=$(git -C "$box" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(env FAKE_OFFLINE=1 PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" FM_MACHINES_BIN="$MACHINES" \
    "$UPDATE" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "self-update must stay non-fatal even when a box is unreachable"
  assert_contains "$out" "secondmate cabin-sm: skipped: machine \"cabin-desktop\" unreachable" \
    "an unreachable box is reported as a clean skip"
  assert_not_contains "$out" "nudge-secondmates: firstmate:fm-cabin-sm" "an unreachable box is not nudged"
  [ "$(git -C "$box" rev-parse HEAD)" = "$before" ] \
    || fail "an unreachable box's clone must be left unchanged"
  pass "C: an unreachable box is skipped cleanly (exit 0) and left unchanged"
}

# --- D: a diverged box is skipped, its local commit preserved ----------------
test_diverged_box_skipped() {
  local w fb log box out before
  w=$(new_world d)
  log="$w/ssh.log"
  fb=$(make_ssh_exec_stub "$w" "$log")
  box=$(make_box_home "$w" cabin)
  # The box made its own commit, diverging from origin.
  printf 'box-local-work\n' >> "$box/README.md"
  git -C "$box" add -A
  git -C "$box" commit -qm box-work
  before=$(git -C "$box" rev-parse HEAD)
  write_remote_meta "$w" cabin-sm "$box"
  bump_origin "$w" instr

  out=$(run_update "$w" "$fb")

  assert_contains "$out" "secondmate cabin-sm: skipped: diverged from" "a diverged box is skipped"
  [ "$(git -C "$box" rev-parse HEAD)" = "$before" ] \
    || fail "a diverged box's HEAD moved (unlanded work at risk)"
  pass "D: a diverged box is skipped fast-forward-only, its commit preserved"
}

# --- E: a registry-only (no live meta) remote secondmate routes over transport
test_registry_backstop_remote() {
  local w fb log box out
  w=$(new_world e)
  log="$w/ssh.log"
  fb=$(make_ssh_exec_stub "$w" "$log")
  box=$(make_box_home "$w" cabin)
  # No state meta; only a registry line with machine: at the end.
  printf -- '- cabin-sm - remote dev (home: %s; scope: x; projects: p; added 2026-06-29; machine: cabin-desktop)\n' \
    "$box" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w" "$fb")

  assert_contains "$out" "secondmate cabin-sm: updated " "a registry-only remote secondmate routes over the transport"
  assert_grep "merge --ff-only" "$log" "the registry-backstop remote update must be fast-forward-only"
  [ "$(git -C "$box" rev-parse HEAD)" = "$(git -C "$box" rev-parse origin/main)" ] \
    || fail "the registry-only box clone did not advance"
  pass "E: a registry-only remote secondmate is fast-forwarded over the transport"
}

test_remote_secondmate_updates_over_transport
test_local_secondmate_makes_no_ssh
test_offline_box_clean_skip
test_diverged_box_skipped
test_registry_backstop_remote

echo "# all fm-cross-machine-update (multi-machine M5) tests passed"
