#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${ZFS_HDLR_SOURCED+x}" ]; then
    export ZFS_HDLR_SOURCED=1  
    set +e
    . ./msg_and_err_hdlr.sh
    . ./helper_functions.sh
    
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
        ldataset="$1"
        ldate="$2"
        llistParameter=""
        lStrContainsDate=1

        chkDateStr "$ldate"
        lStrContainsDate=$?
        msg "DEBUG" "lStrContainsDate = $lStrContainsDate"
        # check the vlaidity of the parameters 2 and 3  
        if { [ "$#" -ne 3 ] && [ "$#" -ne 2 ]; } || [ "$lStrContainsDate" = 2 ]; then
            if [ "$lStrContainsDate" = 2 ]; then
                msg "ERROR" "No valid date or interval string provided: $ldate "
            else
                msg "ERROR" "Wrong number of parameters for function: $# "
            fi
            unset ldataset
            unset ldate
            unset llistParameter
            unset lStrContainsDate
            return 1

        elif [ "$#" -eq 3 ]; then
            llistParameter="$3"          
        fi
        

        if { [ -z "$llistParameter" ] || [ "$#" -eq 2 ]; } && [ "$lStrContainsDate" = 0 ]; then # Get a single snapshot by name
            msg "DEBUG" "We are in the First branch."
            exec_cmd zfs list -t snapshot -o name | grep "${1}@${2}"
        elif [ "$llistParameter" = "LATEST" ]; then # Get the latest snapshot of a given backup intervall
            msg "DEBUG" "We are in the LATEST branch."
            exec_cmd zfs list -t snapshot -o name | grep "${ldataset}@${ldate}-" | sort -nr | head -1 # Get a list of the snapshots of a given backup intervall
        elif [ "$llistParameter" = "ALL" ]; then
            msg "DEBUG" "We are in the All branch"
            exec_cmd zfs list -t snap -o name | grep "${ldataset}@${ldate}-" | sort -nr
        else
            if [ -n "$llistParameter" ]; then
                msg "ERROR" "Wrong keyword for function: $llistParameter "
            fi
            unset ldataset
            unset ldate
            unset llistParameter
            unset lStrContainsDate
            return 1
        fi
        
 
        unset ldataset
        unset ldate
        unset llistParameter
        unset lStrContainsDate
        return 0
    }

    allZFSSnapshot(){
        # $1 - mandatory list of repo paths
        # $2 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!

        LASTFUNC="lastZFSSnapshot"
        ldataset="$1"
        ldate="$2"

        exec_cmd zfs list -t snap -o name | grep "${ldataset}@${ldate}-" | sort -nr

        unset ldataset
        unset ldate
    }

    snapshotZFS() {
        # $1 - mandatory ZFS dataset
        # $2 - mandatory ZFS snapshot label
        LASTFUNC="snapshotZFS"
        ldataset="$1"
        llabel="$2"
        lrecursive="$3"


        if [ -n "$(getZFSSnapshot "$ldataset" "$llabel")" ]; then
            msg "WARNING" "ZFS Snapshot for dataset $ldataset @ label $llabel exists!"
            msg "WARNING" "Assuming last Borg run didn't finish - restarting Borg"
        else
            if [ "$lrecursive" = "r" ] || [ "$lrecursive" = "R" ] ; then
                exec_cmd zfs snapshot -r "$ldataset}@$llabel"
            else
                exec_cmd zfs snapshot "$ldataset}@$llabel"
            fi
            # Check if the snapshot operation is still running
            # depending on the system load and disk speed this might take longer than
            # anticipated
            # TODO: Implement Time Out?
            while pgrep -f "zfs snapshot" > /dev/null; do
                    echo "Waiting for the snapshot operation to complete..."
                    sleep 5  #Sleep for a short time before checking again
            done
            msg "INFO" "Snapshot operation for dataset $ldataset @ label $llabel finished."
        fi

        unset lrecursive
        unset ldataset
        unset llabel
        return 0
    }    

    destroysnapshot() {
        if [ "$RECURSIVE" = "true" ]; then
            echo "Recursive snapshot ${1}@${2}"
            zfs destroy -r "${1}@${2}"
        else
            echo "Snapshot ${1}@${2}"
            zfs destroy "${1}@${2}"
        fi

        # Check if the destroy operation is still running
        while pgrep -f "zfs destroy" > /dev/null; do
            echo "Waiting for the destroy operation to complete..."
            sleep 5  #Sleep for a short time before checking again
        done

        echo "Destroy operation has completed."
    }


    recursivezfsmount() {
        # $1 - volume, pool/dataset
        # $2 - snapshot label
        # Expects $bind_dir

        for R in $(zfs list -Hr -t snapshot -o name "$1" | grep "@$2$" | sed -e "s@^$1@@" -e "s/@$2$//"); do
            echo "Mounting child filesystem snapshot: $1$R@$2"
            mkdir -p "$bind_dir$R"
            mount -t zfs "$1$R@$2" "$bind_dir$R"
        done
    }
    
    recursivezfsumount() {
        # $1 - volume, pool/dataset
        # $2 - snapshot label
        # Expects $bind_dir

        for R in $(zfs list -Hr -t snapshot -o name "$1" | grep "@$2$" | sed -e "s@^$1@@" -e "s/@$2$//" | tac); do
            echo "Unmounting child filesystem snapshot: $bind_dir$R"
            umount "$bind_dir$R"
        done
    }


fi