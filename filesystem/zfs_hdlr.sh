#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${ZFS_HDLR_SOURCED+x}" ]; then
    export ZFS_HDLR_SOURCED=1  
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


fi