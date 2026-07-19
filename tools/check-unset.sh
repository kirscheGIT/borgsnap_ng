#!/bin/sh
# check-unset.sh
#
# Enforces the naming/scoping convention documented in CONVENTIONS.md:
# every prefixed variable (pattern: lowercaseTag_name) assigned inside a
# function must have a matching `unset` before the function ends, and
# vice versa (an `unset` with no matching assignment is likely stale/dead
# code left over from a refactor).
#
# This exists because editor snippets can only help while you're typing a
# *new* block through the snippet - they don't catch a variable quietly
# added to an existing function later. This script catches that
# structurally, regardless of which editor (or none) was used.
#
# Usage:
#   tools/check-unset.sh                 # scan the default file set
#   tools/check-unset.sh path/to/file.sh # scan specific file(s)
#   tools/check-unset.sh --ignore-file tools/check-unset-ignore.txt ...
#
# Suppressing a specific finding:
#   Add "# noqa:unset" at the end of the assignment line to exclude that
#   variable from the check entirely (use sparingly, and prefer fixing the
#   actual assignment/unset pairing instead).
#
# Exit status: 0 if no missing `unset`s were found (stale/extra `unset`s
# are reported but don't affect the exit status - they're not incorrect,
# just possibly redundant). Non-zero if any prefixed variable is assigned
# but never unset.
#
# Known limitations (heuristic, not a real shell parser):
#   - Assumes the "tag_name=..." convention from CONVENTIONS.md; variables
#     that don't match that pattern (single words, ALL_CAPS globals,
#     single-letter loop variables) are intentionally not checked.
#   - Assumes each function opens with "funcname(){" on its own line, and
#     tracks nesting via a simple brace count - this works reliably for
#     POSIX sh (which has no {..} control-flow blocks, only function
#     bodies and ${...} parameter expansions, and the latter almost always
#     open and close on the same line).
#   - Only the first "identifier=" token per line is considered an
#     assignment; assignments after a ";" on the same line as other code
#     are not detected.

set -eu

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
IGNORE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ignore-file)
      shift
      IGNORE_FILE="${1:-}"
      ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
  shift
done

if [ $# -gt 0 ]; then
  FILES="$*"
else
  FILES=$(cd "$REPO_ROOT" && find . \
    -path ./test -prune -o \
    -path ./tools -prune -o \
    -path './.git' -prune -o \
    -name '*.sh' -print | sed 's|^\./||')
fi

TOTAL_MISSING=0
TOTAL_STALE=0

for f in $FILES; do
  fpath="$REPO_ROOT/$f"
  [ -f "$fpath" ] || fpath="$f"
  [ -f "$fpath" ] || { echo "Skipping (not found): $f" >&2; continue; }

  out="$(awk -f "$SCRIPT_DIR/check-unset.awk" -v ignorefile="$IGNORE_FILE" -v fname="$f" "$fpath")"
  [ -z "$out" ] && continue
  echo "$out"
  missing_count=$(printf '%s\n' "$out" | grep -c "^MISSING" || true)
  stale_count=$(printf '%s\n' "$out" | grep -c "^STALE" || true)
  TOTAL_MISSING=$((TOTAL_MISSING + missing_count))
  TOTAL_STALE=$((TOTAL_STALE + stale_count))
done

echo "-------------------------------------"
echo "check-unset.sh: $TOTAL_MISSING missing, $TOTAL_STALE stale"

[ "$TOTAL_MISSING" -eq 0 ]
