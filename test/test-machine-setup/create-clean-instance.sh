#!/bin/sh
# create-clean-instance.sh
#
# Creates a Lima instance from a template file, resolves the portable
# __BORGSNAP_REPO_PATH__ placeholder to an actual filesystem path, strips
# the unconditional "location: ~" mount that every Lima template inherits
# from the root templates/default.yaml, symlinks the template into ~/lima
# for convenient reference, then starts the instance.
#
# Background on the "~" mount: Lima's mount lists are combined across the
# whole `base:` chain, not replaced. Every template ultimately chains back
# to templates/default.yaml, which sets an unconditional
#   - location: "~"
# mount with no mountPoint override. Without a mountPoint, Lima mirrors the
# host's absolute path 1:1 into the guest (so on macOS you'd see /Users/<you>
# fully mounted inside the VM) - regardless of which distro/image template
# you build on top of. The only reliable fix is a one-time edit of the
# *resolved* instance config (~/.lima/<name>/lima.yaml), which is generated
# once at `limactl create` and is never re-merged with the base templates on
# subsequent `stop`/`start` cycles.
#
# Repo path resolution (for the __BORGSNAP_REPO_PATH__ placeholder in the
# template's mounts entry), in priority order:
#   1. --repo-path=PATH / -p PATH command line flag
#   2. BORGSNAP_NG_REPO_PATH environment variable
#   3. Auto-detected via `git rev-parse --show-toplevel` from this script's
#      own directory (works if this script stays inside the repo checkout,
#      e.g. at test/test-machine-setup/, regardless of where that checkout
#      lives on disk - this is what makes the templates portable across
#      machines without editing them).
#   4. Fallback guess: two directories above this script.
#   5. If the guessed/detected path doesn't look like the repo (no
#      borgsnap_ng.sh marker file) and the session is interactive, ask.
#      Non-interactive sessions abort with an error instead of guessing.
#
# The template file on disk (git-tracked) is NEVER modified - it keeps the
# __BORGSNAP_REPO_PATH__ placeholder forever, so it stays portable across
# any machine/checkout location. Only a throwaway temp copy, fed to
# `limactl create`, gets the real path substituted in.
#
# Usage:
#   ./create-clean-instance.sh <instance-name> <template.yaml> [--repo-path=PATH]
#   ./create-clean-instance.sh docker-dev docker-debian.yaml
#   BORGSNAP_NG_REPO_PATH=/some/path ./create-clean-instance.sh zfs-dev zfs-debian.yaml
#
# Requirements: lima, yq (brew install lima yq)

set -eu

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
PLACEHOLDER="__BORGSNAP_REPO_PATH__"
MARKER_FILE="borgsnap_ng.sh"

usage() {
  echo "Usage: $0 <instance-name> <template.yaml> [--repo-path=PATH | -p PATH]" >&2
  echo "       BORGSNAP_NG_REPO_PATH env var is also honored." >&2
  exit 1
}

# --- argument parsing -------------------------------------------------
NAME=""
TEMPLATE_ARG=""
REPO_PATH_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-path=*) REPO_PATH_FLAG="${1#--repo-path=}" ;;
    -p) shift; REPO_PATH_FLAG="${1:-}" ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      elif [ -z "$TEMPLATE_ARG" ]; then TEMPLATE_ARG="$1"
      else echo "Unexpected extra argument: $1" >&2; usage
      fi
      ;;
  esac
  shift
done

[ -n "$NAME" ] && [ -n "$TEMPLATE_ARG" ] || usage

command -v limactl >/dev/null 2>&1 || { echo "limactl not found - brew install lima" >&2; exit 1; }
command -v yq      >/dev/null 2>&1 || { echo "yq not found - brew install yq" >&2; exit 1; }

# Resolve the template path: bare filename -> look next to this script first
# (the common case, templates and script living side by side in the repo).
if [ -f "$TEMPLATE_ARG" ]; then
  TEMPLATE_PATH="$(cd -- "$(dirname "$TEMPLATE_ARG")" && pwd -P)/$(basename "$TEMPLATE_ARG")"
elif [ -f "$SCRIPT_DIR/$TEMPLATE_ARG" ]; then
  TEMPLATE_PATH="$SCRIPT_DIR/$TEMPLATE_ARG"
else
  echo "Template file not found: $TEMPLATE_ARG (looked in cwd and $SCRIPT_DIR)" >&2
  exit 1
fi

if limactl list --quiet 2>/dev/null | grep -qx "$NAME"; then
  echo "Instance '$NAME' already exists. Remove it first if you want a clean rebuild:" >&2
  echo "  limactl stop $NAME && limactl delete $NAME" >&2
  exit 1
fi

# --- repo path resolution ----------------------------------------------
looks_like_repo() {
  [ -f "$1/$MARKER_FILE" ]
}

REPO_PATH=""
REPO_PATH_SOURCE=""
REPO_PATH_EXPLICIT=0

