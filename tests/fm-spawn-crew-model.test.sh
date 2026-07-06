#!/usr/bin/env bash
# Behavior tests for fm-spawn's per-kind crewmate model pin (config/crew-model).
#
# config/crew-model is a LOCAL, gitignored sibling of config/crew-harness: a single
# value on one line, absent/empty = no override. When it holds a non-empty value,
# a CLAUDE ship/scout crewmate is launched with `--model <value>` so this fleet can
# run crewmates on a different Claude model than firstmate/secondmates (which inherit
# the user default). The scope is deliberately narrow, and these cases pin it down:
#
#   (a) file absent      -> the claude launch command is byte-for-byte unchanged.
#   (b) file = opus       -> claude ship AND scout launches carry `--model opus`.
#   (c) secondmate spawn  -> never carries --model, even with the file set (a
#                            secondmate is a firstmate and follows the user default).
#   (d) whitespace-only   -> trimmed to empty, so no flag is added.
#   (e) non-claude harness -> ignored (claude harness only; others out of scope).
#
# Each case drives a full fake-tmux spawn to completion and asserts on the exact
# launch command fm-spawn sends to the crewmate pane (captured via `send-keys -l`),
# so absent-file behavior is provably identical to today.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-crew-model)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# Add a detached linked worktree of <proj> at $TMP_ROOT/<name>; echoes its path.
new_worktree() {
  local proj=$1 name=$2 wt
  wt="$TMP_ROOT/$name"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  printf '%s\n' "$wt"
}

# The launch line fm-spawn typed for <id> is captured to this per-id log by the
# fake tmux's send-keys case below.
spawn_log() { printf '%s/launch-%s.log\n' "$TMP_ROOT" "$1"; }

