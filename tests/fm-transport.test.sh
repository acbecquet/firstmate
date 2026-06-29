#!/usr/bin/env bash
# Behavior tests for the multi-machine M2 transport adapter:
#   - bin/fm-tmux-lib.sh: fm_shquote + fm_tmux. PROVES the local path is
#     byte-for-byte unchanged (exact tmux argv captured with FM_TMUX_SSH unset),
#     and that a remote target is transported as `<prefix> "tmux '<args>'"`.
#   - bin/fm-machines.sh ssh-prefix: transport+host -> ssh command prefix.
#   - bin/fm-transport-lib.sh: fm_transport_arm precedence (FM_TMUX_SSH override >
#     FM_TARGET_MACHINE > meta machine=) and the stranger-pane guard.
#   - MOCK E2E: fm-peek/fm-send driving a remote target end to end through the
#     registry + meta, with a fake `ssh` recording the transported `tmux ...`
#     command. Runs NO real ssh and NO real tmux (a real-tmux loopback once
#     killed the shared tmux server hosting live supervision); it asserts the
#     constructed command string, the only transport logic that matters.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMUXLIB="$ROOT/bin/fm-tmux-lib.sh"
TRANSPORTLIB="$ROOT/bin/fm-transport-lib.sh"
MACHINES="$ROOT/bin/fm-machines.sh"
PEEK="$ROOT/bin/fm-peek.sh"
SEND="$ROOT/bin/fm-send.sh"

# Source the tmux lib once at top level (repo idiom) so fm_shquote/fm_tmux are
# available to the test functions and subshells without re-sourcing.
# shellcheck source=bin/fm-tmux-lib.sh
. "$TMUXLIB"
unset FM_TMUX_SSH FM_TARGET_MACHINE 2>/dev/null || true

