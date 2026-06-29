# shellcheck shell=bash
# Shared fast-forward machinery for firstmate self-sync.
# Usage: . bin/fm-ff-lib.sh   (after FM_ROOT and FM_HOME are set)
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# clean fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /updatefirstmate (bin/fm-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn.sh on launch, bin/fm-bootstrap.sh
#     on startup) follows the PRIMARY checkout's current default-branch commit:
#     base_mode is that local commit, with NO fetch and no origin dependency.
#
# Every secondmate home is a worktree of this same repo, so it already holds the
# primary's commit in the shared object store; the local-HEAD sync is therefore a
# purely local fast-forward that never touches the network. A tracked-files
# fast-forward never touches the gitignored operational dirs (data/, state/,
# config/, projects/, .no-mistakes/), so a secondmate's backlog, projects, and
# in-flight work are never disturbed. Homes are leased at a detached HEAD on the
# default branch, so the fast-forward advances HEAD only and never moves the
# shared default branch or any other worktree's checkout.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every secondmate follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

VALIDATED_HOME=""
VALIDATION_ERROR=""

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P) || {
        VALIDATION_ERROR="secondmate $name directory cannot be resolved"
        return 1
      }
    elif [ -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name path is not a directory"
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the active firstmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the firstmate repo"
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  VALIDATED_HOME=""
  VALIDATION_ERROR=""
  abs_home=$(resolved_existing_dir "$home") || {
    VALIDATION_ERROR="not a directory"
    return 1
  }
  abs_active_home=$(resolved_existing_dir "$FM_HOME") || {
    VALIDATION_ERROR="active firstmate home is not a directory"
    return 1
  }
  abs_root=$(resolved_existing_dir "$FM_ROOT") || {
    VALIDATION_ERROR="firstmate repo is not a directory"
    return 1
  }
  if [ "$abs_home" = "/" ]; then
    VALIDATION_ERROR="secondmate home cannot be the filesystem root"
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    VALIDATION_ERROR="secondmate home cannot be the active firstmate home"
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    VALIDATION_ERROR="secondmate home cannot be the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the firstmate repo"
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ -L "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="secondmate marker must not be a symlink"
    return 1
  fi
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="not a seeded secondmate home"
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    VALIDATION_ERROR="marked for secondmate ${marker_id:-unknown}, expected $id"
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    VALIDATION_ERROR="not a firstmate home (missing AGENTS.md)"
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    VALIDATION_ERROR="not a firstmate home (missing bin/)"
    return 1
  fi
  VALIDATED_HOME="$abs_home"
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches.
FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md symlinks), its skills, and its tooling (bin/).
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

dirty_status() {
  local dir=$1 ignore_seed_marker=${2:-no}
  if [ "$ignore_seed_marker" = yes ]; then
    git -C "$dir" status --porcelain 2>/dev/null | awk -v marker="?? $SUB_HOME_MARKER" '$0 != marker { print; exit }'
  else
    git -C "$dir" status --porcelain 2>/dev/null | head -1
  fi
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - fetch origin and advance to origin/<default> (the /updatefirstmate
#                  path); requires an origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD secondmate sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are identical in both modes: ff-only (never force/merge/stash); skip a
# dirty, diverged, or wrong-branch target and leave its work untouched.
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  if [ -n "$(dirty_status "$dir" "$ignore_seed_marker")" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  FF_STATUS="updated"
  FF_INSTR="$instr"
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}

# Sweep accumulators. The caller resets both before a sweep and reads
# FF_NUDGE_WINDOWS after.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Validate and fast-forward one secondmate home, accumulating its window into
# FF_NUDGE_WINDOWS when it should be live-converged. Args:
#   id home window base_mode nudge_requires_instr
# A home is nudged only when it ACTUALLY advanced (FF_STATUS=updated) and has a
# live window. With nudge_requires_instr=yes the advance must also have changed
# the instruction surface (FF_INSTR non-empty): an already-current home, or one
# whose only change was non-instruction tracked files, is left undisturbed. The
# firstmate repo itself (FM_ROOT) is never processed as its own secondmate, and
# each resolved home is processed at most once.
process_secondmate() {
  local id=$1 home=$2 window=${3:-} base_mode=$4 nudge_requires_instr=${5:-no} home_real fm_root_real
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  fm_root_real=$(resolve_path "$FM_ROOT")
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$fm_root_real" ] || return 0
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  case " $FF_SEEN_HOMES " in
    *" $home_real "*) return 0 ;;
  esac
  FF_SEEN_HOMES="$FF_SEEN_HOMES $home_real"

  ff_target "$home_real" "secondmate $id" "$base_mode" yes yes
  if [ "$FF_STATUS" = "updated" ] && [ -n "$window" ]; then
    if [ "$nudge_requires_instr" = yes ] && [ -z "$FF_INSTR" ]; then
      return 0
    fi
    FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS $window"
  fi
}

# Sweep this home's LIVE secondmate direct reports - state/<id>.meta files with
# kind=secondmate - fast-forwarding each to base_mode. Passes base_mode and
# nudge_requires_instr through to process_secondmate. Accumulates into
# FF_NUDGE_WINDOWS / FF_SEEN_HOMES, which the caller resets before and reads after.
#
# A meta with a non-hub `machine=` is a REMOTE secondmate whose home lives on
# another box's separate object store; the local fast-forward here (whether the
# local-HEAD or origin base mode) cannot reach or converge it - its home path is
# not even on this filesystem. Those are skipped silently and handled instead by
# the cross-machine update path (sweep_remote_secondmate_metas + ff_remote_secondmate,
# run over the transport). Empty / hub machine= is a local home and processed here.
sweep_live_secondmate_metas() {
  local state=$1 base_mode=$2 nudge_requires_instr=${3:-no} meta id home window machine
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
    machine=$(grep '^machine=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    case "$machine" in
      ''|hub) ;;
      *) continue ;;
    esac
    id=$(basename "$meta" .meta)
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    process_secondmate "$id" "$home" "$window" "$base_mode" "$nudge_requires_instr"
  done
}

