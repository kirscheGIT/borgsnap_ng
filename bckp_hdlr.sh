#!/bin/sh
# bckp_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${BCKP_HDLR_SOURCED+x}" ]; then
    export BCKP_HDLR_SOURCED=1  
    
    . ./msg_and_err_hdlr.sh
    
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

    #TODO mount zfs
    #TODO recursive ZFS snap and mount
    #TODO unmount
    #TODO in case of error exit do an unmount of zfs


    startBackupMachine(){
        LASTFUNC="startBackupMachine"
        lfslist="$1"
        lrepolist="$2"
        lintervallist="$3"
        lborgrepoopts="$4"
        lborgpurgeopts="$5"
        lsnapmountbasedir="$6"
 
        llabel=""
        llastsnap=""       
        lkeepduration=""
        lrecursive=""

        if [ -z "$lborgreopopts" ]; then
            lborgrepoopts="--info --stats --compression auto,zstd,9 --files-cache ctime,size,inode"
        fi
        if [ -z "$lborgpurgeopts" ]; then
            lborgpurgeopts="--info --stats"
        fi
        if [ -z "$lsnapmountbasedir" ]; then
            lsnapmountbasedir="/run/borgsnap_ng/"
        fi



        msg "------ $(date) ------"
        

        ldate=$(exec_cmd date +"%Y%m%d")
        ldayofweek=$(exec_cmd date +"%w")
        ldayofmonth=$(exec_cmd date +"%d")

        if ! direxists "$lsnapmountbasedir"; then
            msg "INFO" "Creating snap mount directory: $lsnapmountbasedir"
            dircreate "$lsnapmountbasedir"
        fi

        OLD_IFS="$IFS"
        IFS=';'


        
        for ldataset in $lfslist; do
            ldataset=$(echo "$ldataset" | cut -d',' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
            lrecursive=$(echo "$ldataset" | cut -d',' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
            ###########################################
            # Major logical change compared to original borgsnap:
            # First the snapshot is created. Then the code will take care of the repo and backup dirs
            # Advantage: If something within the repository process or borg goes south, we have hopefully 
            # at least the snapshot!
            ###########################################
            
            # INTERVALLIST has the following format -> Intervalllabel,keepduration;Intervallabel2,Interval2duration;...
            # INTERVALLIST="monthly,1;weekly,4;daily,7"
            for linterval in $lintervallist; do
                llabel=$(echo "$linterval" | cut -d',' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
                lkeepduration=$(echo "$linterval" | cut -d',' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')
                
                if [ "$llabel" = "monthly" ] || [ "$llabel" = "weekly" ]; then
                    llastsnap=$(getZFSSnapshot "$ldataset" "$llabel" "LAST")
                    if { [ -z "$llastsnap" ] ||  [ "$ldayofmonth" -eq 1 ]; } && [ "$llabel" = "monthly" ]; then
                        llabel="$llabel""-""$ldate"
                    elif { [ -z "$llastsnap" ] ||  [ "$ldayofweek" -eq 0 ]; } && [ "$llabel" = "weekly" ]; then
                        llabel="$llabel""-""$ldate"
                    else
                        continue
                    fi
                else
                    llabel="$llabel-$ldate"
                fi
                # TODO Pre and post scripts for the snapshots
                snapshotZFS "$ldataset" "$llabel" "$lrecursive"

                lborgpurgeopts="$lborgpurgeopts --keep-$llabel=$lkeepduration"

            done

            for repo in $lrepolist; do
                repo=$(echo "$repo" | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
                # now we check if the current repo has to be skipped
                if { [ "${repo#ssh://}" != "$repo" ] && [ "$REPOSKIP" != "REMOTE" ]; } || \
                    { [ "${repo#ssh://}" = "$repo" ] && [ "$REPOSKIP" != "LOCAL" ]; }; then

                    if ! direxists "$repo"; then
                        msg "INFO" "Creating repo directory: $repo"
                        dircreate "$repo"
                        msg "INFO" "Init Borg repo: $repo"
                        initBorg "$repo" # TODO Add Borg remote command
                    fi
                    createBorg "$repo" "$llabel" "$lborgrepoopts" "$ldataset" # TODO Add Borg remote command
                    pruneBorg "$repo" "$lborgpurgeopts"                       # TODO Add Borg remote command
                fi
            done

            
        done
        IFS="$OLD_IFS"

        unset linterval
        unset ldataset
        unset repo
        unset lfslist
        unset lrepolist
        unset lintervallist
        unset lborgrepoopts
        unset lborgpurgeopts
        unset lsnapmountbasedir
        unset llabel
        unset llastsnap       
        unset lkeepduration
        unset lrecursive
        unset ldate
        unset ldayofweek
        unset ldayofmonth
    }
    execBackup(){
        LASTFUNC="execBackup"


          # $1 - volume, i.e. zroot/home
            # $2 - label, i.e. monthly-20170602
            # Expects localdir, remotedir, BINDDIR
            LASTFUNC="dobackup"
            msg "------ $(date) ------"
            bind_dir="${BINDDIR}/${1}"
            exec_cmd mkdir -p "$bind_dir"
            msg "DEBUG" "bind_dir is: $bind_dir" 
            exec_cmd mount -t zfs "${1}@${2}" "$bind_dir"
            if [ "$RECURSIVE" = "true" ]; then
                recursivezfsmount "$1" "$2"
            fi
            BORG_OPTS="--info --stats --compression $COMPRESS --files-cache $CACHEMODE --exclude-if-present .noborg"
            if [ "$localdir" != "" ] && [ "$LOCALSKIP" != "true" ]; then
                echo "Doing local backup of ${1}@${2}"
                # shellcheck disable=SC2086
                borg create $BORG_OPTS "${localdir}::${2}" "$bind_dir"
                if [ "$LOCAL_READABLE_BY_OTHERS" = "true" ]; then
                echo "Set read permissions for others"
                chmod +rx "${localdir}" -R
                fi
            else
                msg "INFO" "Skipping local backup"
            fi
            if [ "$remotedir" != "" ]; then
                echo "Doing remote backup of ${1}@${2}"
                # shellcheck disable=SC2086
                borg create $BORG_OPTS --remote-path="${BORGPATH}" "${remotedir}::${2}" "$bind_dir"
            fi
            if [ "$RECURSIVE" = "true" ]; then
                recursivezfsumount "$1" "$2"
            fi

            umount -n "$bind_dir"        


    }    
    

fi