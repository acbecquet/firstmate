#!/usr/bin/env bash
# Behavior tests for the multi-machine M1 additive foundation:
#   - bin/fm-machines.sh: the machine-registry parser (list/get/fields/validate).
#   - bin/fm-project-mode.sh: the optional @<machine> tag on projects.md lines,
#     proving the default "<mode> <yolo>" output is unchanged and the new
#     `machine` subcommand resolves the tag.
#   - data/secondmates.md line form: proving the optional `machine:` field placed
#     after `added` is parsed unchanged by fm-spawn.sh's EXISTING secondmate
#     regexes (those patterns are grepped verbatim out of bin/fm-spawn.sh so this
#     test breaks loudly if that parser ever changes shape).
#
# Each case builds an isolated FM_HOME with its own data/ so nothing touches the
# captain's real fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MACHINES="$ROOT/bin/fm-machines.sh"
PROJMODE="$ROOT/bin/fm-project-mode.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

# Build a fresh isolated home with the given data files and echo its path.
# Usage: make_home <machines-content> <projects-content>
make_home() {
  local home data
  home=$(fm_test_tmproot fm-machines)
  data="$home/data"
  mkdir -p "$data"
  printf '%s\n' "$1" > "$data/machines.md"
  printf '%s\n' "$2" > "$data/projects.md"
  printf '%s\n' "$home"
}

# Run a bin script with ambient firstmate overrides cleared and FM_HOME pinned to
# the isolated home, so the parser reads only our fixture data.
run_in_home() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    "$@"
}

MACHINES_FIXTURE='# Machine registry

- cabin-desktop - cabin Windows box, WSL2 (host: cabin-desktop.tailnet.ts.net; transport: tailscale-ssh; reachability: online; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: online; last-seen 2026-06-29)
- desktop-bgiv1ph - Charlie'"'"'s Workstation, WSL2 (host: desktop-bgiv1ph.tailnet.ts.net; transport: tailscale-ssh; reachability: intermittent; fm-home: /home/cap/firstmate; harness: claude; tmux-session: firstmate; auth: tailnet-acl; status: offline; last-seen 2026-06-29)
<!-- - example-box - a commented-out seed line that must be ignored (host: nope) -->'

# ---------------------------------------------------------------------------
# fm-machines.sh list
# ---------------------------------------------------------------------------
test_list_ids() {
  local home out
  home=$(make_home "$MACHINES_FIXTURE" "")
  out=$(run_in_home "$home" "$MACHINES" list)
  assert_contains "$out" "cabin-desktop" "list should include cabin-desktop"
  assert_contains "$out" "desktop-bgiv1ph" "list should include desktop-bgiv1ph"
  assert_not_contains "$out" "example-box" "list must ignore commented seed lines"
  assert_not_contains "$out" "registry" "list must ignore the markdown header"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ] || fail "list should print exactly 2 ids"
  pass "list prints active machine ids and ignores comments/header"
}

# ---------------------------------------------------------------------------
# fm-machines.sh get
# ---------------------------------------------------------------------------
test_get_fields() {
  local home
  home=$(make_home "$MACHINES_FIXTURE" "")
  [ "$(run_in_home "$home" "$MACHINES" get cabin-desktop host)" = "cabin-desktop.tailnet.ts.net" ] \
    || fail "get host wrong"
  [ "$(run_in_home "$home" "$MACHINES" get cabin-desktop transport)" = "tailscale-ssh" ] \
    || fail "get transport wrong"
  [ "$(run_in_home "$home" "$MACHINES" get cabin-desktop fm-home)" = "/home/cap/firstmate" ] \
    || fail "get fm-home wrong (hyphenated key)"
  [ "$(run_in_home "$home" "$MACHINES" get cabin-desktop tmux-session)" = "firstmate" ] \
    || fail "get tmux-session wrong (hyphenated key)"
  [ "$(run_in_home "$home" "$MACHINES" get cabin-desktop status)" = "online" ] \
    || fail "get status wrong"
  [ "$(run_in_home "$home" "$MACHINES" get cabin-desktop last-seen)" = "2026-06-29" ] \
    || fail "get last-seen wrong (space-separated form)"
  [ "$(run_in_home "$home" "$MACHINES" get cabin-desktop auth)" = "tailnet-acl" ] \
    || fail "get auth (reference) wrong"
  [ "$(run_in_home "$home" "$MACHINES" get cabin-desktop desc)" = "cabin Windows box, WSL2" ] \
    || fail "get desc wrong"
  pass "get resolves every field including hyphenated keys and last-seen"
}

