#!/bin/sh
# zfs_snap_mount.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${ZFS_SNAP_MOUNT_SOURCED+x}" ]; then
    export ZFS_SNAP_MOUNT_SOURCED=1  
    set +e

    . "$(pwd)"/common/msg_and_err_hdlr.sh
    . "$(pwd)"/common/helper_functions.sh
    
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
        mountZFS_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="mountZFSSnapshot"
	    msg "DEBUG" " ---- mount snap start IFS = $IFS ------------------"
        mountZFS_OLD_IFS="$IFS"
        IFS=' '
        mountZFS_snapmountbasedir="$1"
        mountZFS_dataset="$2"
        mountZFS_label="$3"
        mountZFS_recursive="$4"
        export MOUNT_BORG_BASE_DIR=$mountZFS_snapmountbasedir
        msg "DEBUG" "Snap mount base dir is: $mountZFS_snapmountbasedir"

        dircreate "$mountZFS_snapmountbasedir/$mountZFS_dataset"
       # exec_cmd mount -t zfs "$ldataset@$llabel" "$lsnapmountbasedir/$ldataset"
        # [ ] TODO #2 test the recursive snapshot mount @kirscheGIT 
        # [ ] TODO Idea: Test if a "no mount" list can be used or provided - background: The recursive option takes a snapshot for all subvolumes
        # at the same time. But maybe we don't want to backup all of them
        # [x] TODO #1 put the mount and umount scripts to separate files and set the setuid bit for those scripts, making it possible for the borg
        # user to mount and unmount snapshots. (Is this also be needed for the createdir functions?) 
        # FIX #5: record every mountpoint in a manifest so umount can tear
        # down exactly what was mounted (in reverse order). The previous
        # umount used find -maxdepth 1 on the base dir, which only ever saw
        # the pool directory (depth 1), never the real mountpoints at
        # base/pool/dataset (depth 2+).
        MOUNT_MANIFEST="$mountZFS_snapmountbasedir/.mounts"
        export MOUNT_MANIFEST
        : > "$MOUNT_MANIFEST"
        if [ "$mountZFS_recursive" = "r" ] || [ "$mountZFS_recursive" = "R" ] ; then
            # FIX #52: mount the top-level dataset itself first, always,
            # unconditionally - regardless of whether it has children. This
            # used to only happen implicitly via the loop below matching an
            # empty-suffix entry for the top-level dataset's own snapshot -
            # but "for R in $(...)" silently DROPS empty-string words
            # during shell word-splitting, so that entry never actually
            # reached the loop body, with or without children present.
            # Only child datasets were ever actually mounted; the
            # top-level dataset's own directory stayed empty the whole
            # time, and Borg archived either nothing (no children at all)
            # or only the child mountpoints (children present, but the
            # parent's own files silently missing).
            dircreate "$mountZFS_snapmountbasedir/$mountZFS_dataset"
            exec_cmd sudo mount -t zfs "$mountZFS_dataset@$mountZFS_label" "$mountZFS_snapmountbasedir/$mountZFS_dataset"
            echo "$mountZFS_snapmountbasedir/$mountZFS_dataset" >> "$MOUNT_MANIFEST"

            # FIX #37: capture zfs list's output once and check its exit
            # code, instead of piping exec_cmd directly into grep|sed inside
            # the command substitution. The pipe ran exec_cmd in a subshell,
            # so a failed zfs list would have its error silently swallowed -
            # the for loop would just iterate over nothing, looking
            # identical to "no matching child snapshots".
            mountZFS_zfslist=$(exec_cmd zfs list -Hr -t snapshot -o name "$mountZFS_dataset")
            mountZFS_rc=$?
            if [ "$mountZFS_rc" -ne 0 ]; then
                err_hdlr "$mountZFS_rc"
            fi
            # FIX #27: iterate newline-separated zfs list output with newline
            # IFS, otherwise all child entries collapse into one word.
            mountZFS_NL=$(printf '\n_'); mountZFS_NL=${mountZFS_NL%_}
            IFS="$mountZFS_NL"
            for R in $(printf '%s\n' "$mountZFS_zfslist" | grep "@$mountZFS_label$" | sed -e "s@^$mountZFS_dataset@@" -e "s/@$mountZFS_label$//"); do
                IFS=' '
                # The top-level dataset's own (empty-suffix) entry never
                # actually reaches here - word-splitting drops it, per
                # FIX #52 above - but skip explicitly anyway rather than
                # relying on that as the only guard, in case IFS or the
                # sed output ever changes shape.
                if [ -z "$R" ]; then
                    IFS="$mountZFS_NL"
                    continue
                fi
                msg "INFO" "Mounting child filesystem snapshot: $mountZFS_dataset$R@$mountZFS_label"
                dircreate "$mountZFS_snapmountbasedir/$mountZFS_dataset$R"
                exec_cmd sudo mount -t zfs "$mountZFS_dataset$R@$mountZFS_label" "$mountZFS_snapmountbasedir/$mountZFS_dataset$R"
                echo "$mountZFS_snapmountbasedir/$mountZFS_dataset$R" >> "$MOUNT_MANIFEST"
                IFS="$mountZFS_NL"
            done
            IFS=' '
            unset mountZFS_NL
        else
            dircreate "$mountZFS_snapmountbasedir/$mountZFS_dataset"
            exec_cmd sudo mount -t zfs "$mountZFS_dataset@$mountZFS_label" "$mountZFS_snapmountbasedir/$mountZFS_dataset"
            echo "$mountZFS_snapmountbasedir/$mountZFS_dataset" >> "$MOUNT_MANIFEST"
        fi
        
	    LASTFUNC="$mountZFS_CALLINGFUCNTION"
        unset mountZFS_CALLINGFUCNTION
        IFS="$mountZFS_OLD_IFS"
        msg "DEBUG" " ---- mount snap end IFS = $IFS ------------------"
        unset mountZFS_OLD_IFS
        unset mountZFS_snapmountbasedir
        unset mountZFS_dataset
        unset mountZFS_label
        unset mountZFS_recursive
        unset mountZFS_zfslist
        unset mountZFS_rc

    }

    
    umountZFSSnapshot() {
        # $1 - mandatory snap mount base dir
        # $2 - optional dataset (kept for API compatibility; FIX #8: err_hdlr
        #      calls this function with a single argument, which crashed under
        #      set -u before)
        unmountZFS_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="unmountZFSSnapshot"
        unmountZFS_snapmountbasedir="$1"
        unmountZFS_dataset="${2:-}"
        unmountZFS_OLD_IFS="$IFS"
        IFS=' '
        unmountZFS_manifest="${MOUNT_MANIFEST:-$unmountZFS_snapmountbasedir/.mounts}"

        # FIX #5: unmount exactly the recorded mountpoints, deepest/last first.
        if [ -f "$unmountZFS_manifest" ]; then
            sed -n '1!G;h;$p' "$unmountZFS_manifest" | while read -r fs; do
                [ -n "$fs" ] || continue
                if sudo umount "$fs"; then
                    msg "INFO" "Unmounted $fs"
                    rmdir "$fs" 2>/dev/null
                else
                    msg "WARNING" "Failed to unmount $fs"
                fi
            done
            rm -f "$unmountZFS_manifest"
        else
            msg "WARNING" "No mount manifest found at $unmountZFS_manifest - nothing to unmount"
        fi

        LASTFUNC="$unmountZFS_CALLINGFUCNTION"
        unset unmountZFS_CALLINGFUCNTION
        unset unmountZFS_snapmountbasedir
        unset unmountZFS_dataset
        unset unmountZFS_manifest
        IFS="$unmountZFS_OLD_IFS"
        unset unmountZFS_OLD_IFS
    }

        


fi
