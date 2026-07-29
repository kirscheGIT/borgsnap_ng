#!/usr/bin/env bash
# install.sh - installer for borgsnap_ng, licensed under GPLv3. See the
# LICENSE file for additional details.
#
# Copies borgsnap_ng into place, and on request creates the "borg" system
# user and sets up its least-privilege sudo/tmpfiles configuration.
# Targets Debian-family systems (Debian, Ubuntu, Proxmox VE) for now.
#
# This script does NOT create any backup configuration (.conf files),
# systemd timers for a specific job, or ZFS delegation for a specific
# dataset - that's the separate, interactive setup script this project
# also ships (or will ship - see ops/README.md). This script only
# deploys the tool itself and prepares the environment to run it.
#
# Usage:
#   sudo ./install.sh [options]
#
# Options:
#   --install-dir=PATH   Where to copy borgsnap_ng (default: /usr/local/bin/borgsnap_ng)
#   --yes                 Assume "yes" to every prompt (non-interactive)
#   --skip-user            Never create the "borg" user, don't ask
#   --skip-privilege        Never install sudoers/tmpfiles, don't ask
#   --skip-systemd          Never install the systemd unit templates, don't ask
#   --dry-run                Print what would happen, change nothing
#   -h, --help                Show this help and exit

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults and flag parsing
# ---------------------------------------------------------------------------
INSTALL_DIR="/usr/local/bin/borgsnap_ng"
ASSUME_YES=0
SKIP_USER=0
SKIP_PRIVILEGE=0
SKIP_SYSTEMD=0
DRY_RUN=0
BORG_USER="borg"

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

for arg in "$@"; do
    case "$arg" in
        --install-dir=*) INSTALL_DIR="${arg#*=}" ;;
        --yes) ASSUME_YES=1 ;;
        --skip-user) SKIP_USER=1 ;;
        --skip-privilege) SKIP_PRIVILEGE=1 ;;
        --skip-systemd) SKIP_SYSTEMD=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $arg" >&2; usage 1 ;;
    esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

run() {
    # Print, and unless --dry-run, actually execute, a command. Used for
    # every state-changing action below so --dry-run gives an honest,
    # complete preview.
    echo "+ $*"
    if [ "$DRY_RUN" -eq 0 ]; then
        "$@"
    fi
}

