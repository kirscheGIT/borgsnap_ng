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
#   SOURCE side (where your live data lives): snapshot, destroy, mount,
#   send, bookmark, hold, release. The source dataset is already mounted
#   normally by the system at boot and never needs (re-)mounting through
#   this delegation - "mount" is included purely because "destroy" (used
#   for retention pruning) has it as an internal ZFS dependency, the same
#   pattern as the target side below.
#
#   TARGET side (zfssend destinations only - skip this if you only use the
#   borg backend): create, mount, receive, receive:append, destroy,
#   readonly.
#     - "mount" is granted even though the underlying Linux mount(8)
#       syscall will still refuse to actually mount anything as this user
#       (see the OpenZFS docs quote above) - but ZFS's own internal
#       dependency check for create/receive requires "mount" to be
#       PRESENT in the delegation table, or the receive is rejected
#       outright with "cannot receive new filesystem stream: permission
#       denied" (confirmed by Klara Systems' own tested walkthrough -
#       receive+create alone reproduces exactly this error; adding mount,
#       even though it can't functionally succeed, changes it to the much
#       softer "cannot mount ... failed to create mountpoint", which
#       mountpoint=none below avoids ever triggering in the first place).
#     - Both receive AND receive:append are granted together, not
#       receive:append alone - real-world reports (Sanoid/Syncoid's own
#       delegation issues, old SmartOS/illumos reports) confirm this area
#       of ZFS is more finicky than the docs alone suggest.
#     - receive:append additionally rejects destructive receives (zfs recv
#       -F), which our code never uses anyway - free extra safety on top
#       of plain receive, not a replacement for it.
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
        echo "    (snapshot, destroy, mount, send, bookmark, hold, release)"
        echo "    Note: 'mount' is included for the same reason as on the target side -"
        echo "    ZFS's own internal dependency check for 'destroy' requires 'mount' to"
        echo "    be present in the delegation table, even though the source dataset is"
        echo "    already mounted normally by the system and never needs re-mounting"
        echo "    here."
        zfs allow -u "$zfsallow_user" snapshot,destroy,mount,send,bookmark,hold,release "$zfsallow_dataset"
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
        echo "    (create, mount, receive, receive:append, destroy, readonly)"
        echo "    Note: 'mount' is granted even though it can't functionally mount on"
        echo "    Linux (see the sudoers piece for real mounting elsewhere) - ZFS's own"
        echo "    internal dependency check for create/receive requires it to be PRESENT"
        echo "    in the delegation table, or you get 'cannot receive new filesystem"
        echo "    stream: permission denied' outright. mountpoint=none (set above) means"
        echo "    the actual (would-be-blocked) auto-mount attempt never happens, so this"
        echo "    is safe - we only need the dependency check satisfied, not real mounting."
        zfs allow -u "$zfsallow_user" create,mount,receive,receive:append,destroy,readonly "$zfsallow_dataset"
        ;;
    *)
        usage
        ;;
esac

echo ""
echo "==> Resulting permissions on '$zfsallow_dataset':"
zfs allow "$zfsallow_dataset"
