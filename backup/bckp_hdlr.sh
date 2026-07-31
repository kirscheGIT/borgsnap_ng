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

        # RESTORE_VERIFY: tracks whether ANY restore-verification check
        # failed anywhere in this run (any dataset, any repo) - checked at
        # the very end of this function to decide the final return value.
        # Unlike BORG_VERIFY (a WARNING that doesn't affect the exit
        # code), a failed restore verification is a genuine FAILURE by
        # design - it means the actual restore path is broken, which is
        # more serious than "an old archive might have a corrupted byte
        # somewhere". One repo's restore-check failing still doesn't stop
        # OTHER repos from getting their own backup/check this run (same
        # resilience philosophy as FIX #36/#57/#59) - it just means the
        # overall run is reported as failed once everything else is done.
        export RESTOREVERIFY_FAILED=""

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


        msg "INFO" "Borg exit code is set to $BORG_EXIT_CODES"
        msg "DEBUG" "------ $(date) ------"
        

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
                # Optional SNAPSHOT_TAG support: inserted as a prefix on
                # the FINAL label only ("TAG-monthly-20260730" instead of
                # "monthly-20260730") - the interval-name checks below
                # (chkDateStr-relevant, via getZFSSnapshot's LATEST
                # lookup) deliberately keep using the bare interval name
                # unchanged. getZFSSnapshot itself applies this same tag
                # internally when building its LATEST/ALL search pattern,
                # so the "does last month's snapshot already exist" check
                # below correctly finds tagged snapshots too.
                strtBckpMchn_tagprefix="${SNAPSHOT_TAG:+${SNAPSHOT_TAG}-}"
                
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
                        strtBckpMchn_label="${strtBckpMchn_tagprefix}${strtBckpMchn_label}-${strtBckpMchn_date}"
                        break
                    elif { [ -z "$strtBckpMchn_lastsnap" ] ||  [ "$strtBckpMchn_dayofweek" -eq 0 ]; } && [ "$strtBckpMchn_label" = "weekly" ]; then
                        strtBckpMchn_label="${strtBckpMchn_tagprefix}${strtBckpMchn_label}-${strtBckpMchn_date}"
                        break
                    else
                        continue
                    fi
                else
                    strtBckpMchn_label="${strtBckpMchn_tagprefix}${strtBckpMchn_label}-${strtBckpMchn_date}"
                    break
                fi


            done
            # [ ] TODO #4 Pre and post scripts for the snapshots

            # FIX #67: the bare interval name, stripped of both the date
            # suffix AND (if SNAPSHOT_TAG is set) the tag prefix that's
            # now part of $strtBckpMchn_label - needed everywhere below
            # that looks something up BY interval name (RESTORE_VERIFY/
            # BORG_VERIFY's "interval:depth" entries, borg prune's
            # --keep-X flag) rather than matching the ZFS snapshot label
            # itself. Computed once here and reused, instead of repeating
            # (and risking missing) the same stripping logic in each spot.
            strtBckpMchn_bareinterval="${strtBckpMchn_label%-*}"
            strtBckpMchn_bareinterval="${strtBckpMchn_bareinterval#"${SNAPSHOT_TAG:+${SNAPSHOT_TAG}-}"}"

            # RESTORE_VERIFY: determine on/off for today's interval, same
            # default: fallback mechanism as BORG_VERIFY. Must happen HERE
            # - before the snapshot below - because if enabled, a fresh
            # canary file needs to be written into the LIVE dataset first,
            # so it gets captured by today's snapshot.
            strtBckpMchn_restoreverify=""
            strtBckpMchn_restoreverifydefault="off"
            if [ -n "${RESTORE_VERIFY:-}" ]; then
                strtBckpMchn_rverify_OLD_IFS="$IFS"
                IFS=';'
                for strtBckpMchn_rverify_entry in $RESTORE_VERIFY; do
                    IFS=' '
                    case "$strtBckpMchn_rverify_entry" in
                        "${strtBckpMchn_bareinterval}:"*)
                            strtBckpMchn_restoreverify="${strtBckpMchn_rverify_entry#*:}"
                            ;;
                        "default:"*)
                            strtBckpMchn_restoreverifydefault="${strtBckpMchn_rverify_entry#*:}"
                            ;;
                    esac
                    IFS=';'
                done
                IFS="$strtBckpMchn_rverify_OLD_IFS"
                unset strtBckpMchn_rverify_OLD_IFS
                unset strtBckpMchn_rverify_entry
            fi
            if [ -z "$strtBckpMchn_restoreverify" ]; then
                strtBckpMchn_restoreverify="$strtBckpMchn_restoreverifydefault"
            fi
            unset strtBckpMchn_restoreverifydefault

            export RESTOREVERIFY_ACTIVE="off"
            export RESTOREVERIFY_CANARY_HASH=""
            # Path of the canary file exactly as it will appear inside a
            # borg archive: borg records paths as given at creation time
            # (the mounted snapshot dir, e.g. "/run/borgsnap/<dataset>"),
            # with the leading "/" stripped by convention.
            export RESTOREVERIFY_CANARY_ARCHIVEPATH=""
            # Path of the canary file relative to the dataset root, used
            # by the zfssend-side check (which mounts the target's own
            # snapshot directly, not an archive).
            export RESTOREVERIFY_CANARY_RELPATH=".borgsnap_ng_canary"

            if [ "$strtBckpMchn_restoreverify" = "on" ]; then
                strtBckpMchn_canary_mountpoint=$(zfs get -H -o value mountpoint "$strtBckpMchn_dataset" 2>/dev/null)
                if [ "$strtBckpMchn_canary_mountpoint" = "none" ] || [ "$strtBckpMchn_canary_mountpoint" = "legacy" ] || [ -z "$strtBckpMchn_canary_mountpoint" ]; then
                    msg "WARNING" "restore verification: dataset '$strtBckpMchn_dataset' has no conventional mountpoint (mountpoint=$strtBckpMchn_canary_mountpoint) - cannot write a canary file there, skipping restore verification for this dataset this run"
                else
                    strtBckpMchn_canaryfile="$strtBckpMchn_canary_mountpoint/.borgsnap_ng_canary"
                    # Fresh content every single run (not just a touch) -
                    # this proves TODAY's run actually captured and can
                    # restore genuinely new data, not just that some
                    # long-unchanged file from months ago still happens to
                    # be readable.
                    strtBckpMchn_canarycontent="borgsnap_ng restore-verification canary - $(date '+%Y-%m-%d %H:%M:%S') - pid $$ - dataset $strtBckpMchn_dataset"
                    if echo "$strtBckpMchn_canarycontent" > "$strtBckpMchn_canaryfile" 2>/dev/null; then
                        RESTOREVERIFY_CANARY_HASH=$(sha256sum "$strtBckpMchn_canaryfile" 2>/dev/null | cut -d' ' -f1)
                        RESTOREVERIFY_CANARY_ARCHIVEPATH="run/borgsnap/$strtBckpMchn_dataset/.borgsnap_ng_canary"
                        RESTOREVERIFY_ACTIVE="on"
                    else
                        # FIX: writing this one file requires the
                        # executing user to have write access to it -
                        # unlike everything else in this project's
                        # least-privilege setup, which only ever needs
                        # read access to the data being backed up. This is
                        # a deliberate, narrow, and unavoidable exception
                        # (see sample.conf's RESTORE_VERIFY documentation)
                        # - not something the script can grant itself if
                        # it isn't already there.
                        msg "WARNING" "restore verification: could not write canary file '$strtBckpMchn_canaryfile' (permission denied?) - the executing user needs write access to this one file specifically for restore verification to work. Skipping restore verification for this dataset this run."
                    fi
                    unset strtBckpMchn_canaryfile
                    unset strtBckpMchn_canarycontent
                fi
                unset strtBckpMchn_canary_mountpoint
            fi
            unset strtBckpMchn_restoreverify

            snapshotZFS "$strtBckpMchn_dataset" "$strtBckpMchn_label" "$strtBckpMchn_recursive"
            strtBckpMchn_snapreused=$?
            if [ "$strtBckpMchn_snapreused" -ne 0 ] && [ "${RESTOREVERIFY_ACTIVE:-off}" = "on" ]; then
                # FIX #64: the snapshot for today's label already existed
                # and was reused (see snapshotZFS's own WARNING above) -
                # the canary content written just above is for a fresh
                # snapshot that never happened this run, so it was never
                # actually captured anywhere. Comparing against a reused,
                # stale snapshot would always mismatch and misreport a
                # harmless non-event as "the restore path may be
                # corrupting data" - skip the comparison entirely instead.
                msg "INFO" "restore verification: today's snapshot was reused from an earlier run rather than freshly taken (see the warning above) - the canary written this run was never captured, skipping restore verification for this dataset this run"
                RESTOREVERIFY_ACTIVE="off"
            fi
            unset strtBckpMchn_snapreused
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
            # FIX #67: --keep-X only recognizes the fixed flag names
            # --keep-monthly/--keep-weekly/--keep-daily - with a
            # SNAPSHOT_TAG set, $strtBckpMchn_label is "TAG-monthly-DATE",
            # and stripping just the date (as --glob-archives still does,
            # correctly) left "TAG-monthly" here, which borg rejected as
            # an unrecognized argument. $strtBckpMchn_bareinterval (see
            # above, right after the interval-selection loop) is the tag-
            # and date-stripped interval name, used for exactly this.
            # --glob-archives is unaffected since it's plain glob string
            # matching, not a restricted vocabulary, and keeping the tag
            # there is actually more precise (scopes pruning to just this
            # tool's own tagged archives).
            strtBckpMchn_pruneopts="$strtBckpMchn_borgpurgeopts --keep-${strtBckpMchn_bareinterval}=$strtBckpMchn_keepduration --glob-archives '$strtBckpMchn_dataslug-${strtBckpMchn_label%-*}-*'"

            # BORG_VERIFY: look up this interval's configured "borg check"
            # depth once, here - not per repo below, since it depends only
            # on the interval (e.g. "monthly"), not on which repo is being
            # backed up to. An exact interval match always wins; a
            # "default:" entry (if present) is the fallback for any
            # interval that isn't listed explicitly - without this, adding
            # a new interval to RETENTIONPERIOD (e.g. "hourly") without
            # also remembering to update BORG_VERIFY would silently turn
            # verification off for it, with no warning at all. Falls back
            # to "off" only if BORG_VERIFY is unset entirely, or has
            # neither an exact match nor a "default:" entry.
            strtBckpMchn_verifydepth=""
            strtBckpMchn_verifydefault="off"
            if [ -n "${BORG_VERIFY:-}" ]; then
                strtBckpMchn_verify_OLD_IFS="$IFS"
                IFS=';'
                for strtBckpMchn_verify_entry in $BORG_VERIFY; do
                    IFS=' '
                    case "$strtBckpMchn_verify_entry" in
                        "${strtBckpMchn_bareinterval}:"*)
                            strtBckpMchn_verifydepth="${strtBckpMchn_verify_entry#*:}"
                            ;;
                        "default:"*)
                            strtBckpMchn_verifydefault="${strtBckpMchn_verify_entry#*:}"
                            ;;
                    esac
                    IFS=';'
                done
                IFS="$strtBckpMchn_verify_OLD_IFS"
                unset strtBckpMchn_verify_OLD_IFS
                unset strtBckpMchn_verify_entry
            fi
            if [ -z "$strtBckpMchn_verifydepth" ]; then
                strtBckpMchn_verifydepth="$strtBckpMchn_verifydefault"
            fi
            unset strtBckpMchn_verifydefault

            for strtBckpMchn_repoandcmd in $strtBckpMchn_repolist; do
                strtBckpMchn_repospec=$(echo "$strtBckpMchn_repoandcmd" | cut -d',' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace

                # FIX #61: a trailing separator in REPOLIST (e.g.
                # "...;repo3, ; " with nothing after the last ";") produces a phantom
                # entry that's empty once trimmed - skip it silently
                # instead of falling through to the default "borg" case
                # below with a blank repo path, which produced confusing
                # "Empty directory string was given!"/"repo ''" errors
                # for something that was never a real, intended entry.
                if [ -z "$strtBckpMchn_repospec" ]; then
                    continue
                fi

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
                            backendBorg "$strtBckpMchn_repo" "$strtBckpMchn_borgremotecommand" "$strtBckpMchn_borglabel" "$strtBckpMchn_borgrepoopts" "$strtBckpMchn_snapmountbasedir/$strtBckpMchn_dataset" "$strtBckpMchn_pruneopts" "$strtBckpMchn_label" "$strtBckpMchn_encryption" "$strtBckpMchn_repotype" "$strtBckpMchn_verifydepth"
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
            # FIX #55: unmount BEFORE pruning, not after. pruneZFSSnapshot
            # destroys old source snapshots by name/interval match alone -
            # it has no dependency on anything being mounted. With the
            # unmount happening afterward (the old order), a destroy that
            # happens to target a snapshot still mounted from earlier in
            # THIS SAME run (e.g. today's own snapshot, if retention's
            # keep-count logic ever selects it) fails outright with
            # "dataset is busy", since nothing has unmounted it yet at
            # that point. Unmounting first removes the possibility
            # entirely - by the time pruning runs, nothing this run
            # mounted is still in the way.
            msg "DEBUG" "--------------------------------------------------------------"
            msg "DEBUG" "Snapmount base dir: $strtBckpMchn_snapmountbasedir " 
            msg "DEBUG" "Snapmount dataset: $strtBckpMchn_dataset "
            msg "DEBUG" "--------------------------------------------------------------"
            umountZFSSnapshot "$strtBckpMchn_snapmountbasedir" "$strtBckpMchn_dataset"

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
        unset strtBckpMchn_bareinterval
        unset strtBckpMchn_dataslug
        unset strtBckpMchn_borglabel
        unset strtBckpMchn_pruneopts
        unset strtBckpMchn_verifydepth
        unset strtBckpMchn_lastsnap       
        unset strtBckpMchn_keepduration
        unset strtBckpMchn_tagprefix
        unset strtBckpMchn_recursive
        unset strtBckpMchn_date
        unset strtBckpMchn_dayofweek
        unset strtBckpMchn_dayofmonth
        unset strtBckpMchn_borgremotecommand
        unset strtBckpMchn_rc

        # RESTORE_VERIFY: a failed restore-verification anywhere this run
        # makes the whole run report as failed, even though everything
        # else (snapshots, borg/zfssend backups, BORG_VERIFY checks)
        # completed normally - see the comment where RESTOREVERIFY_FAILED
        # is initialized above for why this is treated as a genuine
        # failure rather than a warning.
        if [ -n "$RESTOREVERIFY_FAILED" ]; then
            unset RESTOREVERIFY_FAILED
            unset RESTOREVERIFY_ACTIVE
            unset RESTOREVERIFY_CANARY_HASH
            unset RESTOREVERIFY_CANARY_ARCHIVEPATH
            unset RESTOREVERIFY_CANARY_RELPATH
            return 1
        fi
        unset RESTOREVERIFY_FAILED
        unset RESTOREVERIFY_ACTIVE
        unset RESTOREVERIFY_CANARY_HASH
        unset RESTOREVERIFY_CANARY_ARCHIVEPATH
        unset RESTOREVERIFY_CANARY_RELPATH
        return 0
    }

    

fi