# A fake tmux + treehouse. The pane_current_path sequence (FM_FAKE_PANE_SEQ, a '|'-
# separated list clamped to its last entry, counted per call via FM_FAKE_PANE_COUNTER)
# drives the post-`treehouse get` settle loop; the send-keys case records the literal
# launch line (the argument following `-l`) to FM_FAKE_LAUNCH_LOG so a test can assert
# on the exact command. Modeled on the fm-spawn-worktree-meta suite's fake tmux.
make_launch_fakebin() {
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
  has-session|new-session|new-window) exit 0 ;;
  send-keys)
    # Log only the literal launch line: the argument that follows `-l`. The
    # `treehouse get` and bare `Enter` sends carry no `-l`, so they are ignored.
    prev=
    for arg in "$@"; do
      [ "$prev" = "-l" ] && printf '%s\n' "$arg" >> "${FM_FAKE_LAUNCH_LOG:-/dev/null}"
      prev=$arg
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# run_ship_spawn <home> <id> <proj> <wt> <fakebin> <harness> [flag]: drive a
# ship (or, with flag=--scout, scout) spawn; returns fm-spawn's exit code and
# leaves the captured launch line in $(spawn_log <id>).
run_ship_spawn() {
  local home=$1 id=$2 proj=$3 wt=$4 fakebin=$5 harness=$6 flag=${7:-}
  local counter="$TMP_ROOT/.pc-$id" log rc=0
  log=$(spawn_log "$id")
  rm -f "$counter" "$log"
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  local args=("$id" "$proj" "$harness")
  [ -n "$flag" ] && args+=("$flag")
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_SEQ="$wt" FM_FAKE_PANE_COUNTER="$counter" \
    FM_FAKE_LAUNCH_LOG="$log" TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "${args[@]}" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# claude_launch <brief> [model]: the exact command fm-spawn builds for a claude
# spawn - today's template with __BRIEF__ substituted (the crewmate pane runs the
# $(cat ...) itself, so it stays literal here), plus ` --model <model>` when a model
# is given. The no-model form is the byte-for-byte baseline the no-pin cases assert.
claude_launch() {
  local brief=$1 model=${2:-} flag=''
  [ -n "$model" ] && flag=" --model $model"
  printf '%s' "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions${flag} \"\$(cat '$brief')\""
}

test_absent_file_unchanged() {
  local home proj wt fakebin id=cm-absent-a1 rc launch expected
  home="$TMP_ROOT/a-home"; mkdir -p "$home/data"   # no config/ at all
  proj=$(make_repo "$TMP_ROOT/a-proj")
  wt=$(new_worktree "$proj" a-wt)
  fakebin=$(make_launch_fakebin "$TMP_ROOT/a-fake")

  run_ship_spawn "$home" "$id" "$proj" "$wt" "$fakebin" claude; rc=$?
  expect_code 0 "$rc" "claude ship spawn should succeed with no crew-model file"
  launch=$(cat "$(spawn_log "$id")")
  expected=$(claude_launch "$home/data/$id/brief.md")
  [ "$launch" = "$expected" ] || fail \
    "absent-file launch is not byte-for-byte the unchanged template"$'\n'"got:      $launch"$'\n'"expected: $expected"
  assert_not_contains "$launch" "--model" "absent crew-model must not add --model"
  pass "fm-spawn: no config/crew-model leaves the claude launch byte-for-byte unchanged"
}

test_present_opus_ship_and_scout() {
  local home proj wt wt2 fakebin rc launch expected
  home="$TMP_ROOT/b-home"; mkdir -p "$home/data" "$home/config"
  printf 'opus\n' > "$home/config/crew-model"
  proj=$(make_repo "$TMP_ROOT/b-proj")
  fakebin=$(make_launch_fakebin "$TMP_ROOT/b-fake")

  # ship
  wt=$(new_worktree "$proj" b-wt-ship)
  run_ship_spawn "$home" cm-opus-ship-b1 "$proj" "$wt" "$fakebin" claude; rc=$?
  expect_code 0 "$rc" "claude ship spawn should succeed with crew-model=opus"
  launch=$(cat "$(spawn_log cm-opus-ship-b1)")
  expected=$(claude_launch "$home/data/cm-opus-ship-b1/brief.md" opus)
  [ "$launch" = "$expected" ] || fail \
    "opus ship launch is not the expected --model command"$'\n'"got:      $launch"$'\n'"expected: $expected"
  assert_contains "$launch" "--model opus" "ship spawn must honor crew-model=opus"

  # scout (same home/file), a different worktree of the same project
  wt2=$(new_worktree "$proj" b-wt-scout)
  run_ship_spawn "$home" cm-opus-scout-b2 "$proj" "$wt2" "$fakebin" claude --scout; rc=$?
  expect_code 0 "$rc" "claude scout spawn should succeed with crew-model=opus"
  launch=$(cat "$(spawn_log cm-opus-scout-b2)")
  assert_contains "$launch" "--model opus" "scout spawn must honor crew-model=opus"
  pass "fm-spawn: config/crew-model pins --model for claude ship and scout spawns"
}

test_secondmate_ignores_file() {
  local home subhome id=cm-sub-c1 fakebin rc launch log
  home="$TMP_ROOT/c-home"; mkdir -p "$home/data" "$home/config"
  printf 'opus\n' > "$home/config/crew-model"

  # A minimal seeded secondmate home: marker (matching id), AGENTS.md, bin/, and a
  # filled charter so the spawn reaches the launch.
  subhome="$TMP_ROOT/c-subhome"
  mkdir -p "$subhome/bin" "$subhome/data"
  printf '# Firstmate\n' > "$subhome/AGENTS.md"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'charter\n' > "$subhome/data/charter.md"

  fakebin=$(make_launch_fakebin "$TMP_ROOT/c-fake")
  log=$(spawn_log "$id"); rm -f "$log"
  rc=0
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$log" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --secondmate >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "secondmate spawn should succeed"
  launch=$(cat "$log" 2>/dev/null)
  assert_contains "$launch" "claude --dangerously-skip-permissions" "secondmate should still launch claude"
  assert_not_contains "$launch" "--model" \
    "a secondmate launch must never receive --model, even with config/crew-model set"
  pass "fm-spawn: a secondmate spawn ignores config/crew-model (a secondmate follows the user default)"
}

test_whitespace_only_no_flag() {
  local home proj wt fakebin id=cm-ws-d1 rc launch expected
  home="$TMP_ROOT/d-home"; mkdir -p "$home/data" "$home/config"
  printf '   \n\t \n' > "$home/config/crew-model"   # whitespace only
  proj=$(make_repo "$TMP_ROOT/d-proj")
  wt=$(new_worktree "$proj" d-wt)
  fakebin=$(make_launch_fakebin "$TMP_ROOT/d-fake")

  run_ship_spawn "$home" "$id" "$proj" "$wt" "$fakebin" claude; rc=$?
  expect_code 0 "$rc" "claude ship spawn should succeed with a whitespace-only crew-model file"
  launch=$(cat "$(spawn_log "$id")")
  expected=$(claude_launch "$home/data/$id/brief.md")
  [ "$launch" = "$expected" ] || fail \
    "whitespace-only crew-model perturbed the launch"$'\n'"got:      $launch"$'\n'"expected: $expected"
  assert_not_contains "$launch" "--model" "a whitespace-only crew-model must not add --model"
  pass "fm-spawn: a whitespace-only config/crew-model trims to empty and adds no flag"
}

test_non_claude_harness_ignores_file() {
  local home proj wt fakebin id=cm-codex-e1 rc launch
  home="$TMP_ROOT/e-home"; mkdir -p "$home/data" "$home/config"
  printf 'opus\n' > "$home/config/crew-model"
  proj=$(make_repo "$TMP_ROOT/e-proj")
  wt=$(new_worktree "$proj" e-wt)
  fakebin=$(make_launch_fakebin "$TMP_ROOT/e-fake")

  run_ship_spawn "$home" "$id" "$proj" "$wt" "$fakebin" codex; rc=$?
  expect_code 0 "$rc" "codex ship spawn should succeed"
  launch=$(cat "$(spawn_log "$id")")
  assert_contains "$launch" "codex --dangerously-bypass-approvals-and-sandbox" \
    "the codex launch template should be used"
  assert_not_contains "$launch" "--model" \
    "config/crew-model is claude-only; a codex launch must not receive --model"
  pass "fm-spawn: config/crew-model is claude-only; a non-claude spawn ignores it"
}

test_absent_file_unchanged
test_present_opus_ship_and_scout
test_secondmate_ignores_file
test_whitespace_only_no_flag
test_non_claude_harness_ignores_file
