#!/bin/sh

export MSG_LEVEL=5

# change the working directory to the borgsnap_ng
cd ..

. $(pwd)/common/dir_functions.sh
. $(pwd)/filesystem/zfs_hdlr.sh
. $(pwd)/filesystem/zfs_snap_mount.sh

if [ -z "${LASTFUNC+x}" ]; then
    export LASTFUNC=""
fi

# $1 = mount path
# $2 = zfs pool
# $3 = specific snapshot e.g. dayly-20241228
# $4 = subvolume

mountZFSSnapshot "${1}" "${2}" "${3}" "r"
msg "Finished recursive mounting operation"
umountZFSSnapshot "${1}" "${2}" "" ""
msg "Finished unmounting operation"
mountZFSSnapshot "${1}" "${2}/${4}" "${3}" ""
msg "Finished mounting operation"
umountZFSSnapshot "${1}" "${2}" "" ""
msg "Finished unmounting operation"