# --- cross-machine self-update (M5) ----------------------------------------
#
# A REMOTE secondmate home is a STANDALONE clone of firstmate on another box, with
# its own origin and its own object store. The local fast-forward modes above
# cannot converge it (no shared objects, and the path is not on this host), so a
# machine:-tagged home is advanced by running the SAME guarded, fast-forward-only,
# origin-base update ON THE BOX over the transport: fetch origin, then ff HEAD to
# origin/<default>. The guards mirror ff_target's origin mode exactly - ff-only,
# never force/merge/stash; skip a dirty, diverged, or wrong-branch home untouched -
# but they run box-side. Detached HEAD on the default branch (how a leased home
# legitimately sits) is allowed.

# Single-quote-escape one argument for safe reuse inside the box-side script.
_ff_shquote() {  # <arg>
  local s=$1
  printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
}

# Build the box-side guarded fast-forward script for a remote firstmate home. The
# home path is substituted (shell-quoted) HERE on the hub; everything else stays a
# literal the BOX shell expands, so $default/$base/etc resolve on the box. Prints
# exactly one terminal status line to box stdout: "current", "updated <a>..<b>
# instr=yes|no", or "skipped: <reason>".
remote_ff_command() {  # <remote-home>
  local sq_home
  sq_home=$(_ff_shquote "$1")
  printf 'cd %s 2>/dev/null || { echo "skipped: not a directory"; exit 0; }\n' "$sq_home"
  cat <<'EOF'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "skipped: not a git repo"; exit 0; }
default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
if [ -z "$default" ]; then for b in main master; do if git show-ref --verify --quiet "refs/heads/$b"; then default=$b; break; fi; done; fi
[ -n "$default" ] || { echo "skipped: cannot determine default branch"; exit 0; }
git remote get-url origin >/dev/null 2>&1 || { echo "skipped: no origin remote"; exit 0; }
git fetch origin --prune --quiet 2>/dev/null || { echo "skipped: fetch failed"; exit 0; }
base="origin/$default"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "skipped: $base does not exist"; exit 0; }
cur=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -n "$cur" ] && [ "$cur" != "$default" ]; then echo "skipped: on $cur, expected $default"; exit 0; fi
dirty=$(git status --porcelain 2>/dev/null | grep -v '^?? \.fm-secondmate-home$' | head -1)
[ -z "$dirty" ] || { echo "skipped: dirty working tree"; exit 0; }
local_rev=$(git rev-parse HEAD 2>/dev/null) || { echo "skipped: cannot read HEAD"; exit 0; }
base_rev=$(git rev-parse "$base" 2>/dev/null) || { echo "skipped: cannot read base"; exit 0; }
if [ "$local_rev" = "$base_rev" ]; then echo "current"; exit 0; fi
git merge-base --is-ancestor HEAD "$base" 2>/dev/null || { echo "skipped: diverged from $base"; exit 0; }
instr=no
git diff --quiet HEAD "$base" -- AGENTS.md bin .agents/skills 2>/dev/null || instr=yes
before=$(git rev-parse --short HEAD)
git merge --ff-only "$base" >/dev/null 2>&1 || { echo "skipped: fast-forward failed"; exit 0; }
after=$(git rev-parse --short HEAD)
echo "updated $before..$after instr=$instr"
EOF
}

