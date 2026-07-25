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
            # FIX #39 (resolves TODO #3): use BINDDIR, which borgsnap_ng.sh
            # already exports as "/run/borgsnap" but which nothing actually
            # read until now - the hardcoded /tmp/borgsnap_ng default was
            # still in effect. /run is root-only (mode 755), tmpfs, and not
            # subject to systemd-tmpfiles' periodic /tmp sweeps - /tmp was a
            # predictable, world-writable path for a root-mounted
            # filesystem, i.e. a real (if narrow) symlink-attack surface.
            # The ${BINDDIR:-/run/borgsnap} fallback keeps this function
            # safe to call/test even if borgsnap_ng.sh's export somehow
            # didn't run first.
            strtBckpMchn_snapmountbasedir="${BINDDIR:-/run/borgsnap}"
        fi


        msg "Borg exit code is set to $BORG_EXIT_CODES"
        msg "------ $(date) ------"
        

        strtBckpMchn_date=$(exec_cmd date +"%Y%m%d")
        strtBckpMchn_rc=$?
        [ "$strtBckpMchn_rc" -eq 0 ] || err_hdlr "$strtBckpMchn_rc"
        strtBckpMchn_dayofweek=$(exec_cmd date +"%w")
        strtBckpMchn_rc=$?
        [ "$strtBckpMchn_rc" -eq 0 ] || err_hdlr "$strtBckpMchn_rc"
        strtBckpMchn_dayofmonth=$(exec_cmd date +"%d")
        strtBckpMchn_rc=$?
        [ "$strtBckpMchn_rc" -eq 0 ] || err_hdlr "$strtBckpMchn_rc"

        if ! direxists "$strtBckpMchn_snapmountbasedir" ; then
            msg "INFO" "Creating snap mount directory: $strtBckpMchn_snapmountbasedir"
            dircreate "$strtBckpMchn_snapmountbasedir"
        fi

        OLD_IFS="$IFS"
        IFS=';'


        
        for strtBckpMchn_fsentry in $strtBckpMchn_fslist; do
            # FIX #2: recursive flag must be cut from the original entry.
            # Previously it was cut from the already-cut dataset name (which
            # contains no comma anymore), so cut -f2 returned the dataset name
            # itself and recursion silently never happened.
            strtBckpMchn_dataset=$(echo "$strtBckpMchn_fsentry" | cut -d',' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')
            strtBckpMchn_recursive=$(echo "$strtBckpMchn_fsentry" | cut -s -d',' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')
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
                    strtBckpMchn_rc=$?
                    # FIX #38: getZFSSnapshot's own internal err_hdlr call
                    # (see FIX #37) terminates only the subshell created by
                    # this command substitution - $? right here correctly
                    # reflects that exit code, but without this explicit
                    # check the empty $strtBckpMchn_lastsnap that results
                    # was silently treated as "no previous snapshot exists"
                    # instead of "the zfs query itself failed".
                    if [ "$strtBckpMchn_rc" -ne 0 ]; then
                        err_hdlr "$strtBckpMchn_rc"
                    fi
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
            # FIX #33: Borg archive names must be unique *within a repo*.
            # strtBckpMchn_label (interval-date, e.g. "monthly-20260719") is
            # correct and sufficient for ZFS snapshot naming, since ZFS
            # already namespaces snapshots by dataset. But when multiple
            # datasets share the same borg repo, using that same label as
            # the archive name collides on the second dataset ("Archive
            # monthly-20260719 already exists", rc 30) - discovered via a
            # real borg run against a real multi-dataset config; the mock
            # harness can't catch this since the borg mock doesn't enforce
            # uniqueness. Prepend a filesystem-safe dataset slug to
            # disambiguate archive names (dataset first, e.g.
            # "tank_data-daily-20260719"), without touching the ZFS-side label at all.
            strtBckpMchn_dataslug=$(echo "$strtBckpMchn_dataset" | tr '/' '_')
            strtBckpMchn_borglabel="$strtBckpMchn_dataslug-$strtBckpMchn_label"
            # FIX #4: build prune options per dataset instead of appending to
            # the shared variable (which accumulated one --keep flag per
            # dataset iteration).
            # FIX #1: restrict prune to archives of the current interval via
            # glob, otherwise borg prune with only e.g. --keep-daily=7 would
            # delete weekly-/monthly- archives as well.
            # FIX #33: glob must also match the dataset slug now that it's
            # part of the archive name, otherwise prune would consider every
            # dataset's archives together instead of scoping to this one.
            strtBckpMchn_pruneopts="$strtBckpMchn_borgpurgeopts --keep-${strtBckpMchn_label%-*}=$strtBckpMchn_keepduration --glob-archives '$strtBckpMchn_dataslug-${strtBckpMchn_label%-*}-*'"
            
            for strtBckpMchn_repoandcmd in $strtBckpMchn_repolist; do
                strtBckpMchn_repospec=$(echo "$strtBckpMchn_repoandcmd" | cut -d',' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
                strtBckpMchn_borgremotecommand=$(echo "$strtBckpMchn_repoandcmd" | cut -d',' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')
                # FIX #50: optional third field - encryption mode for a
                # fresh "borg init" (e.g. "repokey-blake2"). Empty/absent
                # defaults to "repokey", preserving every existing config's
                # behavior unchanged.
                strtBckpMchn_encryption=$(echo "$strtBckpMchn_repoandcmd" | cut -d',' -f3 | sed 's/^[ \t]*//;s/[ \t]*$//')
                [ -z "$strtBckpMchn_encryption" ] && strtBckpMchn_encryption="repokey"

                # FIX #41: backend dispatch. A REPOLIST entry may be
                # prefixed with a backend type ("borg:", "zfssend:", or
                # "borgbase:"); no prefix defaults to "borg" so every
                # existing config keeps working unchanged.
                case "$strtBckpMchn_repospec" in
                    borg:*) strtBckpMchn_repotype="borg"; strtBckpMchn_repo="${strtBckpMchn_repospec#borg:}" ;;
                    borgbase:*) strtBckpMchn_repotype="borgbase"; strtBckpMchn_repo="${strtBckpMchn_repospec#borgbase:}" ;;
                    zfssend:*) strtBckpMchn_repotype="zfssend"; strtBckpMchn_repo="${strtBckpMchn_repospec#zfssend:}" ;;
                    *) strtBckpMchn_repotype="borg"; strtBckpMchn_repo="$strtBckpMchn_repospec" ;;
                esac

                msg "DEBUG" "Repo type is = $strtBckpMchn_repotype, target = $strtBckpMchn_repo "
                msg "DEBUG" "Borg remote command is = $strtBckpMchn_borgremotecommand "
                # now we check if the current repo has to be skipped
                # [ ] TODO #5 changing REPOSKIP from global to local variable
                if { [ "${strtBckpMchn_repo#ssh://}" != "$strtBckpMchn_repo" ] && [ "$REPOSKIP" != "REMOTE" ]; } || \
                    { [ "${strtBckpMchn_repo#ssh://}" = "$strtBckpMchn_repo" ] && [ "$REPOSKIP" != "LOCAL" ]; }; then

                    set +e
                    case "$strtBckpMchn_repotype" in
                        borg|borgbase)
                            backendBorg "$strtBckpMchn_repo" "$strtBckpMchn_borgremotecommand" "$strtBckpMchn_borglabel" "$strtBckpMchn_borgrepoopts" "$strtBckpMchn_snapmountbasedir/$strtBckpMchn_dataset" "$strtBckpMchn_pruneopts" "$strtBckpMchn_label" "$strtBckpMchn_encryption" "$strtBckpMchn_repotype"
                            ;;
                        zfssend)
                            backendZfsSend "$strtBckpMchn_repo" "$strtBckpMchn_borgremotecommand" "$strtBckpMchn_dataset" "$strtBckpMchn_label" "$strtBckpMchn_keepduration"
                            ;;
                        *)
                            die "Unknown backend type '$strtBckpMchn_repotype' for repo entry: $strtBckpMchn_repoandcmd"
                            ;;
                    esac

                fi
            done
            # FIX #41: pruneZFSSnapshot takes no repo-specific argument (its
            # 4th parameter is always empty) - it always operated purely on
            # the ZFS source side, independent of which/how many repos this
            # dataset backs up to. It used to run once per repo iteration
            # above (harmless, since it's idempotent once there's nothing
            # left to prune, but redundant and the wrong place for it once
            # repos can be different backend types). Runs once per
            # dataset/interval instead.
            msg "DEBUG" "--------------------------- PRUNE ZFS -----------------------------------"
            pruneZFSSnapshot "$strtBckpMchn_dataset" "$strtBckpMchn_label" "$strtBckpMchn_keepduration" ""
            msg "DEBUG" "--------------------------------------------------------------"
            msg "DEBUG" "Snapmount base dir: $strtBckpMchn_snapmountbasedir " 
            msg "DEBUG" "Snapmount dataset: $strtBckpMchn_dataset "
            msg "DEBUG" "--------------------------------------------------------------"
            umountZFSSnapshot "$strtBckpMchn_snapmountbasedir" "$strtBckpMchn_dataset"

            
        done
        IFS="$OLD_IFS"

        unset OLD_IFS
        unset strtBckpMchn_interval
        unset strtBckpMchn_fslist
        unset strtBckpMchn_fsentry
        unset strtBckpMchn_dataset
        unset strtBckpMchn_repo
        unset strtBckpMchn_repospec
        unset strtBckpMchn_repotype
        unset strtBckpMchn_encryption
        unset strtBckpMchn_repolist
        unset strtBckpMchn_repoandcmd
        unset strtBckpMchn_intervallist
        unset strtBckpMchn_borgrepoopts
        unset strtBckpMchn_borgpurgeopts
        unset strtBckpMchn_snapmountbasedir
        unset strtBckpMchn_label
        unset strtBckpMchn_dataslug
        unset strtBckpMchn_borglabel
        unset strtBckpMchn_pruneopts
        unset strtBckpMchn_lastsnap       
        unset strtBckpMchn_keepduration
        unset strtBckpMchn_recursive
        unset strtBckpMchn_date
        unset strtBckpMchn_dayofweek
        unset strtBckpMchn_dayofmonth
        unset strtBckpMchn_borgremotecommand
        unset strtBckpMchn_rc
    }

    

fi
