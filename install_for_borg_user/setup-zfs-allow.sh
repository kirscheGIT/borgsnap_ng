#!/bin/sh
# setup-zfs-allow.sh - licensed under GPLv3. See the LICENSE file for
# additional details.
#
# Delegates exactly the ZFS permissions borgsnap_ng needs to run as a
# non-root user (e.g. "borg"), instead of root - the least-privilege setup
# discussed and researched for this project.
#
# Run this ONCE, as root, per dataset you want borgsnap_ng to manage.
#
# Usage:
#   setup-zfs-allow.sh source <user> <source-dataset>
#   setup-zfs-allow.sh target <user> <target-prefix>
#
# Examples:
#   sudo ./setup-zfs-allow.sh source borg tank/data
#   sudo ./setup-zfs-allow.sh target borg usbpool/backups
#
# Background / why these specific permissions (see the conversation this
# was designed in for the full research trail):
#
#   SOURCE side (where your live data lives): snapshot, destroy, send,
#   bookmark, hold, release. This never needs "mount" - the source dataset
#   is already mounted normally by the system at boot; borgsnap_ng only
#   snapshots/sends from it, never (re-)mounts it itself via zfs allow.
#
#   TARGET side (zfssend destinations only - skip this if you only use the
#   borg backend): create, receive:append, destroy, readonly.
#     - receive:append (not plain "receive") requires OpenZFS >= 2.2 -
#       it rejects destructive receives (zfs recv -F), which our code
#       never uses anyway, so this is free extra safety with no downside.
#     - "mount" is NOT delegable on Linux at all (OpenZFS's own docs:
#       "these permissions cannot be delegated because the Linux mount(8)
#       command restricts modifications of the global namespace to the
#       root user"). Real-world testing (Klara Systems, OpenZFS
#       specialists) confirms zfs receive's data transfer still succeeds
#       as a delegated user - only the automatic post-receive mount
#       attempt fails, harmlessly. Since borgsnap_ng's zfssend target is
#       never actually mounted (we only manage snapshots/properties on
#       it, never read files from it), the clean fix - also Klara's own
#       recommendation - is to set mountpoint=none on the target so that
#       auto-mount attempt never happens in the first place.
#
#   Separately from all of this, mount/umount (the *generic* OS command,
#   for mounting snapshots for the borg backend) and zpool import/export
#   (removable-media pool lifecycle) can NEVER be delegated via zfs allow
#   at all - see borgsnap-ng.sudoers in this same directory for those.

set -eu

usage() {
    echo "Usage: $0 source <user> <source-dataset>" >&2
    echo "       $0 target <user> <target-prefix>" >&2
    exit 1
}

[ "$#" -eq 3 ] || usage
zfsallow_mode="$1"
zfsallow_user="$2"
zfsallow_dataset="$3"

if [ "$(id -u)" -ne 0 ]; then
    echo "This must be run as root (it grants permissions on behalf of other users)." >&2
    exit 1
fi

case "$zfsallow_mode" in
    source)
        echo "==> Delegating SOURCE-side permissions to '$zfsallow_user' on '$zfsallow_dataset'"
        echo "    (snapshot, destroy, send, bookmark, hold, release)"
        zfs allow -u "$zfsallow_user" snapshot,destroy,send,bookmark,hold,release "$zfsallow_dataset"
        ;;
    target)
        echo "==> Setting mountpoint=none on '$zfsallow_dataset' (and its descendants)"
        echo "    so the automatic post-receive mount attempt never happens - this"
        echo "    dataset tree is never meant to be mounted, only managed at the ZFS"
        echo "    admin level (snapshots/properties)."
        if ! zfs list -H "$zfsallow_dataset" >/dev/null 2>&1; then
            echo "    '$zfsallow_dataset' does not exist yet - creating it first."
            zfs create -p "$zfsallow_dataset"
        fi
        zfs set mountpoint=none "$zfsallow_dataset"

        echo "==> Delegating TARGET-side permissions to '$zfsallow_user' on '$zfsallow_dataset'"
        echo "    (create, receive:append, destroy, readonly)"
        zfs allow -u "$zfsallow_user" create,receive:append,destroy,readonly "$zfsallow_dataset"
        ;;
    *)
        usage
        ;;
esac

echo ""
echo "==> Resulting permissions on '$zfsallow_dataset':"
zfs allow "$zfsallow_dataset"
