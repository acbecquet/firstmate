#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, and (optionally) its home machine
# from the data/projects.md registry.
#
#   fm-project-mode.sh <name>          prints "<mode> <yolo>" (the default; two
#                                      words, consumed by `read -r MODE YOLO`)
#   fm-project-mode.sh machine <name>  prints the project's machine id, or "hub"
#                                      when no @machine tag is present
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                       -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)               -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)         -> <mode> on
#   - <name> @<machine> [<mode>] - <desc> (added <date>)    -> <mode> off, machine <machine>
#
# The optional @<machine> tag (multi-machine fleet; AGENTS.md S14) routes hub-side
# intake to the box that owns the project without reaching across the network. It
# may appear before or after the [mode +yolo] bracket; absent or "@hub" means the
# local hub (today's behavior, fully backward compatible). The default invocation
# still prints exactly two words, so existing callers are unaffected.
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> firstmate review -> captain approve -> local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" (and
# machine "hub") and warns to stderr, so a typo never silently drops the gate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"

WANT=mode
if [ "${1:-}" = machine ]; then
  WANT=machine
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [machine] <project-name>}

emit() {
  # $1 mode, $2 yolo, $3 machine
  if [ "$WANT" = machine ]; then echo "$3"; else echo "$1 $2"; fi
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off (machine hub)" >&2
  emit no-mistakes off hub
  exit 0
fi

# awk emits "<mode> <yolo> <machine>" (one line) or nothing if the project is
# absent. It scans the tokens between the name and the " - <desc>" separator,
# recognising an @<machine> tag and a [<mode> +yolo] bracket in either order.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; machine="hub";
    for (i=3; i<=NF; i++) {
      if ($i == "-") break;                 # reached the " - <desc>" separator
      if ($i ~ /^@/) { machine = substr($i, 2); continue }
      if ($i ~ /^\[/) {
        s="";
        for (j=i; j<=NF; j++) { s = s (s==""?"":" ") $j; if ($j ~ /\]$/) { i=j; break } }
        gsub(/^\[|\]$/, "", s);              # strip the surrounding brackets
        k = split(s, a, " ");
        if (a[1] != "" && a[1] != "+yolo") mode = a[1];
        for (m=1; m<=k; m++) if (a[m]=="+yolo") yolo="on";
        continue
      }
    }
    if (machine == "") machine = "hub";
    print mode, yolo, machine; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off (machine hub)" >&2
  emit no-mistakes off hub
  exit 0
fi

mode=$(printf '%s\n' "$parsed" | awk '{print $1}')
yolo=$(printf '%s\n' "$parsed" | awk '{print $2}')
machine=$(printf '%s\n' "$parsed" | awk '{print $3}')
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
[ -n "$machine" ] || machine=hub
emit "$mode" "$yolo" "$machine"