if [ -n "$REPO_PATH_FLAG" ]; then
  REPO_PATH="$REPO_PATH_FLAG"
  REPO_PATH_SOURCE="--repo-path flag"
  REPO_PATH_EXPLICIT=1
elif [ -n "${BORGSNAP_NG_REPO_PATH:-}" ]; then
  REPO_PATH="$BORGSNAP_NG_REPO_PATH"
  REPO_PATH_SOURCE="BORGSNAP_NG_REPO_PATH env var"
  REPO_PATH_EXPLICIT=1
elif command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_PATH="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
  REPO_PATH_SOURCE="git rev-parse (auto-detected)"
else
  REPO_PATH="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
  REPO_PATH_SOURCE="relative fallback: \$SCRIPT_DIR/../.. (auto-detected, no git)"
fi

# Explicit overrides (flag/env var) are trusted as-is - the whole point of
# allowing them is to support non-standard layouts, so we don't second-guess
# the user here. Only auto-detected paths get sanity-checked and, if wrong,
# prompted for interactively.
if [ "$REPO_PATH_EXPLICIT" -eq 0 ] && ! looks_like_repo "$REPO_PATH"; then
  echo "Note: '$REPO_PATH' (source: $REPO_PATH_SOURCE) does not contain '$MARKER_FILE'." >&2
  if [ -t 0 ] && [ -t 1 ]; then
    printf 'Enter the borgsnap_ng repo path to mount [%s]: ' "$REPO_PATH" >&2
    read -r INPUT
    [ -n "$INPUT" ] && REPO_PATH="$INPUT"
    if ! looks_like_repo "$REPO_PATH"; then
      echo "Warning: '$REPO_PATH' still has no '$MARKER_FILE' - proceeding anyway, this may be intentional." >&2
    fi
  else
    echo "Non-interactive session: refusing to guess. Pass --repo-path=PATH or set BORGSNAP_NG_REPO_PATH." >&2
    exit 1
  fi
fi

echo "==> Using repo path: $REPO_PATH (source: $REPO_PATH_SOURCE)"

# --- symlink the template into ~/lima for convenient reference ---------
LIMA_DIR="$HOME/lima"
mkdir -p "$LIMA_DIR"
LIMA_SYMLINK="$LIMA_DIR/$(basename "$TEMPLATE_PATH")"
if [ -L "$LIMA_SYMLINK" ] || [ ! -e "$LIMA_SYMLINK" ]; then
  ln -sf "$TEMPLATE_PATH" "$LIMA_SYMLINK"
  echo "==> Symlinked $LIMA_SYMLINK -> $TEMPLATE_PATH"
else
  echo "Note: $LIMA_SYMLINK exists and is not a symlink - leaving it untouched." >&2
fi

# --- substitute the placeholder into a throwaway resolved copy ---------
# The git-tracked template on disk is never modified. sed with '|' as the
# delimiter avoids escaping issues since filesystem paths contain '/'.
RESOLVED_TMP="$(mktemp "${TMPDIR:-/tmp}/borgsnap-lima-XXXXXX.yaml")"
trap 'rm -f "$RESOLVED_TMP"' EXIT INT TERM HUP

if ! grep -q "$PLACEHOLDER" "$TEMPLATE_PATH"; then
  echo "Note: placeholder $PLACEHOLDER not found in $TEMPLATE_PATH - using it as-is." >&2
  cp "$TEMPLATE_PATH" "$RESOLVED_TMP"
else
  sed "s|$PLACEHOLDER|$REPO_PATH|g" "$TEMPLATE_PATH" > "$RESOLVED_TMP"
fi

# --- create, strip the inherited mount, start ---------------------------
LIMA_YAML="$HOME/.lima/$NAME/lima.yaml"

echo "==> Creating instance '$NAME' from $(basename "$TEMPLATE_PATH") (not starting yet)"
limactl create --tty=false --name="$NAME" "$RESOLVED_TMP"

if [ ! -f "$LIMA_YAML" ]; then
  echo "Expected resolved config not found at $LIMA_YAML - aborting without starting." >&2
  exit 1
fi

echo "==> Stripping the inherited 'location: ~' mount from $LIMA_YAML"
BEFORE=$(yq '.mounts | length' "$LIMA_YAML")
yq -i 'del(.mounts[] | select(.location == "~"))' "$LIMA_YAML"
AFTER=$(yq '.mounts | length' "$LIMA_YAML")

if [ "$BEFORE" = "$AFTER" ]; then
  echo "    Note: mount count unchanged ($BEFORE -> $AFTER)."
  echo "    Either there was no bare '~' mount to remove, or it's already clean."
else
  echo "    Removed $((BEFORE - AFTER)) entr(y/ies) ($BEFORE -> $AFTER mounts remain)."
fi

echo "==> Remaining mounts:"
yq '.mounts' "$LIMA_YAML"

echo "==> Starting instance '$NAME'"
limactl start "$NAME"

echo "==> Done. Verify with:"
echo "  limactl shell $NAME ls /Users 2>&1   # should say 'No such file or directory'"
echo "  limactl shell $NAME mount | grep -i borgsnap"
