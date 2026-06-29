#!/usr/bin/env bash
# tests/m3-roundtrip-live.sh — MANUAL, REAL, isolated multi-machine M3 round-trip.
#
# NOT part of the committed `tests/*.test.sh` suite (its name ends in .sh, not
# .test.sh, so CI never runs it). The committed, deterministic, mock-based proof
# of the same behavior is tests/fm-spawn-remote-secondmate.test.sh. This script
# is the real-wire confirmation firstmate runs BY HAND, on demand.
#
# What it proves (the §5.1 round-trip, AGENTS.md section 14): with a SECOND
# FM_HOME on this same box standing in for "the remote box", reached over real
# `ssh localhost` through the transport,
#   1. a marked work line routed IN with fm-send reaches the "box" pane, and
#   2. a status line the "box" writes is carried BACK into the hub's local
#      state/<id>.status by fm-status-pull (where the watcher's signal scan wakes).
# It also exercises fm-peek over the wire as a read-side check.
#
# ── ABSOLUTE TMUX SAFETY ───────────────────────────────────────────────────
# The DEFAULT tmux server hosts firstmate's live supervision and every crewmate
# pane. This harness NEVER touches it. EVERY tmux call — local and the ones that
# cross `ssh localhost` — is pinned to the PRIVATE server `-L fm-m3-test`:
#   - local calls use `tmux -L fm-m3-test ...` directly;
#   - the transport prefix is a wrapper that rewrites a remote `tmux ...` to
#     `tmux -L fm-m3-test ...` BEFORE running it over ssh, so a remote tmux can
#     never land on the box's default server either.
# Teardown kills ONLY `-L fm-m3-test` and removes ONLY this run's temp homes.
#
# Clean skip: if `ssh localhost` is not usable non-interactively (no sshd, no
# key-based auth, BatchMode refused), the harness prints SKIP and exits 0.
#
# Usage:
#   tests/m3-roundtrip-live.sh
# Optional env:
#   FM_M3_SSH_OPTS   ssh options (default: -o BatchMode=yes -o ConnectTimeout=8)
set -u

SOCK=fm-m3-test                      # the PRIVATE tmux server; never the default
SES=fm-m3-live                       # private session name
SMID=m3box-sm                        # the simulated remote secondmate id
WIN="fm-$SMID"
TARGET="$SES:$WIN"
SSH_OPTS=${FM_M3_SSH_OPTS:-"-o BatchMode=yes -o ConnectTimeout=8"}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND="$ROOT/bin/fm-send.sh"
PEEK="$ROOT/bin/fm-peek.sh"
PULL="$ROOT/bin/fm-status-pull.sh"
MACHINES="$ROOT/bin/fm-machines.sh"

