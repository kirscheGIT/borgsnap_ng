#!/bin/sh

export MSG_LEVEL=5
cd ..

. $(pwd)/common/dir_functions.sh
. $(pwd)/filesystem/zfs_hdlr.sh
. $(pwd)/filesystem/zfs_snap_mount.sh

if [ -z "${LASTFUNC+x}" ]; then
    export LASTFUNC=""
fi

# $1 = mount path
# $2 = zfs pool

umountZFSSnapshot "${1}" "${2}" "" ""
msg "Finished unmounting operation"