# ---------------------------------------------------------------------------
# fm_shquote: single-quote-escape for a remote shell re-parse
# ---------------------------------------------------------------------------
test_shquote() {
  [ "$(fm_shquote "abc")" = "'abc'" ] || fail "shquote plain"
  [ "$(fm_shquote "a b")" = "'a b'" ] || fail "shquote spaces"
  [ "$(fm_shquote "it's")" = "'it'\\''s'" ] || fail "shquote embedded quote"
  [ "$(fm_shquote "")" = "''" ] || fail "shquote empty"
  # Round-trip: a shell must re-parse the quoted form back to the original.
  local s="weird 'quoted' \$x #{fmt} | & ;"
  local got
  got=$(eval "printf '%s' $(fm_shquote "$s")")
  [ "$got" = "$s" ] || fail "shquote round-trip (got: '$got')"
  pass "fm_shquote quotes and round-trips through a shell re-parse"
}

# A fakebin dir with a `tmux` (or `ssh`) stub that records its argv, one per line.
make_argv_stub() {  # <dir> <toolname> <logfile>
  local fb="$1/fakebin" tool=$2 log=$3
  mkdir -p "$fb"
  cat > "$fb/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$log"
EOF
  chmod +x "$fb/$tool"
  printf '%s\n' "$fb"
}

# ---------------------------------------------------------------------------
# fm_tmux LOCAL path is byte-for-byte `tmux "$@"` (exact argv captured)
# ---------------------------------------------------------------------------
test_fm_tmux_local_byte_identical() {
  local home fakebin log expected got
  home=$(fm_test_tmproot fm-transport)
  log="$home/tmux-argv.log"
  fakebin=$(make_argv_stub "$home" tmux "$log")
  PATH="$fakebin:$PATH" fm_tmux capture-pane -e -p -t sess:win -S 5 -E 5
  expected=$(printf '%s\n' capture-pane -e -p -t sess:win -S 5 -E 5)
  got=$(cat "$log")
  [ "$got" = "$expected" ] \
    || fail "local fm_tmux argv differs:"$'\n'"--- got ---"$'\n'"$got"$'\n'"--- want ---"$'\n'"$expected"
  # A second argv shape (send-keys -l with spaces/glyphs) stays exact too.
  PATH="$fakebin:$PATH" fm_tmux send-keys -t s:w -l "hello world ❯ #{x}"
  expected=$(printf '%s\n' send-keys -t s:w -l "hello world ❯ #{x}")
  got=$(cat "$log")
  [ "$got" = "$expected" ] || fail "local send-keys argv differs"
  pass "fm_tmux with FM_TMUX_SSH unset passes argv byte-for-byte to tmux"
}

# ---------------------------------------------------------------------------
# fm_tmux REMOTE path transports as `<prefix> "tmux '<quoted args>'"`
# ---------------------------------------------------------------------------
test_fm_tmux_remote_transport() {
  local home fakebin log dest cmd
  home=$(fm_test_tmproot fm-transport)
  log="$home/ssh-argv.log"
  fakebin=$(make_argv_stub "$home" ssh "$log")
  PATH="$fakebin:$PATH" FM_TMUX_SSH="ssh fakehost" fm_tmux capture-pane -e -p -t s:w
  dest=$(sed -n '1p' "$log")
  cmd=$(sed -n '2p' "$log")
  [ "$dest" = "fakehost" ] || fail "remote: ssh destination should be fakehost (got: '$dest')"
  [ "$cmd" = "tmux 'capture-pane' '-e' '-p' '-t' 's:w'" ] \
    || fail "remote: composed tmux command differs (got: '$cmd')"
  [ "$(wc -l < "$log")" -eq 2 ] || fail "remote: ssh should receive exactly destination + one command"
  # A multi-word prefix (ssh options) word-splits before the remote command.
  PATH="$fakebin:$PATH" FM_TMUX_SSH="ssh -o BatchMode=yes host2" fm_tmux send-keys -t s:w -l "x y"
  [ "$(sed -n '1p' "$log")" = "-o" ] || fail "remote: prefix options should word-split"
  [ "$(sed -n '3p' "$log")" = "host2" ] || fail "remote: destination after options"
  [ "$(sed -n '4p' "$log")" = "tmux 'send-keys' '-t' 's:w' '-l' 'x y'" ] \
    || fail "remote: literal text with a space stays a single quoted arg (got: '$(sed -n '4p' "$log")')"
  pass "fm_tmux with FM_TMUX_SSH transports a shell-quoted tmux command over ssh"
}

# ---------------------------------------------------------------------------
# fm-machines.sh ssh-prefix
# ---------------------------------------------------------------------------
REG_FIXTURE='# Machine registry
- cabin-desktop - cabin box, WSL2 (host: cabin-desktop.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)
- hubbox - the local hub (host: localhost; transport: hub; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: none; status: online; last-seen 2026-06-29)
- weirdbox - bad transport (host: weird.ts.net; transport: carrier-pigeon; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: none; status: online; last-seen 2026-06-29)'

make_reg_home() {
  local home data
  home=$(fm_test_tmproot fm-transport)
  data="$home/data"
  mkdir -p "$data"
  printf '%s\n' "$REG_FIXTURE" > "$data/machines.md"
  printf '%s\n' "$home"
}

run_machines() {
  local home=$1; shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE="$home/data" "$MACHINES" "$@"
}

test_ssh_prefix() {
  local home out
  home=$(make_reg_home)
  out=$(run_machines "$home" ssh-prefix cabin-desktop)
  [ "$out" = "ssh -o BatchMode=yes -o ConnectTimeout=8 cabin-desktop.ts.net" ] \
    || fail "ssh-prefix default opts wrong (got: '$out')"
  out=$(FM_SSH_OPTS='' run_machines "$home" ssh-prefix cabin-desktop)
  [ "$out" = "ssh cabin-desktop.ts.net" ] || fail "ssh-prefix empty FM_SSH_OPTS should be bare (got: '$out')"
  out=$(FM_SSH_OPTS='-o ConnectTimeout=3' run_machines "$home" ssh-prefix cabin-desktop)
  [ "$out" = "ssh -o ConnectTimeout=3 cabin-desktop.ts.net" ] || fail "ssh-prefix custom opts wrong (got: '$out')"
  if run_machines "$home" ssh-prefix hubbox >/dev/null 2>&1; then
    fail "ssh-prefix should refuse a local/hub transport"
  fi
  if run_machines "$home" ssh-prefix weirdbox >/dev/null 2>&1; then
    fail "ssh-prefix should reject an unsupported transport"
  fi
  pass "ssh-prefix maps transport+host to an ssh command and rejects local/unknown transports"
}

# ---------------------------------------------------------------------------
# fm_transport_arm precedence + stranger-pane guard.
# Each scenario runs in an isolated `bash -c` child (the lib sourced fresh) so
# its FM_TMUX_SSH/env never leaks between scenarios and prints RESULT=<prefix>.
# ---------------------------------------------------------------------------
arm_scenario() {  # <data-dir> <state-dir> <raw> <window> [extra env assignment...]
  local data=$1 state=$2 raw=$3 win=$4; shift 4
  # Extra "$@" entries are NAME=VALUE env assignments handed to `env` (so a value
  # with a space, like FM_TMUX_SSH="ssh override-host", stays one assignment). The
  # child shell expands $1..$4 from the positional args after the script string;
  # single quotes are deliberate so THIS shell does not expand them.
  # shellcheck disable=SC2016
  env FM_MACHINES_BIN="$MACHINES" FM_DATA_OVERRIDE="$data" "$@" \
    bash -c '
      lib=$1; raw=$2; win=$3; state=$4
      . "$lib"
      if fm_transport_arm "$raw" "$win" "$state" 2>&1; then
        printf "RESULT=[%s]\n" "${FM_TMUX_SSH:-}"
      else
        printf "REFUSED\n"
      fi
    ' _ "$TRANSPORTLIB" "$raw" "$win" "$state"
}

test_transport_arm() {
  local home data state out
  home=$(make_reg_home)
  data="$home/data"
  state="$home/state"
  mkdir -p "$state"
  fm_write_meta "$state/cabin-sm.meta" \
    "window=firstmate:fm-cabin-sm" "kind=secondmate" "machine=cabin-desktop"
  fm_write_meta "$state/stranger.meta" \
    "window=evil:fm-stranger" "kind=secondmate" "machine=cabin-desktop"
  fm_write_meta "$state/local-sm.meta" \
    "window=firstmate:fm-local-sm" "kind=secondmate" "machine=hub"

  # (1) Explicit FM_TMUX_SSH override is preserved verbatim, no registry lookup.
  out=$(arm_scenario "$data" "$state" "session:win" "session:win" FM_TMUX_SSH="ssh override-host")
  assert_contains "$out" "RESULT=[ssh override-host]" "explicit FM_TMUX_SSH must be preserved"

  # (2) meta machine= resolves to the registry ssh-prefix when the session matches.
  out=$(arm_scenario "$data" "$state" "fm-cabin-sm" "firstmate:fm-cabin-sm")
  assert_contains "$out" "RESULT=[ssh -o BatchMode=yes -o ConnectTimeout=8 cabin-desktop.ts.net]" \
    "meta machine= should resolve to the registry ssh-prefix"

  # (3) Stranger-pane guard: session != registry tmux-session => refused.
  out=$(arm_scenario "$data" "$state" "fm-stranger" "evil:fm-stranger")
  assert_contains "$out" "REFUSED" "a session not matching the registry tmux-session must be refused"

  # (4) machine=hub stays local: FM_TMUX_SSH unset.
  out=$(arm_scenario "$data" "$state" "fm-local-sm" "firstmate:fm-local-sm")
  assert_contains "$out" "RESULT=[]" "machine=hub must stay local (FM_TMUX_SSH unset)"

  # (5) FM_TARGET_MACHINE resolves via the registry.
  out=$(arm_scenario "$data" "$state" "fm-cabin-sm" "firstmate:fm-cabin-sm" FM_TARGET_MACHINE=cabin-desktop)
  assert_contains "$out" "cabin-desktop.ts.net" "FM_TARGET_MACHINE should resolve via the registry"
  pass "fm_transport_arm honors precedence and enforces the stranger-pane guard"
}

# ---------------------------------------------------------------------------
# MOCK E2E: fm-peek and fm-send drive a REMOTE target end to end through the
# registry + meta, with a fake `ssh` on PATH recording the transported command.
#
# This deliberately runs NO real ssh and NO real tmux. A real-tmux loopback test
# (an ephemeral sshd reaching a real tmux server) is unsafe in this environment:
# firstmate's live supervision and this very crewmate's window share the default
# tmux server, and a stray tmux/kill-server in a test once killed it. The only
# logic that matters for the transport is the COMMAND STRING construction — that
# fm-send/fm-peek emit exactly `ssh <host> "tmux '<args>'"` for a remote target —
# so we capture and assert that string with a fake executor and zero real I/O.
# ---------------------------------------------------------------------------

# A fake `ssh` that (1) appends the remote command (its last argv word, the
# "tmux '...'" string) to a log and (2) answers fm-send's composer probes so the
# verified submit reaches a clean "empty" verdict without any real terminal: a
# cursor_y query -> "0", a capture-pane (composer read) -> empty, everything else
# (send-keys) -> no output. Mirrors the local tmux stub used by the marker test,
# but on the ssh side, so it proves the call was TRANSPORTED, not run locally.
make_ssh_responder() {  # <dir> <logfile> -> echoes fakebin dir
  local fb="$1/fakebin" log=$2
  mkdir -p "$fb"
  cat > "$fb/ssh" <<EOF
#!/usr/bin/env bash
set -u
# The last positional argument is the remote command string ("tmux '...'").
cmd=""
for cmd; do :; done
printf '%s\n' "\$cmd" >> "$log"
case "\$cmd" in
  *cursor_y*)     printf '0\n' ;;   # numeric cursor row
  *capture-pane*) : ;;              # empty composer / empty pane
  *)              : ;;              # send-keys: no output