ask_yes_no() {
    # $1 - prompt text. $2 - default answer ("y" or "n") used both for
    # --yes mode and for a bare Enter keypress.
    local prompt="$1"
    local default="$2"
    if [ "$ASSUME_YES" -eq 1 ]; then
        [ "$default" = "y" ] && return 0 || return 1
    fi
    local hint="y/N"
    [ "$default" = "y" ] && hint="Y/n"
    local reply
    read -r -p "$prompt [$hint] " reply || true
    reply="${reply:-$default}"
    case "$reply" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must be run as root (needed to copy into $INSTALL_DIR," >&2
    echo "  create the '$BORG_USER' user, and install sudoers/systemd/tmpfiles" >&2
    echo "  configuration). Re-run with sudo." >&2
    exit 1
fi

if [ ! -f /etc/debian_version ] && [ ! -f /etc/os-release ] || ! grep -qi "debian\|ubuntu\|proxmox" /etc/os-release 2>/dev/null; then
    echo "install.sh: this doesn't look like a Debian-family system" >&2
    echo "  (Debian, Ubuntu, Proxmox VE). borgsnap_ng itself is portable" >&2
    echo "  POSIX sh, but this installer's package/user-management commands" >&2
    echo "  (useradd, sudoers, tmpfiles.d) are Debian-specific for now." >&2
    if ! ask_yes_no "Continue anyway?" "n"; then
        exit 1
    fi
fi

for cmd in useradd id visudo; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "install.sh: required command '$cmd' not found - aborting" >&2
        exit 1
    }
done

echo "=================================================================="
echo "borgsnap_ng installer"
echo "  Source:      $SCRIPT_DIR"
echo "  Install dir: $INSTALL_DIR"
[ "$DRY_RUN" -eq 1 ] && echo "  Mode:        DRY RUN - nothing will actually change"
echo "=================================================================="
echo ""

# ---------------------------------------------------------------------------
# Step 1: copy application files
# ---------------------------------------------------------------------------
echo "--- Step 1: installing application files to $INSTALL_DIR ---"

APP_FILES="borgsnap_ng.sh mail_wrapper.sh cfg_file_hdlr.sh borgwrapper sample.conf sample_prescript.sh sample_postscript.sh README.md LICENSE"
APP_DIRS="common backup borg filesystem ops"

for required in borgsnap_ng.sh mail_wrapper.sh cfg_file_hdlr.sh common backup borg filesystem; do
    if [ ! -e "$SCRIPT_DIR/$required" ]; then
        echo "install.sh: expected '$required' next to this installer script, but it's missing." >&2
        echo "  Run this script from an unpacked/cloned borgsnap_ng source tree." >&2
        exit 1
    fi
done

run mkdir -p "$INSTALL_DIR"

for f in $APP_FILES; do
    [ -e "$SCRIPT_DIR/$f" ] || continue
    run cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
done
for d in $APP_DIRS; do
    run mkdir -p "$INSTALL_DIR/$d"
    # Trailing slash on the source: copy CONTENTS into the (already
    # created) destination directory, not the directory itself nested
    # one level deeper - matters when re-running this script on top of
    # an existing install.
    run cp -r "$SCRIPT_DIR/$d/." "$INSTALL_DIR/$d/"
done

run chmod 755 "$INSTALL_DIR/borgsnap_ng.sh" "$INSTALL_DIR/mail_wrapper.sh" "$INSTALL_DIR/borgwrapper"
run chmod 644 "$INSTALL_DIR/cfg_file_hdlr.sh" "$INSTALL_DIR/common/"*.sh "$INSTALL_DIR/backup/"*.sh "$INSTALL_DIR/borg/"*.sh "$INSTALL_DIR/filesystem/"*.sh
[ -e "$INSTALL_DIR/sample.conf" ] && run chmod 644 "$INSTALL_DIR/sample.conf"
[ -e "$INSTALL_DIR/ops/least-privilege/setup-zfs-allow.sh" ] && run chmod 755 "$INSTALL_DIR/ops/least-privilege/setup-zfs-allow.sh"

# Ownership: root:root, world-readable. The running user only ever needs
# to READ these scripts, never write them - keeping them root-owned means
# a compromised/misbehaving backup job can't modify its own code.
run chown -R root:root "$INSTALL_DIR"

echo ""
echo "Application files installed."
echo ""

# ---------------------------------------------------------------------------
# Step 2: the "borg" user
# ---------------------------------------------------------------------------
USER_EXISTS=0
if id "$BORG_USER" >/dev/null 2>&1; then
    USER_EXISTS=1
fi

CREATE_USER=0
if [ "$SKIP_USER" -eq 1 ]; then
    echo "--- Step 2: user creation skipped (--skip-user) ---"
elif [ "$USER_EXISTS" -eq 1 ]; then
    echo "--- Step 2: user '$BORG_USER' already exists - not touching it ---"
else
    echo "--- Step 2: the '$BORG_USER' system user ---"
    echo "borgsnap_ng is meant to run as a dedicated, non-root user (least"
    echo "privilege - see ops/least-privilege/README.md for why). This"
    echo "creates a system account named '$BORG_USER' with a real home"
    echo "directory (needed for its own ~/.ssh/config, if you use SSH"
    echo "remote repos) and an interactive shell (useful for manual testing"
    echo "and 'borg' maintenance commands, unlike a typical no-login system"
    echo "account)."
    if ask_yes_no "Create the '$BORG_USER' user now?" "y"; then
        CREATE_USER=1
    else
        echo "Skipping user creation. Whichever user you run borgsnap_ng as"
        echo "will need read access to $INSTALL_DIR and the least-privilege"
        echo "setup in ops/least-privilege/ adjusted for that username."
    fi
fi

if [ "$CREATE_USER" -eq 1 ]; then
    run useradd --system --create-home --home-dir "/home/$BORG_USER" --shell /bin/bash "$BORG_USER"
    USER_EXISTS=1
    echo "User '$BORG_USER' created."
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: least-privilege sudo/tmpfiles setup
# ---------------------------------------------------------------------------
if [ "$SKIP_PRIVILEGE" -eq 1 ]; then
    echo "--- Step 3: least-privilege setup skipped (--skip-privilege) ---"
elif [ "$USER_EXISTS" -eq 0 ]; then
    echo "--- Step 3: least-privilege setup skipped (no '$BORG_USER' user to set it up for) ---"
    echo "See ops/least-privilege/README.md if you set one up yourself later."
else
    echo "--- Step 3: least-privilege sudo/tmpfiles setup for '$BORG_USER' ---"
    echo "This grants '$BORG_USER' passwordless sudo for exactly four"
    echo "commands (mount -t zfs, umount, zpool import, zpool export) -"
    echo "the only operations that can't be delegated via 'zfs allow' on"
    echo "Linux - and sets up /run/borgsnap to be created with the right"
    echo "ownership at boot. It does NOT grant ZFS dataset access itself -"
    echo "that's per-dataset, via ops/least-privilege/setup-zfs-allow.sh,"
    echo "run separately once you know which datasets you're backing up."
    if ask_yes_no "Install sudoers rule and tmpfiles.d config now?" "y"; then
        SUDOERS_SRC="$SCRIPT_DIR/ops/least-privilege/borgsnap-ng.sudoers"
        TMPFILES_SRC="$SCRIPT_DIR/ops/least-privilege/borgsnap-ng.tmpfiles.conf"
        if [ ! -f "$SUDOERS_SRC" ] || [ ! -f "$TMPFILES_SRC" ]; then
            echo "install.sh: expected ops/least-privilege/*.sudoers and *.tmpfiles.conf" >&2
            echo "  next to this installer - skipping this step." >&2
        else
            run cp "$SUDOERS_SRC" /etc/sudoers.d/borgsnap-ng
            run chmod 0440 /etc/sudoers.d/borgsnap-ng
            if [ "$DRY_RUN" -eq 0 ]; then
                if ! visudo -c -f /etc/sudoers.d/borgsnap-ng; then
                    echo "install.sh: the installed sudoers file failed validation - removing it." >&2
                    echo "  This should not happen with the file as shipped; please report this." >&2
                    rm -f /etc/sudoers.d/borgsnap-ng
                    exit 1
                fi
            fi
            run cp "$TMPFILES_SRC" /etc/tmpfiles.d/borgsnap-ng.conf
            run systemd-tmpfiles --create /etc/tmpfiles.d/borgsnap-ng.conf || \
                echo "install.sh: systemd-tmpfiles --create failed - /run/borgsnap will be created on next boot instead, or run that command by hand now." >&2
            echo "Sudoers rule and tmpfiles.d config installed."
        fi
    else
        echo "Skipping. borgsnap_ng will not be able to mount ZFS snapshots or"
        echo "import/export removable-media pools as '$BORG_USER' without this."
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Step 4: systemd unit templates
# ---------------------------------------------------------------------------
if [ "$SKIP_SYSTEMD" -eq 1 ]; then
    echo "--- Step 4: systemd unit installation skipped (--skip-systemd) ---"
elif ! command -v systemctl >/dev/null 2>&1; then
    echo "--- Step 4: systemd unit installation skipped (systemctl not found - use cron instead, see ops/README.md) ---"
else
    echo "--- Step 4: systemd unit templates ---"
    echo "Installs borgsnap-ng@.service and borgsnap-ng@.timer as TEMPLATES"
    echo "(the '@' instance name selects which .conf file to run - see"
    echo "ops/README.md). These are inert until you 'systemctl enable --now"
    echo "borgsnap-ng@<yourconfig>.timer' for a specific config, which the"
    echo "separate config-setup script (or you, by hand) does later."
    if ask_yes_no "Install the systemd unit templates now?" "y"; then
        SERVICE_SRC="$SCRIPT_DIR/ops/systemd/borgsnap-ng@.service"
        TIMER_SRC="$SCRIPT_DIR/ops/systemd/borgsnap-ng@.timer"
        if [ ! -f "$SERVICE_SRC" ] || [ ! -f "$TIMER_SRC" ]; then
            echo "install.sh: expected ops/systemd/borgsnap-ng@.service and .timer" >&2
            echo "  next to this installer - skipping this step." >&2
        else
            run mkdir -p /etc/systemd/system
            if [ "$DRY_RUN" -eq 0 ]; then
                sed -e "s#ExecStart=.*#ExecStart=$INSTALL_DIR/mail_wrapper.sh $INSTALL_DIR/%i.conf#" \
                    -e "/^\[Service\]/a User=$BORG_USER\\nGroup=$BORG_USER" \
                    "$SERVICE_SRC" > /etc/systemd/system/borgsnap-ng@.service
                echo "+ installed /etc/systemd/system/borgsnap-ng@.service (ExecStart path and User=/Group= adjusted for this install)"
            else
                echo "+ would install /etc/systemd/system/borgsnap-ng@.service (ExecStart path and User=/Group= adjusted for this install)"
            fi
            run cp "$TIMER_SRC" /etc/systemd/system/borgsnap-ng@.timer
            run systemctl daemon-reload || echo "install.sh: 'systemctl daemon-reload' failed - if this is a container without a running systemd, that's expected; run it on the real target system." >&2
            echo "Unit templates installed. Nothing is enabled yet - see ops/README.md"
            echo "for how to enable a timer once you have a config file."
        fi
    else
        echo "Skipping. See ops/README.md for the cron alternative, or install"
        echo "these by hand later."
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=================================================================="
echo "Done."
echo "=================================================================="
echo "borgsnap_ng is installed at: $INSTALL_DIR"
if [ "$USER_EXISTS" -eq 1 ]; then
    echo "Runs as user:                $BORG_USER"
fi
echo ""
echo "Still to do by hand (or with the separate config-setup script):"
echo "  - Delegate ZFS access for your actual datasets:"
echo "      $INSTALL_DIR/ops/least-privilege/setup-zfs-allow.sh (see its README)"
echo "  - Write a .conf file for what you want backed up (see sample.conf)"
echo "  - Enable a timer/cron entry for that config (see ops/README.md)"
echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "This was a DRY RUN - nothing was actually changed. Re-run without --dry-run to apply."
fi
exit 0
