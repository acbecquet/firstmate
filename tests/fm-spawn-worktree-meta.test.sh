#!/usr/bin/env bash
# Regression tests for fm-spawn's worktree resolution after `treehouse get`:
# the meta worktree= value and the harness turn-end hook placement.
#
# Observed on real spawns (ceochat-callmode-f5 / ceochat-sms, claude harness,
# 2026-07): during window startup the pane's cwd transiently reads the tmux
# SERVER's own cwd - for firstmate's session, the firstmate PRIMARY checkout -
# before treehouse enters the worktree. That transient is a genuine git
# toplevel distinct from the project's primary checkout, so the old settle
# loop latched it and the isolation guard (which only compared against the
# project) let it through. Result: meta recorded worktree=<firstmate primary>
# (pointing fm-teardown's landed-work check at the wrong repo) and the claude
# Stop hook landed in the primary's .claude/settings.local.json, waking
# firstmate on its own turn ends in a self-wake loop.
#
# The fix pins worktree membership: only a linked worktree of the PROJECT
# clone (same git common dir as PROJ_ABS) may be latched, so a foreign-repo
# transient is skipped and both the meta value and the hook stay in the
# isolated worktree. These cases drive a full fake-tmux ship spawn and assert
# (a) meta worktree= equals the isolated worktree path, and (b) nothing is
# written under the primary checkout's .claude/ (or its shared git exclude).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-meta)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# A fake tmux that drives the post-`treehouse get` pane cwd the spawn loop
# polls (same shape as the fm-tangle-guard suite's; behavior-specific mocks
# live with the suite that owns them). FM_FAKE_PANE_SEQ is a '|'-separated
# sequence of paths returned on successive pane_current_path reads (clamping
# to the last entry); FM_FAKE_PANE_COUNTER names a per-call counter file.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    IFS='|' read -ra seq <<<"${FM_FAKE_PANE_SEQ:-}"
    c="${FM_FAKE_PANE_COUNTER:-/dev/null}"
    n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1))
    [ "$c" != /dev/null ] && echo "$n" > "$c"
    idx=$((n - 1)); last=$(( ${#seq[@]} - 1 ))
    [ "$idx" -gt "$last" ] && idx=$last
    printf '%s\n' "${seq[$idx]:-}"
    exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# run_spawn <home> <id> <proj> <pane-seq> <fakebin> <harness>: <pane-seq> is
# the '|'-separated pane-cwd sequence. A fresh per-id counter file makes each
# call's sequence start from the top.
run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 harness=$6 counter
  counter="$TMP_ROOT/.panecount-$id"; rm -f "$counter"
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_SEQ="$pane" FM_FAKE_PANE_COUNTER="$counter" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "$harness" 2>&1
}

# The observed failure, end to end: the pane first reports a foreign git
# toplevel (the firstmate primary checkout, modeled by a separate repo), then
# treehouse settles into the project's isolated worktree. The spawn must skip
# the transient, record the worktree in meta, and keep every hook write inside
# the worktree.
test_transient_primary_not_latched() {
  local home proj wt primary fakebin out status meta
  home="$TMP_ROOT/latch-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/latch-proj")
  primary=$(make_repo "$TMP_ROOT/latch-primary")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/latch-fake")
  wt="$TMP_ROOT/latch-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn "$home" meta-transient-h8 "$proj" "$primary|$wt" "$fakebin" claude); status=$?
  expect_code 0 "$status" "spawn should skip the foreign-repo transient and succeed"
  assert_contains "$out" "spawned meta-transient-h8" "spawn did not report success"
  assert_contains "$out" "worktree=$wt" "spawn output latched the transient instead of the worktree"

  # (a) meta worktree= is the isolated worktree, never the foreign transient.
  meta="$home/state/meta-transient-h8.meta"
  assert_present "$meta" "spawn did not record meta"
  assert_grep "worktree=$wt" "$meta" "meta worktree= is not the isolated worktree path"
  assert_no_grep "worktree=$primary" "$meta" "meta worktree= latched the primary-checkout transient"

  # (b) the claude Stop hook lives in the WORKTREE; the primary checkout gets
  # no .claude/ and no shared-exclude write at all.
  assert_present "$wt/.claude/settings.local.json" "claude Stop hook was not installed in the worktree"
  assert_grep "$home/state/meta-transient-h8.turn-ended" "$wt/.claude/settings.local.json" \
    "worktree Stop hook does not touch the task's turn-ended file"
  assert_absent "$primary/.claude" "a .claude/ dir was written under the primary checkout"
  if [ -f "$primary/.git/info/exclude" ]; then
    assert_no_grep ".claude/settings.local.json" "$primary/.git/info/exclude" \
      "the hook exclude was appended to the primary checkout's shared git exclude"
  fi
  assert_grep ".claude/settings.local.json" "$proj/.git/info/exclude" \
    "the hook exclude did not land in the project's shared git exclude"
  pass "fm-spawn: foreign-repo pane transient is never latched; meta and Stop hook stay in the worktree"
}

# Membership is the project's git common dir, not path shape: a transient that
# IS a worktree root of some OTHER repo (exactly what the firstmate primary
# looks like) must be rejected even when it appears repeatedly, while the
# project's own linked worktree is accepted as soon as it shows up.
test_foreign_worktree_root_rejected_repeatedly() {
  local home proj wt primary fakebin out status
  home="$TMP_ROOT/repeat-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/repeat-proj")
  primary=$(make_repo "$TMP_ROOT/repeat-primary")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/repeat-fake")
  wt="$TMP_ROOT/repeat-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn "$home" meta-repeat-j9 "$proj" "$primary|$primary|$primary|$wt" "$fakebin" claude); status=$?
  expect_code 0 "$status" "spawn should keep polling past a persistent foreign toplevel"
  assert_contains "$out" "worktree=$wt" "spawn latched the persistent foreign toplevel"
  assert_absent "$primary/.claude" "a .claude/ dir was written under the primary checkout"
  pass "fm-spawn: a persistent foreign worktree root never wins over the project's own worktree"
}

test_transient_primary_not_latched
test_foreign_worktree_root_rejected_repeatedly
