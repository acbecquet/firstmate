#!/usr/bin/env bash
# Behavior tests for fm-home-seed's propagation of the crewmate model pin
# (config/crew-model) into a newly seeded secondmate home.
#
# config/crew-model is a LOCAL, gitignored pin that fm-spawn honors to launch
# ship/scout crewmates on a chosen Claude model. A secondmate is a firstmate in
# its own home, seeded from a fresh clone with an empty config/, so without this
# propagation a secondmate's crewmates would fall back to the user default and
# silently escape the captain's fleet-wide model rule. Seeding therefore copies a
# non-empty pin from the seeding firstmate into the new home. These cases pin the
# behavior down:
#
#   (a) source present     -> copied VERBATIM (byte-for-byte) into the new home.
#   (b) source absent       -> destination absent (today's behavior, unchanged).
#   (c) source whitespace   -> trimmed to empty, so destination stays absent.
#
# config/crew-harness is deliberately NOT copied (it stays per-home by its own
# convention); only crew-model, a fleet-wide captain model rule, travels.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-seed-crew-model)
fm_git_identity fmtest fmtest@example.invalid

# Build a seeding firstmate home under <home> with one direct-PR project (alpha)
# ready to seed into a secondmate. Direct-PR keeps the seed off the no-mistakes
# init path, so these tests exercise only the crew-model copy.
setup_seed_home() {
  local home=$1
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$home/remotes/alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
}

# Seed <id> from <home> into <subhome> with a filled charter. Echoes fm-home-seed
# stdout; returns its exit code.
run_seed() {
  local home=$1 subhome=$2 id=$3
  FM_HOME="$home" FM_SECONDMATE_CHARTER='feature work for alpha' \
    FM_SECONDMATE_SCOPE='feature work for alpha' \
    "$ROOT/bin/fm-home-seed.sh" "$id" "$subhome" alpha
}

test_present_crew_model_copied_verbatim() {
  local home subhome out rc=0
  home="$TMP_ROOT/present-home"
  subhome="$TMP_ROOT/present-subhome"
  setup_seed_home "$home"
  mkdir -p "$home/config"
  # A distinctive value WITH a trailing newline: a verbatim cp preserves it, while
  # a trimmed-value write would drop it, so cmp below actually proves "verbatim".
  printf 'claude-opus-4-8\n' > "$home/config/crew-model"

  out=$(run_seed "$home" "$subhome" design) || rc=$?
  expect_code 0 "$rc" "seed should succeed with a crew-model pin present"
  printf '%s\n' "$out" | grep -F "home=" >/dev/null || fail "seed did not report the seeded home"
  assert_present "$subhome/config/crew-model" "seed did not copy crew-model into the secondmate home"
  cmp -s "$home/config/crew-model" "$subhome/config/crew-model" \
    || fail "seed did not copy crew-model verbatim (byte-for-byte) into the secondmate home"
  [ "$(cat "$subhome/config/crew-model")" = "claude-opus-4-8" ] \
    || fail "copied crew-model has unexpected content"
  # Sanity: the rest of the seed still happened (charter copied, home marked).
  assert_present "$subhome/data/charter.md" "seed did not copy the charter"
  pass "fm-home-seed copies a non-empty config/crew-model pin verbatim into the new home"
}

test_absent_crew_model_destination_absent() {
  local home subhome out rc=0
  home="$TMP_ROOT/absent-home"
  subhome="$TMP_ROOT/absent-subhome"
  setup_seed_home "$home"   # no config/crew-model at all

  out=$(run_seed "$home" "$subhome" design) || rc=$?
  expect_code 0 "$rc" "seed should succeed with no crew-model pin"
  printf '%s\n' "$out" | grep -F "home=" >/dev/null || fail "seed did not report the seeded home"
  assert_absent "$subhome/config/crew-model" \
    "seed created a crew-model file when the seeding firstmate had none"
  # Absent-pin behavior is otherwise unchanged: the home is still fully seeded.
  assert_present "$subhome/data/charter.md" "seed did not copy the charter"
  assert_present "$subhome/.fm-secondmate-home" "seed did not mark the secondmate home"
  pass "fm-home-seed copies nothing when the seeding firstmate has no crew-model pin"
}

test_whitespace_crew_model_destination_absent() {
  local home subhome out rc=0
  home="$TMP_ROOT/whitespace-home"
  subhome="$TMP_ROOT/whitespace-subhome"
  setup_seed_home "$home"
  mkdir -p "$home/config"
  printf '   \n\t \n' > "$home/config/crew-model"   # whitespace only

  out=$(run_seed "$home" "$subhome" design) || rc=$?
  expect_code 0 "$rc" "seed should succeed with a whitespace-only crew-model file"
  printf '%s\n' "$out" | grep -F "home=" >/dev/null || fail "seed did not report the seeded home"
  assert_absent "$subhome/config/crew-model" \
    "seed copied a whitespace-only crew-model, which trims to empty and must be skipped"
  pass "fm-home-seed treats a whitespace-only crew-model as empty and copies nothing"
}

test_present_crew_model_copied_verbatim
test_absent_crew_model_destination_absent
test_whitespace_crew_model_destination_absent