test_get_unknown_machine_fails() {
  local home rc
  home=$(make_home "$MACHINES_FIXTURE" "")
  run_in_home "$home" "$MACHINES" get no-such-box host >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "get of unknown machine"
  pass "get of unknown machine exits non-zero"
}

test_get_unknown_field_fails() {
  local home rc
  home=$(make_home "$MACHINES_FIXTURE" "")
  run_in_home "$home" "$MACHINES" get cabin-desktop nonesuch >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "get of unknown field"
  pass "get of unknown field exits non-zero"
}

# ---------------------------------------------------------------------------
# fm-machines.sh fields
# ---------------------------------------------------------------------------
test_fields_dump() {
  local home out
  home=$(make_home "$MACHINES_FIXTURE" "")
  out=$(run_in_home "$home" "$MACHINES" fields desktop-bgiv1ph)
  assert_contains "$out" "host=desktop-bgiv1ph.tailnet.ts.net" "fields should include host"
  assert_contains "$out" "status=offline" "fields should include status"
  assert_contains "$out" "last-seen=2026-06-29" "fields should include last-seen"
  pass "fields dumps key=value pairs"
}

# ---------------------------------------------------------------------------
# fm-machines.sh validate
# ---------------------------------------------------------------------------
test_validate() {
  local home rc
  home=$(make_home "$MACHINES_FIXTURE" "")
  run_in_home "$home" "$MACHINES" validate cabin-desktop || fail "validate of present id should pass"

  run_in_home "$home" "$MACHINES" validate not-here >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "validate of absent id"

  run_in_home "$home" "$MACHINES" validate 'Bad/Id' >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "validate of malformed id"
  pass "validate passes present ids, rejects absent and malformed"
}

# ---------------------------------------------------------------------------
# fm-machines.sh missing registry
# ---------------------------------------------------------------------------
test_missing_registry() {
  local home out rc
  home=$(fm_test_tmproot fm-machines-empty)
  mkdir -p "$home/data"   # no machines.md
  out=$(run_in_home "$home" "$MACHINES" list 2>/dev/null)
  [ -z "$out" ] || fail "list with no registry should print nothing"
  run_in_home "$home" "$MACHINES" get cabin-desktop host >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "get with no registry"
  pass "missing registry: list empty/exit-0, get exits non-zero"
}

# ---------------------------------------------------------------------------
# fm-project-mode.sh: @machine tag is additive and backward compatible
# ---------------------------------------------------------------------------
test_projmode_backward_compatible() {
  local home projects
  projects='# Fleet registry

- legacy - no brackets at all (added 2026-06-01)
- gated [no-mistakes] - explicit gate (added 2026-06-02)
- fast [direct-PR +yolo] - yolo direct pr (added 2026-06-03)'
  home=$(make_home "" "$projects")
  [ "$(run_in_home "$home" "$PROJMODE" legacy)" = "no-mistakes off" ] \
    || fail "legacy line should resolve no-mistakes off"
  [ "$(run_in_home "$home" "$PROJMODE" gated)" = "no-mistakes off" ] \
    || fail "gated line should resolve no-mistakes off"
  [ "$(run_in_home "$home" "$PROJMODE" fast)" = "direct-PR on" ] \
    || fail "fast line should resolve direct-PR on"
  # machine subcommand defaults to hub when no tag present
  [ "$(run_in_home "$home" "$PROJMODE" machine fast)" = "hub" ] \
    || fail "absent @machine should default to hub"
  pass "projects.md without @machine resolves exactly as before; machine defaults to hub"
}