# Fast-forward one REMOTE secondmate home over the transport. Args:
#   id machine remote-home ssh-prefix [label]
# ssh-prefix is the caller-resolved transport command word list (from
# fm-machines.sh ssh-prefix). Prints one status line and sets the same globals as
# ff_target: FF_STATUS = updated|current|skipped and FF_INSTR (the changed
# instruction surface, set only when an update changed AGENTS.md/bin/skills). An
# unreachable box or a transport failure is a clean skip, never an error.
ff_remote_secondmate() {  # id machine remote-home ssh-prefix [label]
  local id=$1 machine=$2 home=$3 prefix=$4 label=${5:-secondmate $1}
  FF_STATUS="skipped"
  FF_INSTR=""
  if [ -z "$prefix" ]; then
    echo "$label: skipped: no transport prefix for machine \"$machine\""
    return 0
  fi
  if [ -z "$home" ]; then
    echo "$label: skipped: no remote home recorded"
    return 0
  fi
  local cmd out line
  cmd=$(remote_ff_command "$home")
  # Wall-clock bound on the whole box-side run. The ssh-prefix bakes in
  # ConnectTimeout (TCP connect only), so a reachable box whose own `git fetch
  # origin` stalls mid-transfer would otherwise hang this ssh indefinitely; the
  # timeout caps that post-connect stall and turns it into the same clean skip as
  # an unreachable box, honoring this function's "never an error" contract. Bounded
  # but generous since a fetch transfers data. Mirrors fm-machine-ping.sh's guard.
  local ff_timeout=${FM_REMOTE_FF_TIMEOUT:-60}
  # shellcheck disable=SC2086  # prefix is a deliberate ssh command word list.
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout "$ff_timeout" ${prefix} "$cmd" </dev/null 2>/dev/null)
  else
    out=$(${prefix} "$cmd" </dev/null 2>/dev/null)
  fi || {
    echo "$label: skipped: machine \"$machine\" unreachable"
    return 0
  }
  line=$(printf '%s\n' "$out" | grep -E '^(current|updated |skipped:)' | tail -1)
  case "$line" in
    current)
      FF_STATUS="current"
      echo "$label: already current" ;;
    updated\ *)
      FF_STATUS="updated"
      local rest=${line#updated } range instr
      range=${rest%% instr=*}
      instr=${rest##*instr=}
      [ "$instr" = yes ] && FF_INSTR="AGENTS.md, bin, .agents/skills"
      if [ -n "$FF_INSTR" ]; then
        echo "$label: updated $range (instructions changed: $FF_INSTR)"
      else
        echo "$label: updated $range"
      fi ;;
    skipped:*)
      echo "$label: $line" ;;
    *)
      echo "$label: skipped: machine \"$machine\" gave no recognizable response" ;;
  esac
  return 0
}

# Sweep this home's LIVE REMOTE secondmate direct reports - state/<id>.meta with
# kind=secondmate AND a non-hub machine= - fast-forwarding each on its box over the
# transport. Resolves the per-machine ssh-prefix and remote home via the registry
# parser at <machines-bin>. Accumulates an updated remote secondmate's window into
# FF_NUDGE_WINDOWS when its instruction surface changed and a live window exists, so
# the caller can nudge it to re-read - exactly like the local sweep. The hub never
# touches a box home directly; the box self-updates from its own origin.
# Remote ids already processed this sweep, so a registry backstop can skip a remote
# secondmate that already had a live meta. The caller resets it before the sweep.
FF_SEEN_REMOTE=""
sweep_remote_secondmate_metas() {  # <state> <machines-bin>
  local state=$1 machines=$2 meta id machine home window prefix rhome
  [ -d "$state" ] || return 0
  [ -x "$machines" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
    machine=$(grep '^machine=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    case "$machine" in
      ''|hub) continue ;;
    esac
    id=$(basename "$meta" .meta)
    window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    rhome=$(grep '^remote_home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$rhome" ] || rhome=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$rhome" ] || rhome=$("$machines" get "$machine" fm-home 2>/dev/null || true)
    prefix=$("$machines" ssh-prefix "$machine" 2>/dev/null || true)
    ff_remote_secondmate "$id" "$machine" "$rhome" "$prefix" "secondmate $id"
    FF_SEEN_REMOTE="$FF_SEEN_REMOTE $id"
    if [ "$FF_STATUS" = "updated" ] && [ -n "$window" ] && [ -n "$FF_INSTR" ]; then
      FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS $window"
    fi
  done
}
