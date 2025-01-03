#!/bin/sh
# zfs_snap_mount.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${ZFS_SNAP_MOUNT_SOURCED+x}" ]; then
    export ZFS_SNAP_MOUNT_SOURCED=1  
    set +e
    . ../common/msg_and_err_hdlr.sh
    . ../common/helper_functions.sh
    
    if [ -z "${LASTFUNC+x}" ]; then
        export LASTFUNC=""
    fi

    if [ -z "${MSG_DEFINED+x}" ]; then
        msg() {
            LASTFUNC="msg"
            printf "WARNING: msg() function called without invoking the debugging.sh script or explicit disabling it!\n"
            printf "WARNING: No debug or verbose message outputs available!\n"
            return 0
        }
        export MSG_DEFINED=1
    fi

    set -u
    msg "DEBUG" "-----------------------------------------------"
    msg "DEBUG" "sourced zfs_snap_mount.sh"
    msg "DEBUG" "-----------------------------------------------"

    mountZFSSnapshot() {
        mountZFS_snapmountbasedir="$1"
        mountZFS_dataset="$2"
        mountZFS_label="$3"
        mountZFS_recursive="$4"

        LASTFUNC="mountZFSSnapshot"

        dircreate "$mountZFS_snapmountbasedir/$mountZFS_dataset"
       # exec_cmd mount -t zfs "$ldataset@$llabel" "$lsnapmountbasedir/$ldataset"
        # [ ] TODO #2 test the recursive snapshot mount @kirscheGIT 
        # [ ] TODO Idea: Test if a "no mount" list can be used or provided - background: The recursive option takes a snapshot for all subvolumes
        # at the same time. But maybe we don't want to backup all of them
        # [ ] TODO #1 put the mount and umount scripts to separate files and set the setuid bit for those scripts, making it possible for the borg
        # user to mount and unmount snapshots. (Is this also be needed for the createdir functions?) 
        if [ "$mountZFS_recursive" = "r" ] || [ "$mountZFS_recursive" = "R" ] ; then
            for R in $(exec_cmd zfs list -Hr -t snapshot -o name "$mountZFS_dataset" | grep "@$mountZFS_label$" | sed -e "s@^$mountZFS_dataset@@" -e "s/@$mountZFS_label$//"); do
                msg "INFO" "Mounting child filesystem snapshot: $mountZFS_dataset$R@$mountZFS_label"
                dircreate "$mountZFS_snapmountbasedir/$mountZFS_dataset$R"
                exec_cmd mount -t zfs "$mountZFS_dataset$R@$mountZFS_label" "$mountZFS_snapmountbasedir/$mountZFS_dataset$R"
            done
        else
            dircreate "$mountZFS_snapmountbasedir/$mountZFS_dataset"
            exec_cmd mount -t zfs "$mountZFS_dataset@$mountZFS_label" "$mountZFS_snapmountbasedir/$mountZFS_dataset"
        fi

        unset mountZFS_snapmountbasedir
        unset mountZFS_dataset
        unset mountZFS_label
        unset mountZFS_recursive

    }

    
    umountZFSSnapshot() {
        mountZFS_snapmountbasedir="$1"
        mountZFS_dataset="$2"
 
        LASTFUNC="unmountZFSSnapshot"
               

        # Find all directories under the mount point and unmount them
        find "$mountZFS_snapmountbasedir/$mountZFS_dataset" -mindepth 1 -maxdepth 1 -type d | while read -r fs; do
            umount "$fs" && echo "Unmounted $fs" || echo "Failed to unmount $fs"
            exec_cmd rmdir "$fs" #cleanup mount points
        done

        #for R in $(zfs list -Hr -t snapshot -o name "$1" | grep "@$2$" | sed -e "s@^$1@@" -e "s/@$2$//" | tac); do
        #    echo "Unmounting child filesystem snapshot: $bind_dir$R"
        #    umount "$bind_dir$R"
        #done
    }

        unset mountZFS_snapmountbasedir
        unset mountZFS_dataset


fi