esac
exit 0
EOF
  chmod +x "$fb/ssh"
  # A no-op sleep keeps the verified-submit loop instant and deterministic.
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

test_mock_e2e_peek_send() {
  local home data state fakebin log out
  home=$(make_reg_home)            # data/machines.md: cabin-desktop, tmux-session firstmate
  data="$home/data"
  state="$home/state"
  mkdir -p "$state"
  log="$home/ssh-remote-cmds.log"
  fakebin=$(make_ssh_responder "$home" "$log")
  # A remote secondmate's meta: bare fm-<id> target, machine= a registered box.
  fm_write_meta "$state/cabin-sm.meta" \
    "window=firstmate:fm-cabin-sm" "kind=secondmate" "machine=cabin-desktop" "harness=claude"

  # fm-peek over the (mock) wire: capture-pane is transported to the remote tmux.
  : > "$log"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_MACHINES_BIN="$MACHINES" \
    "$PEEK" fm-cabin-sm 50 >/dev/null 2>&1 || true
  out=$(cat "$log")
  assert_contains "$out" "tmux 'capture-pane' '-p' '-t' 'firstmate:fm-cabin-sm' '-S' '-50'" \
    "fm-peek must transport the capture-pane to the remote tmux over ssh"

  # fm-send over the (mock) wire: the literal line is transported as a remote
  # `tmux send-keys -l`, and the verifying Enter as a remote `tmux send-keys
  # Enter`. The text carries the from-firstmate marker (a secondmate target), so
  # assert the marker text as a substring of the transported send-keys line.
  : > "$log"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_MACHINES_BIN="$MACHINES" \
    FM_SEND_SETTLE=0 \
    "$SEND" fm-cabin-sm "MOCK_MARKER_42" >/dev/null 2>&1 || true
  out=$(cat "$log")
  assert_contains "$out" "send-keys" "fm-send must transport send-keys to the remote tmux over ssh"
  assert_contains "$out" "MOCK_MARKER_42" "fm-send must transport the literal line to the remote pane"
  assert_contains "$out" "tmux 'send-keys' '-t' 'firstmate:fm-cabin-sm' 'Enter'" \
    "fm-send must transport the verifying Enter to the remote tmux"
  pass "mock E2E: fm-peek and fm-send drive a remote target through ssh (no real tmux/ssh)"
}

test_shquote
test_fm_tmux_local_byte_identical
test_fm_tmux_remote_transport
test_ssh_prefix
test_transport_arm
test_mock_e2e_peek_send

echo "# all fm-transport (multi-machine M2) tests passed"
