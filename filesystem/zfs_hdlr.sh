#!/bin/sh
# zfs_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
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
        getZFSSnap_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="getZFSSnapshot"
        getZFSSnap_OLD_IFS="$IFS"
        IFS=' '
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
            IFS="$getZFSSnap_OLD_IFS"
            unset getZFSSnap_OLD_IFS
            return 1

        elif [ "$#" -eq 3 ]; then
            getZFSSnap_listParameter="$3"          
        fi
        

        # FIX #37: capture zfs list's output once and check its exit code
        # explicitly, instead of piping exec_cmd directly into grep. Piping
        # exec_cmd runs it in a subshell, so if zfs list failed, exec_cmd's
        # internal err_hdlr-triggered exit only killed that subshell - grep
        # would still run against empty input, "not find" a match, and this
        # function would return 1 exactly as if the snapshot legitimately
        # didn't exist. A failed zfs list and "no matching snapshot" were
        # indistinguishable to every caller.
        getZFSSnap_zfslist=$(exec_cmd zfs list -H -t snapshot -o name)
        getZFSSnap_rc=$?
        if [ "$getZFSSnap_rc" -ne 0 ]; then
            err_hdlr "$getZFSSnap_rc"
        fi

        if { [ -z "$getZFSSnap_listParameter" ] || [ "$#" -eq 2 ]; } && [ "$getZFSSnap_StrContainsDate" = 0 ]; then # Get a single snapshot by name
            msg "DEBUG" "We are in the First branch."
            printf '%s\n' "$getZFSSnap_zfslist" | grep "${getZFSSnap_dataset}@${getZFSSnap_date}"
        elif [ "$getZFSSnap_listParameter" = "LATEST" ]; then # Get the latest snapshot of a given backup intervall
            msg "DEBUG" "We are in the LATEST branch."
            printf '%s\n' "$getZFSSnap_zfslist" | grep "${getZFSSnap_dataset}@${getZFSSnap_date}-" | sort -r | head -1 # Get a list of the snapshots of a given backup intervall
        elif [ "$getZFSSnap_listParameter" = "ALL" ]; then
            msg "DEBUG" "We are in the All branch"
            printf '%s\n' "$getZFSSnap_zfslist" | grep "${getZFSSnap_dataset}@${getZFSSnap_date}-" | sort -r
        else
            if [ -n "$getZFSSnap_listParameter" ]; then
                msg "ERROR" "Wrong keyword for function: $getZFSSnap_listParameter "
            fi
            unset getZFSSnap_dataset
            unset getZFSSnap_date
            unset getZFSSnap_listParameter
            unset getZFSSnap_StrContainsDate
            unset getZFSSnap_zfslist
            unset getZFSSnap_rc
            IFS="$getZFSSnap_OLD_IFS"
            unset getZFSSnap_OLD_IFS
            return 1
        fi
        
        LASTFUNC="$getZFSSnap_CALLINGFUCNTION"
        unset getZFSSnap_CALLINGFUCNTION
        unset getZFSSnap_dataset
        unset getZFSSnap_date
        unset getZFSSnap_listParameter
        unset getZFSSnap_StrContainsDate
        unset getZFSSnap_zfslist
        unset getZFSSnap_rc
        IFS="$getZFSSnap_OLD_IFS"
        unset getZFSSnap_OLD_IFS
        return 0
    }

    allZFSSnapshot(){
        # $1 - mandatory list of repo paths
        # $2 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!
        lastZFSSnap_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="lastZFSSnapshot"
        lastZFSSnap_OLD_IFS="$IFS"
        IFS=' '
        lastZFSSnap_dataset="$1"
        lastZFSSnap_date="$2"

        lastZFSSnap_zfslist=$(exec_cmd zfs list -H -t snap -o name)
        lastZFSSnap_rc=$?
        if [ "$lastZFSSnap_rc" -ne 0 ]; then
            err_hdlr "$lastZFSSnap_rc"
        fi
        printf '%s\n' "$lastZFSSnap_zfslist" | grep "${lastZFSSnap_dataset}@${lastZFSSnap_date}-" | sort -r

        LASTFUNC="$lastZFSSnap_CALLINGFUCNTION"
        unset lastZFSSnap_CALLINGFUCNTION    
        unset lastZFSSnap_dataset
        unset lastZFSSnap_date
        unset lastZFSSnap_zfslist
        unset lastZFSSnap_rc
        IFS="$lastZFSSnap_OLD_IFS"
        unset lastZFSSnap_OLD_IFS
    }

    snapshotZFS() {
        # $1 - mandatory ZFS dataset
        # $2 - mandatory ZFS snapshot label
        snapshotZFS_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="snapshotZFS"
        snapshotZFS_OLD_IFS="$IFS"
        IFS=' '
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
            # FIX #7: zfs snapshot is synchronous - the former pgrep -f wait
            # loop could hang forever if any other process (sanoid, second
            # instance, another admin) matched "zfs snapshot".
            msg "INFO" "Snapshot operation for dataset $snapshotZFS_dataset @ label $snapshotZFS_label finished."
        fi
        LASTFUNC="$snapshotZFS_CALLINGFUCNTION"
        unset snapshotZFS_CALLINGFUCNTION
        unset snapshotZFS_recursive
        unset snapshotZFS_dataset
        unset snapshotZFS_label
        IFS="$snapshotZFS_OLD_IFS"
        unset snapshotZFS_OLD_IFS
        return 0
    }    

    pruneZFSSnapshot() {
        pruneZFS_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="pruneZFSSnapshot"
        pruneZFS_OLD_IFS="$IFS"
        IFS=' '
        pruneZFS_dataset="$1"
        pruneZFS_label="$2"
        pruneZFS_keepduration="$3"
       # pruneZFS_recursive="$4"

        pruneZFS_TotalNumberOfSnapshots=""
        pruneZFS_Delete=""

        

        pruneZFS_label="${pruneZFS_label%-*}"
        pruneZFS_TotalNumberOfSnapshots=$(getZFSSnapshot "$pruneZFS_dataset" "$pruneZFS_label" "ALL" | wc -l)

        msg "------ $(date) ------"
        if [ "$pruneZFS_TotalNumberOfSnapshots" -le "$pruneZFS_keepduration" ]; then
            msg "INFO" "No old backups to purge"
        else
            pruneZFS_Delete=$((pruneZFS_TotalNumberOfSnapshots - pruneZFS_keepduration))
            msg "INFO" "Keep: $pruneZFS_keepduration, found: $pruneZFS_TotalNumberOfSnapshots, will delete $pruneZFS_Delete"
            # FIX #3: findall() never existed in this repo (leftover from the
            # original borgsnap) - with set +e the prune silently did nothing
            # and the pool filled up. getZFSSnapshot ... ALL returns the list
            # sorted newest-first, so tail gives the oldest N to delete.
            # FIX #27: zfs list output is newline-separated; with IFS=' ' the
            # whole multi-line result was treated as ONE word and only a
            # single (malformed) destroy was issued.
            pruneZFS_NL=$(printf '\n_'); pruneZFS_NL=${pruneZFS_NL%_}
            IFS="$pruneZFS_NL"
            for i in $(getZFSSnapshot "$pruneZFS_dataset" "$pruneZFS_label" "ALL" | tail -n "$pruneZFS_Delete"); do
                IFS=' '
                msg "INFO" "Purging old snapshot $i"
                # FIX #7: zfs destroy is synchronous - when it returns, the
                # operation is committed. The former pgrep -f wait loop matched
                # ANY process containing "zfs destroy" (sanoid, other admins,
                # a second borgsnap instance) and could hang forever.
                exec_cmd zfs destroy -r "$i"
                msg "INFO" "Purge of old Snapshot finished"
                IFS="$pruneZFS_NL"
            done
            IFS=' '
            unset pruneZFS_NL
        fi
        LASTFUNC="$pruneZFS_CALLINGFUCNTION"
        unset pruneZFS_CALLINGFUCNTION
        unset pruneZFS_TotalNumberOfSnapshots
        unset pruneZFS_Delete
        unset pruneZFS_dataset
        unset pruneZFS_label
        unset pruneZFS_keepduration
        IFS="$pruneZFS_OLD_IFS"
        unset pruneZFS_OLD_IFS
        #unset pruneZFS_recursive

    }   


fi