test_projmode_machine_tag() {
  local home projects
  # @machine before AND after the [mode] bracket must both resolve mode+machine.
  projects='# Fleet registry

- roybot @cabin-desktop [direct-PR] - robot controller (added 2026-06-29)
- ermods [no-mistakes +yolo] @desktop-bgiv1ph - firmware (added 2026-06-29)
- hubproj @hub [local-only] - stays local (added 2026-06-29)'
  home=$(make_home "" "$projects")

  [ "$(run_in_home "$home" "$PROJMODE" roybot)" = "direct-PR off" ] \
    || fail "roybot mode/yolo wrong with @machine before bracket"
  [ "$(run_in_home "$home" "$PROJMODE" machine roybot)" = "cabin-desktop" ] \
    || fail "roybot @machine not resolved"

  [ "$(run_in_home "$home" "$PROJMODE" ermods)" = "no-mistakes on" ] \
    || fail "ermods mode/yolo wrong with @machine after bracket"
  [ "$(run_in_home "$home" "$PROJMODE" machine ermods)" = "desktop-bgiv1ph" ] \
    || fail "ermods @machine not resolved (after bracket)"

  [ "$(run_in_home "$home" "$PROJMODE" machine hubproj)" = "hub" ] \
    || fail "explicit @hub should resolve hub"
  [ "$(run_in_home "$home" "$PROJMODE" hubproj)" = "local-only off" ] \
    || fail "hubproj mode wrong"
  pass "@machine tag resolves in either order without disturbing mode/yolo"
}

# ---------------------------------------------------------------------------
# data/secondmates.md: optional machine: field is parsed unchanged by the
# EXISTING fm-spawn.sh secondmate regexes (placed after `added`).
# ---------------------------------------------------------------------------
test_secondmate_machine_field_spawn_compatible() {
  # Pull the two sed scripts verbatim out of fm-spawn.sh so this test is bound to
  # the real parser; if fm-spawn's secondmate parsing ever changes shape, the
  # grep assertions below fail loudly rather than silently testing a stale copy.
  local home_pat proj_pat
  home_pat='s/^[^(]*(home: \([^;)]*\);.*/\1/p'
  proj_pat='s/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p'
  grep -qF "$home_pat" "$SPAWN" \
    || fail "fm-spawn.sh home regex changed; update the secondmates machine-field contract test"
  grep -qF "$proj_pat" "$SPAWN" \
    || fail "fm-spawn.sh projects regex changed; update the secondmates machine-field contract test"

  # The documented line form: machine: comes AFTER `added` (the only placement the
  # existing projects regex tolerates untouched).
  local line home_val proj_val
  line='- er2-mods - ER2 firmware mods (home: /home/cap/firstmate; scope: ER2 embedded work; projects: er2-mods, shared-lib; added 2026-06-29; machine: cabin-desktop)'
  home_val=$(printf '%s\n' "$line" | sed -n "$home_pat")
  proj_val=$(printf '%s\n' "$line" | sed -n "$proj_pat")
  [ "$home_val" = "/home/cap/firstmate" ] \
    || fail "fm-spawn home parser broke on a machine-bearing secondmate line (got: '$home_val')"
  [ "$proj_val" = "er2-mods, shared-lib" ] \
    || fail "fm-spawn projects parser broke on a machine-bearing secondmate line (got: '$proj_val')"
  pass "secondmates.md machine: (after added) is parsed unchanged by fm-spawn's existing regexes"
}

test_list_ids
test_get_fields
test_get_unknown_machine_fails
test_get_unknown_field_fails
test_fields_dump
test_validate
test_missing_registry
test_projmode_backward_compatible
test_projmode_machine_tag
test_secondmate_machine_field_spawn_compatible

echo "# all fm-machines / multi-machine M1 tests passed"