note() { printf '%s\n' "$*"; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*"; exit 0; }

# --- preflight: a usable non-interactive ssh localhost ----------------------
# shellcheck disable=SC2086  # SSH_OPTS is a deliberate option word list.
if ! ssh $SSH_OPTS localhost true >/dev/null 2>&1; then
  skip "ssh localhost is not usable non-interactively (no sshd / no key-based auth); cannot run the live round-trip"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/m3-live.XXXXXX") || die "mktemp failed"
HUB="$TMP/hub"          # the hub firstmate home
BOX="$TMP/box"          # the SECOND FM_HOME standing in for the remote box
WRAP="$TMP/transport-wrap.sh"
mkdir -p "$HUB/state" "$HUB/data" "$BOX/state" "$BOX/data"

cleanup() {
  # Kill ONLY the private server (sanctioned: it is -L fm-m3-test, never default).
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  # FM_M3_KEEP=1 preserves the temp homes for manual inspection of a failed run.
  if [ -n "${FM_M3_KEEP:-}" ]; then
    printf 'FM_M3_KEEP: left temp homes at %s\n' "$TMP" >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

# --- transport wrapper: pin remote tmux to the private server ---------------
# fm_tmux invokes:  <FM_TMUX_SSH> "tmux '<args>'"  (or "cat '<path>'" for pulls).
# This wrapper rewrites a leading `tmux ` to `tmux -L fm-m3-test ` so the REMOTE
# tmux uses the private server too, then runs the command over ssh localhost.
# Non-tmux remote commands (the status-pull `cat`) pass through untouched.
cat > "$WRAP" <<EOF
#!/usr/bin/env bash
set -u
remote=\$1
case "\$remote" in
  "tmux "*) remote="tmux -L $SOCK \${remote#tmux }" ;;
esac
exec ssh $SSH_OPTS localhost "\$remote"
EOF
chmod +x "$WRAP"

# --- the "box" pane: a stand-in firstmate that records what it receives ------
# A line-buffered reader in the box window. Each non-empty line it receives over
# the composer (what fm-send types) is logged to inbox.log AND turned into a
# status line in the box home's state/<id>.status — exactly where a real remote
# secondmate's charter retargets its escalation, on the box.
LOOP="$TMP/box-loop.sh"
cat > "$LOOP" <<EOF
#!/usr/bin/env bash
# Signal readiness so the harness only types in once the read loop is live (the
# pane's shell takes a beat to start; typing before it is up would lose the line).
touch "$BOX/.box-ready"
while IFS= read -r line; do
  [ -n "\$line" ] || continue
  printf '%s\n' "\$line" >> "$BOX/inbox.log"
  printf 'done: box received a work line\n' >> "$BOX/state/$SMID.status"
done
EOF
chmod +x "$LOOP"

note "starting the private box pane on the -L $SOCK server ..."
tmux -L "$SOCK" new-session -d -s "$SES" -n "$WIN" "bash '$LOOP'" \
  || die "could not start the private box session"

# Wait (bounded) until the box read loop is live before typing into its pane.
box_ready=
for _ in $(seq 1 50); do
  if [ -f "$BOX/.box-ready" ]; then box_ready=1; break; fi
  sleep 0.1
done
[ -n "$box_ready" ] || die "the box pane did not become ready"

# --- registry + meta: route fm-send/fm-status-pull at the box over ssh ------
# machines.md: the box is reached at localhost over a plain ssh transport. Its
# tmux-session matches the private session so fm-status-pull's ssh-prefix resolves
# (status-pull runs only `cat`, never tmux, so it is safe over plain ssh).
# NB: the desc must not contain parentheses — fm-machines.sh parses the first
# "(" as the start of the field block.
cat > "$HUB/data/machines.md" <<EOF
- m3box - live loopback box for $SMID (host: localhost; transport: ssh; reachability: online; fm-home: $BOX; harness: claude; tmux-session: $SES; auth: local; status: online; last-seen 2026-06-29)
EOF
# Hub meta for the (already running) remote secondmate, as fm-spawn would write.
cat > "$HUB/state/$SMID.meta" <<EOF
window=$TARGET
worktree=$BOX
project=$BOX
harness=claude
kind=secondmate
mode=secondmate
yolo=off
home=$BOX
projects=roybot
machine=m3box
host=localhost
remote_home=$BOX
EOF

MARK="LIVE_WORK_$$"

# --- IN: route a marked work line to the box over the wire ------------------
# FM_TMUX_SSH=<wrapper> makes fm-send transport every tmux call through the
# private-server-pinned ssh wrapper (fm_transport_arm honors an explicit override
# verbatim). fm-send marks the line from-firstmate because the meta is a
# secondmate, so this is a faithful marked-work-line-in.
note "routing a marked work line IN with fm-send ..."
FM_TMUX_SSH="$WRAP" FM_HOME="$HUB" FM_STATE_OVERRIDE="$HUB/state" \
  FM_DATA_OVERRIDE="$HUB/data" FM_MACHINES_BIN="$MACHINES" \
  FM_SEND_SETTLE=0 \
  "$SEND" "fm-$SMID" "$MARK" >/dev/null 2>&1 \
  || die "fm-send to the remote box failed"

# Wait (bounded) for the box pane to record the line it received.
got_in=
for _ in $(seq 1 50); do
  if [ -f "$BOX/inbox.log" ] && grep -q "$MARK" "$BOX/inbox.log" 2>/dev/null; then
    got_in=1; break
  fi
  sleep 0.1
done
[ -n "$got_in" ] || die "the box pane never received the work line (inbox.log missing '$MARK')"
grep -q '\[fm-from-firstmate\]' "$BOX/inbox.log" \
  || die "the received line was not marked from-firstmate"
note "  ok: the box received the marked work line"

# --- read-side: fm-peek the box pane over the wire (non-fatal extra check) ---
if peeked=$(FM_TMUX_SSH="$WRAP" FM_HOME="$HUB" FM_STATE_OVERRIDE="$HUB/state" \
              FM_DATA_OVERRIDE="$HUB/data" FM_MACHINES_BIN="$MACHINES" \
              "$PEEK" "fm-$SMID" 20 2>/dev/null); then
  note "  ok: fm-peek read the box pane over the wire (${#peeked} bytes)"
else
  note "  note: fm-peek over the wire returned non-zero (non-fatal)"
fi

# --- BACK: carry the box's status into the hub's local state ----------------
# fm-status-pull resolves the box from the meta machine= + registry, runs a remote
# `cat` over ssh (no tmux), and mirrors the box status into the hub-local file.
note "carrying the box status BACK with fm-status-pull ..."
FM_HOME="$HUB" FM_STATE_OVERRIDE="$HUB/state" FM_DATA_OVERRIDE="$HUB/data" \
  FM_MACHINES_BIN="$MACHINES" \
  "$PULL" "$SMID" >/dev/null 2>&1 \
  || die "fm-status-pull failed"

HUB_STATUS="$HUB/state/$SMID.status"
[ -f "$HUB_STATUS" ] || die "no status was carried back into the hub-local state file"
grep -q 'done: box received a work line' "$HUB_STATUS" \
  || die "the box's status line was not mirrored into the hub-local state file"
note "  ok: the box status was carried back into the hub-local state file"

note ""
note "PASS: live M3 round-trip — marked work line IN over ssh→private tmux, status carried BACK."
