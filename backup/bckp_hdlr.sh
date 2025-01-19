#!/bin/sh
# bckp_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${BCKP_HDLR_SOURCED+x}" ]; then
    export BCKP_HDLR_SOURCED=1  
    
    . "$(pwd)"/common/msg_and_err_hdlr.sh
    
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

    msg "DEBUG" "sourced bckp_hdlr.sh"

    
    startBackupMachine(){
        LASTFUNC="startBackupMachine"
        strtBckpMchn_fslist="$1"
        strtBckpMchn_repolist="$2"
        strtBckpMchn_intervallist="$3"
        strtBckpMchn_borgrepoopts="$4"
        strtBckpMchn_borgpurgeopts="$5"
        strtBckpMchn_snapmountbasedir="$6"
 
        strtBckpMchn_label=""
        strtBckpMchn_lastsnap=""       
        strtBckpMchn_keepduration=""
        strtBckpMchn_recursive=""
        strtBckpMchn_borgremotecommand=""

        if [ -z "$strtBckpMchn_borgrepoopts" ]; then
            strtBckpMchn_borgrepoopts="--info --stats --compression=auto,zstd,9 --files-cache=ctime,size,inode --show-rc"
        fi
        if [ -z "$strtBckpMchn_borgpurgeopts" ]; then
            strtBckpMchn_borgpurgeopts="--info --stats --show-rc"
        fi
        if [ -z "$strtBckpMchn_snapmountbasedir" ]; then
            strtBckpMchn_snapmountbasedir="/tmp/borgsnap_ng" # [ ] TODO #3 set to Borg defaults
        fi


        msg "Borg exit code is set to $BORG_EXIT_CODES"
        msg "------ $(date) ------"
        

        strtBckpMchn_date=$(exec_cmd date +"%Y%m%d")
        strtBckpMchn_dayofweek=$(exec_cmd date +"%w")
        strtBckpMchn_dayofmonth=$(exec_cmd date +"%d")

        if ! direxists "$strtBckpMchn_snapmountbasedir" ; then
            msg "INFO" "Creating snap mount directory: $strtBckpMchn_snapmountbasedir"
            dircreate "$strtBckpMchn_snapmountbasedir"
        fi

        OLD_IFS="$IFS"
        IFS=';'


        
        for strtBckpMchn_dataset in $strtBckpMchn_fslist; do
            strtBckpMchn_dataset=$(echo "$strtBckpMchn_dataset" | cut -d',' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
            strtBckpMchn_recursive=$(echo "$strtBckpMchn_dataset" | cut -d',' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
            ###########################################
            # Major logical change compared to original borgsnap:
            # First the snapshot is created. Then the code will take care of the repo and backup dirs
            # Advantage: If something within the repository process or borg goes south, we have hopefully 
            # at least the snapshot!
            ###########################################
            
            # INTERVALLIST has the following format -> Intervalllabel,keepduration;Intervallabel2,Interval2duration;...
            # INTERVALLIST="monthly,1;weekly,4;daily,7"
            for strtBckpMchn_interval in $strtBckpMchn_intervallist; do
                strtBckpMchn_label=$(echo "$strtBckpMchn_interval" | cut -d',' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
                strtBckpMchn_keepduration=$(echo "$strtBckpMchn_interval" | cut -d',' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')
                
                if [ "$strtBckpMchn_label" = "monthly" ] || [ "$strtBckpMchn_label" = "weekly" ]; then
                    strtBckpMchn_lastsnap=$(getZFSSnapshot "$strtBckpMchn_dataset" "$strtBckpMchn_label" "LATEST")
                    if { [ -z "$strtBckpMchn_lastsnap" ] ||  [ "$strtBckpMchn_dayofmonth" -eq 1 ]; } && [ "$strtBckpMchn_label" = "monthly" ]; then
                        strtBckpMchn_label="$strtBckpMchn_label""-""$strtBckpMchn_date"
                        break
                    elif { [ -z "$strtBckpMchn_lastsnap" ] ||  [ "$strtBckpMchn_dayofweek" -eq 0 ]; } && [ "$strtBckpMchn_label" = "weekly" ]; then
                        strtBckpMchn_label="$strtBckpMchn_label""-""$strtBckpMchn_date"
                        break
                    else
                        continue
                    fi
                else
                    strtBckpMchn_label="$strtBckpMchn_label-$strtBckpMchn_date"
                    break
                fi

            done
            # [ ] TODO #4 Pre and post scripts for the snapshots
            snapshotZFS "$strtBckpMchn_dataset" "$strtBckpMchn_label" "$strtBckpMchn_recursive"
            mountZFSSnapshot "$strtBckpMchn_snapmountbasedir" "$strtBckpMchn_dataset" "$strtBckpMchn_label" "$strtBckpMchn_recursive"
            strtBckpMchn_borgpurgeopts="$strtBckpMchn_borgpurgeopts --keep-${strtBckpMchn_label%-*}=$strtBckpMchn_keepduration"
            
            for strtBckpMchn_repoandcmd in $strtBckpMchn_repolist; do
                strtBckpMchn_repo=$(echo "$strtBckpMchn_repoandcmd" | cut -d',' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
                strtBckpMchn_borgremotecommand=$(echo "$strtBckpMchn_repoandcmd" | cut -d',' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')
                msg "DEBUG" "Borg remote command is = $strtBckpMchn_borgremotecommand "
                # now we check if the current repo has to be skipped
                # [ ] TODO #5 changing REPOSKIP from global to local variable
                if { [ "${strtBckpMchn_repo#ssh://}" != "$strtBckpMchn_repo" ] && [ "$REPOSKIP" != "REMOTE" ]; } || \
                    { [ "${strtBckpMchn_repo#ssh://}" = "$strtBckpMchn_repo" ] && [ "$REPOSKIP" != "LOCAL" ]; }; then

                    if ! direxists "$strtBckpMchn_repo"; then
                        msg "INFO" "Creating repo directory: $strtBckpMchn_repo"
                        dircreate "$strtBckpMchn_repo"
                        msg "INFO" "Init Borg repo: $strtBckpMchn_repo"
                        initBorg "$strtBckpMchn_repo" "$strtBckpMchn_borgremotecommand" # [x] TODO #6 Add Borg remote command
                    fi
                    # [x] TODO #7 Take into account recursive snaps
                    set +e
                    msg "DEBUG" "--------------------------- CREATE BORG -----------------------------------"
                    msg "DEBUG" "Repo is: $strtBckpMchn_repo " 
                    createBorg "$strtBckpMchn_repo" "$strtBckpMchn_label" "$strtBckpMchn_borgrepoopts" "$strtBckpMchn_snapmountbasedir/$strtBckpMchn_dataset" "$strtBckpMchn_borgremotecommand" # [x] TODO #8 Add Borg remote command
                    msg "DEBUG" "--------------------------- PRUNE BORG -----------------------------------"
                    msg "DEBUG" "Repo is: $strtBckpMchn_repo " 
                    pruneBorg "$strtBckpMchn_repo" "$strtBckpMchn_borgpurgeopts" "$strtBckpMchn_label" "$strtBckpMchn_borgremotecommand"                # [x] TODO #9 Add Borg remote command
                    msg "DEBUG" "--------------------------- PRUNE ZFS -----------------------------------"
                    msg "DEBUG" "Repo is: $strtBckpMchn_repo " 
                    pruneZFSSnapshot "$strtBckpMchn_dataset" "$strtBckpMchn_label" "$strtBckpMchn_keepduration" ""  
                    
                fi
            done
            msg "DEBUG" "--------------------------------------------------------------"
            msg "DEBUG" "Snapmount base dir: $strtBckpMchn_snapmountbasedir " 
            msg "DEBUG" "Snapmount dataset: $strtBckpMchn_dataset "
            msg "DEBUG" "--------------------------------------------------------------"
            umountZFSSnapshot "$strtBckpMchn_snapmountbasedir" "$strtBckpMchn_dataset"

            
        done
        IFS="$OLD_IFS"

        unset OLD_IFS
        unset strtBckpMchn_interval
        unset strtBckpMchn_dataset
        unset strtBckpMchn_repo
        unset strtBckpMchn_lfslist
        unset strtBckpMchn_repolist
        unset strtBckpMchn_intervallist
        unset strtBckpMchn_borgrepoopts
        unset strtBckpMchn_borgpurgeopts
        unset strtBckpMchn_snapmountbasedir
        unset strtBckpMchn_label
        unset strtBckpMchn_lastsnap       
        unset strtBckpMchn_keepduration
        unset strtBckpMchn_recursive
        unset strtBckpMchn_date
        unset strtBckpMchn_dayofweek
        unset strtBckpMchn_dayofmonth
        unset strtBckpMchn_borgremotecommand
    }

    

fi
