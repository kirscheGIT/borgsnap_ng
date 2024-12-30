#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${ZFS_HDLR_SOURCED+x}" ]; then
    export ZFS_HDLR_SOURCED=1  
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
    msg "DEBUG" "sourced zfs_hdlr.sh"
    msg "DEBUG" "-----------------------------------------------"
    
    
    getZFSSnapshot(){
        # $1 - mandatory zfs dataset
        # $2 - madatory date of dataset or name of interval: 
        #      e.g. "daily-20241212" - in that case the third 
        #       parameter is ignored
        #       if given weekly, daily or monthly the output depends
        #       on the third parameter
        # $3 -  optional when given a snapshot name with a valid date "YYYYMMDD" as the first parameter 
        #       Valid values are weekly, monthly, daily

        msg "DEBUG" "Number of parameters for function: $# "

        LASTFUNC="getZFSSnapshot"
        getZFSSnap_dataset="$1"
        getZFSSnap_date="$2"
        getZFSSnap_listParameter=""
        getZFSSnap_StrContainsDate=1

        chkDateStr "$getZFSSnap_date"
        getZFSSnap_StrContainsDate=$?
        msg "DEBUG" "getZFSSnap_StrContainsDate = $getZFSSnap_StrContainsDate"
        # check the vlaidity of the parameters 2 and 3  
        if { [ "$#" -ne 3 ] && [ "$#" -ne 2 ]; } || [ "$getZFSSnap_StrContainsDate" = 2 ]; then
            if [ "$getZFSSnap_StrContainsDate" = 2 ]; then
                msg "ERROR" "No valid date or interval string provided: $getZFSSnap_date "
            else
                msg "ERROR" "Wrong number of parameters for function: $# "
            fi
            unset getZFSSnap_dataset
            unset getZFSSnap_date
            unset getZFSSnap_listParameter
            unset getZFSSnap_StrContainsDate
            return 1

        elif [ "$#" -eq 3 ]; then
            getZFSSnap_listParameter="$3"          
        fi
        

        if { [ -z "$getZFSSnap_listParameter" ] || [ "$#" -eq 2 ]; } && [ "$getZFSSnap_StrContainsDate" = 0 ]; then # Get a single snapshot by name
            msg "DEBUG" "We are in the First branch."
            exec_cmd zfs list -t snapshot -o name | grep "${getZFSSnap_dataset}@${getZFSSnap_date}"
        elif [ "$getZFSSnap_listParameter" = "LATEST" ]; then # Get the latest snapshot of a given backup intervall
            msg "DEBUG" "We are in the LATEST branch."
            exec_cmd zfs list -t snapshot -o name | grep "${getZFSSnap_dataset}@${getZFSSnap_date}-" | sort -nr | head -1 # Get a list of the snapshots of a given backup intervall
        elif [ "$getZFSSnap_listParameter" = "ALL" ]; then
            msg "DEBUG" "We are in the All branch"
            exec_cmd zfs list -t snap -o name | grep "${getZFSSnap_dataset}@${getZFSSnap_date}-" | sort -nr
        else
            if [ -n "$getZFSSnap_listParameter" ]; then
                msg "ERROR" "Wrong keyword for function: $getZFSSnap_listParameter "
            fi
            unset getZFSSnap_dataset
            unset getZFSSnap_date
            unset getZFSSnap_listParameter
            unset getZFSSnap_StrContainsDate
            return 1
        fi
        
 
        unset getZFSSnap_dataset
        unset getZFSSnap_date
        unset getZFSSnap_listParameter
        unset getZFSSnap_StrContainsDate
        return 0
    }

    allZFSSnapshot(){
        # $1 - mandatory list of repo paths
        # $2 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!

        LASTFUNC="lastZFSSnapshot"
        lastZFSSnap_dataset="$1"
        lastZFSSnap_date="$2"

        exec_cmd zfs list -t snap -o name | grep "${lastZFSSnap_dataset}@${lastZFSSnap_date}-" | sort -nr

        unset lastZFSSnap_dataset
        unset lastZFSSnap_date
    }

    snapshotZFS() {
        # $1 - mandatory ZFS dataset
        # $2 - mandatory ZFS snapshot label
        LASTFUNC="snapshotZFS"
        snapshotZFS_dataset="$1"
        snapshotZFS_label="$2"
        snapshotZFS_recursive="$3"


        if [ -n "$(getZFSSnapshot "$snapshotZFS_dataset" "$snapshotZFS_label")" ]; then
            msg "WARNING" "ZFS Snapshot for dataset $snapshotZFS_dataset @ label $snapshotZFS_label exists!"
            msg "WARNING" "Assuming last Borg run didn't finish - restarting Borg"
        else
            if [ "$snapshotZFS_recursive" = "r" ] || [ "$snapshotZFS_recursive" = "R" ] ; then
                exec_cmd zfs snapshot -r "$snapshotZFS_dataset@$snapshotZFS_label"
            else
                exec_cmd zfs snapshot "$snapshotZFS_dataset@$snapshotZFS_label"
            fi
            # Check if the snapshot operation is still running
            # depending on the system load and disk speed this might take longer than
            # anticipated
            # [x] TODO: Implement Time Out?
            while pgrep -f "zfs snapshot" > /dev/null; do
                    echo "Waiting for the snapshot operation to complete..."
                    sleep 5  #Sleep for a short time before checking again
            done
            msg "INFO" "Snapshot operation for dataset $snapshotZFS_dataset @ label $snapshotZFS_label finished."
        fi

        unset snapshotZFS_recursive
        unset snapshotZFS_dataset
        unset snapshotZFS_label
        return 0
    }    

    pruneZFSSnapshot() {
        pruneZFS_dataset="$1"
        pruneZFS_label="$2"
        pruneZFS_keepduration="$3"
       # pruneZFS_recursive="$4"

        pruneZFS_TotalNumberOfSnapshots=""
        pruneZFS_Delete=""

        LASTFUNC="pruneZFSSnapshot"

        pruneZFS_label="${pruneZFS_label%-*}"
        pruneZFS_TotalNumberOfSnapshots=$(getZFSSnapshot "$pruneZFS_dataset" "$pruneZFS_label" "ALL" | wc -l)

        msg "------ $(date) ------"
        if [ "$pruneZFS_TotalNumberOfSnapshots" -le "$pruneZFS_keepduration" ]; then
            msg "INFO" "No old backups to purge"
        else
            pruneZFS_Delete=$((pruneZFS_TotalNumberOfSnapshots - pruneZFS_keepduration))
            msg "INFO" "Keep: $pruneZFS_keepduration, found: $pruneZFS_TotalNumberOfSnapshots, will delete $pruneZFS_Delete"
            for i in $(findall "$pruneZFS_dataset" "$pruneZFS_label" | tail -n "$pruneZFS_Delete"); do
                msg "INFO" "Purging old snapshot $i"
                exec_cmd zfs destroy -r "$i"
                while pgrep -f "zfs destroy" > /dev/null; do
                    msg "INFO" "Waiting for the destroy operation to complete..."
                    sleep 1  #Sleep for a short time before checking again
                done
                msg "INFO" "Purge of old Snapshot finished"
            done
        fi
        
        unset pruneZFS_TotalNumberOfSnapshots
        unset pruneZFS_Delete
        unset pruneZFS_dataset
        unset pruneZFS_label
        unset pruneZFS_keepduration
        #unset pruneZFS_recursive

    }   

    mountZFSSnapshot() {
        mountZFS_snapmountbasedir="$1"
        mountZFS_dataset="$2"
        mountZFS_label="$3"
        mountZFS_recursive="$4"

        LASTFUNC="mountZFSSnapshot"

        dircreate "$mountZFS_snapmountbasedir/$mountZFS_dataset"
       # exec_cmd mount -t zfs "$ldataset@$llabel" "$lsnapmountbasedir/$ldataset"
        # [ ] TODO #2 test the recursive snapshot mount 
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