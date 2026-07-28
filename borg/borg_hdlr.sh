#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${BORG_HDLR_SOURCED+x}" ]; then
    export BORG_HDLR_SOURCED=1  
    
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
    msg "DEBUG" "-----------------------------------------------"
    msg "DEBUG" "sourced borg_hdlr.sh"
    msg "DEBUG" "-----------------------------------------------"
    
   
    
    initBorg(){
        # $1 - mandatory list of repo paths
        # $2 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!
        # $3 - optional - encryption mode for "borg init --encryption=..."
        #      (default: repokey, preserving prior hardcoded behavior)
        # Returns 0 if every repo in the list was successfully
        # initialized, nonzero if any failed - see the FIX #57 comment
        # below for why the caller needs to know this.

        initBorg_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="initBorg"
        initBorg_OLD_IFS="$IFS"
        IFS=' '
        initBorg_pathlist="$1"
        initBorg_borgpath="$2"
        initBorg_encryption="${3:-repokey}"
        
        initBorg_remotepath=""
        initBorg_cmdline=""
        initBorg_failed=0 # noqa:unset - this IS the return value, see exec_cmd's lexit_status for the same pattern

        if [ -n "$initBorg_borgpath" ]; then
            msg "DEBUG" "borgpath set"
            initBorg_remotepath="--remote-path=${initBorg_borgpath}"
        else
            msg "DEBUG" "borgpath not set - default to borg"
            initBorg_remotepath="--remote-path=borg"
        fi

        for i in $initBorg_pathlist; do
            msg "DEBUG" "Init Borg path is: $i "
            if [ "${i#ssh://}" != "$i" ]; then
                msg "DEBUG" "Initialize Remote path"
                initBorg_cmdline="borg init --encryption=$initBorg_encryption --show-rc "$initBorg_remotepath" "$i""
                msg "DEBUG" "Init Borg cmdline is $initBorg_cmdline"
                exec_cmd eval "$initBorg_cmdline"  
            else
                exec_cmd borg init --encryption="$initBorg_encryption" --show-rc "$i"  
            fi
            initBorg_rc=$?
            if [ "$initBorg_rc" -ne 0 ]; then
                # FIX #57: exec_cmd intentionally skips err_hdlr when
                # LASTFUNC=="initBorg" (mirroring the FIX #36 carve-out
                # for createBorg) - a single repo failing to initialize
                # (transient network hiccup, unreachable remote, etc.)
                # must not abort backups to every OTHER configured repo.
                # Surface it loudly, continue this loop, and report
                # failure via our own return value - backendBorg checks
                # that and skips create/prune/check for just this one
                # repo, letting the dispatch loop move on to the next
                # configured repo as originally intended.
                msg "ERROR" "borg init failed (exit $initBorg_rc) for repo $i - skipping this repo, continuing with remaining repos"
                initBorg_failed=1 # noqa:unset - see the initial assignment above
            fi
        done
        LASTFUNC="$initBorg_CALLINGFUCNTION"
        unset initBorg_CALLINGFUCNTION
        IFS="$initBorg_OLD_IFS"
        unset initBorg_OLD_IFS
        unset initBorg_cmdline
        unset initBorg_borgpath
        unset initBorg_remotepath
        unset initBorg_pathlist
        unset initBorg_encryption
        unset initBorg_rc
        return "$initBorg_failed"
    }

    createBorg(){
        # $1 - mandatory list of repo paths
        # $2 - mandatory label of the backup
        # $3 - mandatory borg options like compression etc. 
        #      valid for all repos in the list
        # $4 - backup source path 
        # $5 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!

        crtBorg_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="createBorg"
        crtBorg_msglevel="$MSG_LEVEL"
        MSG_LEVEL=5
        crtBorg_OLD_IFS="$IFS"
        IFS=' '
        crtBorg_pathlist="$1"
        crtBorg_backuplabel="$2"
        crtBorg_borgopts="$3"
        crtBorg_srcpath="$4"
        crtBorg_borgpath="$5"
        crtBorg_remotepath=""
        crtBorg_cmdline=""

        if [ -n "$crtBorg_borgpath" ]; then
            msg "DEBUG" "borgpath set"
            crtBorg_remotepath="--remote-path=${crtBorg_borgpath}"
        else
            msg "DEBUG" "borgpath not set - default to borg"
            crtBorg_remotepath="--remote-path=borg"
        fi
        if [ -d $crtBorg_srcpath ]; then
            for crtBorg_i in $crtBorg_pathlist; do
                if [ "${crtBorg_i#ssh://}" != "$crtBorg_i" ]; then
                    # FIX #32 (resolved 2025-01-12): source path construction
                    # for the remote (ssh://) branch was wrong at the time
                    # this comment was originally written - already fixed
                    # since, this note was just never cleaned up.
                    crtBorg_cmdline="borg create $crtBorg_borgopts $crtBorg_remotepath ${crtBorg_i}::${crtBorg_backuplabel} $crtBorg_srcpath"
                else 
                    crtBorg_cmdline="borg create $crtBorg_borgopts ${crtBorg_i}::${crtBorg_backuplabel} $crtBorg_srcpath"
                fi
                msg "DEBUG" "Borg create cmdline: $crtBorg_cmdline"
                exec_cmd eval "$crtBorg_cmdline"
                crtBorg_rc=$?
                if [ "$crtBorg_rc" -ne 0 ]; then
                    # FIX #36: exec_cmd intentionally skips err_hdlr when
                    # LASTFUNC=="createBorg" (see FIX #11), so one repo
                    # failing (e.g. rsync.net being unreachable) doesn't
                    # abort backups to the other configured repos. Until
                    # now that made the failure completely silent outside
                    # DEBUG mode - surface it instead, then continue with
                    # the remaining repos as originally intended.
                    msg "ERROR" "borg create failed (exit $crtBorg_rc) for repo $crtBorg_i, dataset $crtBorg_srcpath - continuing with remaining repos"
                fi
            done
        else
            MSG_LEVEL=$crtBorg_msglevel
            IFS="$crtBorg_OLD_IFS"
            unset crtBorg_OLD_IFS
            unset crtBorg_msglevel
            unset crtBorg_cmdline
            unset crtBorg_i
            unset crtBorg_pathlist
            unset crtBorg_backuplabel
            unset crtBorg_borgopts
            unset crtBorg_borgpath
            unset crtBorg_srcpath
            unset crtBorg_remotepath
            unset crtBorg_rc
            msg "ERROR" "Source directory doesn't exist - terminate excution"
            err_hdlr "1"
            return 1
        fi
        MSG_LEVEL=$crtBorg_msglevel
        IFS="$crtBorg_OLD_IFS"
        unset crtBorg_OLD_IFS
        LASTFUNC="$crtBorg_CALLINGFUCNTION"
        unset crtBorg_CALLINGFUCNTION
        unset crtBorg_msglevel
        unset crtBorg_cmdline
        unset crtBorg_i
        unset crtBorg_pathlist
        unset crtBorg_backuplabel
        unset crtBorg_borgopts
        unset crtBorg_borgpath
        unset crtBorg_srcpath
        unset crtBorg_remotepath
        unset crtBorg_rc
        return 0

    }

    pruneBorg(){
        # $1 - mandatory list of repo paths
        # $2 - mandatory borg options like compression etc. 
        #      valid for all repos in the list
        # $3 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!
        pruneBorg_CALLINGFUCNTION="$LASTFUNC"
        # FIX #11: was "createBorg" (copy-paste), which triggered exec_cmd's
        # createBorg special case and silently swallowed all prune errors.
        LASTFUNC="pruneBorg"
        pruneBorg_OLD_IFS="$IFS"
        IFS=' '
        pruneBorg_pathlist="$1"
        pruneBorg_borgopts="$2"
        pruneBorg_compactlabel="$3"
        pruneBorg_borgpath="$4"
        pruneBorg_remotepath=""
        pruneBorg_cmdline=""

        if [ -n "$pruneBorg_borgpath" ]; then
            msg "DEBUG" "borgpath set"
            pruneBorg_remotepath="--remote-path=${pruneBorg_borgpath}"
        else
            msg "DEBUG" "borgpath not set - default to borg"
            pruneBorg_remotepath="--remote-path=borg"
        fi

        # [ ] TODO: #34 Check if statements - could be simplified I guess @kirscheGIT
        for pruneBorg_i in $pruneBorg_pathlist; do
            if [ "${pruneBorg_i#ssh://}" != "$pruneBorg_i" ]; then
                
                pruneBorg_cmdline="borg prune $pruneBorg_borgopts $pruneBorg_remotepath ${pruneBorg_i}"
                #exec_cmd borg prune "$pruneBorg_borgopts" "$pruneBorg_remotepath" "${pruneBorg_i}"
                exec_cmd eval $pruneBorg_cmdline
                if [ "$pruneBorg_compactlabel" = "monthly" ]; then
                    pruneBorg_cmdline="borg compact ${pruneBorg_i}"
                    exec_cmd eval $pruneBorg_cmdline
                fi  
                #set -e
            else 
                pruneBorg_cmdline="borg prune $pruneBorg_borgopts ${pruneBorg_i}"
                #exec_cmd borg prune "$pruneBorg_borgopts" "${pruneBorg_i}"
                exec_cmd eval $pruneBorg_cmdline
                if [ "$pruneBorg_compactlabel" = "monthly" ]; then
                    pruneBorg_cmdline="borg compact ${pruneBorg_i}"
                    #exec_cmd borg compact "${pruneBorg_i}"
                    exec_cmd eval $pruneBorg_cmdline
                fi    
                #set -e
            fi
        done
        LASTFUNC="$pruneBorg_CALLINGFUCNTION"
        unset pruneBorg_CALLINGFUCNTION
        IFS="$pruneBorg_OLD_IFS"
        unset pruneBorg_OLD_IFS        
        unset pruneBorg_cmdline
        unset pruneBorg_i
        unset pruneBorg_pathlist
        unset pruneBorg_borgopts
        unset pruneBorg_compactlabel
        unset pruneBorg_borgpath
        unset pruneBorg_remotepath
        return 0
    }

    ensureBorgBaseInit(){
        # FIX #50: BorgBase (and any similarly locked-down "borg repo
        # hosting" provider) forces every SSH login to run "borg serve"
        # regardless of what command is actually sent - so direxists'/
        # dircreate's shell commands (ls, mkdir) never reach a real shell
        # at all; they get swallowed as bogus arguments to borg itself
        # (visible as "borg: error: argument <command>: invalid choice").
        # There is also no mkdir equivalent: BorgBase repos are created
        # exactly once via their web UI, one fixed path per account - we
        # can never create a new one, only detect whether the existing one
        # has been borg-init'd yet.
        #
        # borg list's own exit code (stable, documented at
        # https://borgbackup.readthedocs.io/en/stable/internals/frontends.html#message-ids)
        # tells us exactly that, without needing any shell access at all:
        #   0  - already a valid, initialized repo - nothing to do
        #   15 - Repository.InvalidRepository: the path exists (BorgBase
        #        created the slot) but isn't borg-init'd yet - this is the
        #        normal state of a freshly-created BorgBase repo
        #   13 - Repository.DoesNotExist: genuinely the wrong path - since
        #        we can't create one, this is a real configuration error
        #   anything else - a real, unexpected error
        #
        # Note: rc 15 for *remote* repos specifically requires a client
        # (not server) borg version >= 1.4.1 - see
        # https://github.com/borgbackup/borg/issues/8631. Older clients
        # get a generic rc 2 instead, which this function will (correctly)
        # treat as "unexpected error" rather than silently misinterpreting
        # it as "needs init".
        #
        # $1 - mandatory repo path (ssh://...)
        # $2 - optional borg remote command
        # $3 - optional encryption mode for a fresh init (default: repokey)
        ensureBorgBaseInit_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="ensureBorgBaseInit"
        ensureBorgBaseInit_repo="$1"
        ensureBorgBaseInit_remotecmd="$2"
        ensureBorgBaseInit_encryption="${3:-repokey}"

        if [ -n "$ensureBorgBaseInit_remotecmd" ]; then
            ensureBorgBaseInit_remotepath="--remote-path=${ensureBorgBaseInit_remotecmd}"
        else
            ensureBorgBaseInit_remotepath="--remote-path=borg"
        fi

        ensureBorgBaseInit_listcmd="borg list $ensureBorgBaseInit_remotepath \"$ensureBorgBaseInit_repo\""
        msg "DEBUG" "borgbase repo state check: $ensureBorgBaseInit_listcmd"
        eval "$ensureBorgBaseInit_listcmd"
        ensureBorgBaseInit_listrc=$?
        msg "DEBUG" "borgbase repo state check exit code: $ensureBorgBaseInit_listrc"

        case "$ensureBorgBaseInit_listrc" in
            0)
                msg "DEBUG" "borgbase repo '$ensureBorgBaseInit_repo' already initialized"
                ;;
            15)
                msg "INFO" "borgbase repo '$ensureBorgBaseInit_repo' exists but is not yet initialized - running borg init"
                initBorg "$ensureBorgBaseInit_repo" "$ensureBorgBaseInit_remotecmd" "$ensureBorgBaseInit_encryption"
                ;;
            13)
                unset ensureBorgBaseInit_CALLINGFUCNTION
                unset ensureBorgBaseInit_remotecmd
                unset ensureBorgBaseInit_encryption
                unset ensureBorgBaseInit_remotepath
                unset ensureBorgBaseInit_listcmd
                unset ensureBorgBaseInit_listrc
                die "borgbase repo '$ensureBorgBaseInit_repo' does not exist. BorgBase repos must be created via their web UI first - filesystem operations (mkdir etc.) aren't possible over their restricted SSH access, so this can't be created automatically. Check the path and that the repo exists in your BorgBase dashboard."
                ;;
            *)
                unset ensureBorgBaseInit_CALLINGFUCNTION
                unset ensureBorgBaseInit_remotecmd
                unset ensureBorgBaseInit_encryption
                unset ensureBorgBaseInit_remotepath
                unset ensureBorgBaseInit_listcmd
                die "borgbase repo check failed unexpectedly (borg list exit $ensureBorgBaseInit_listrc) for '$ensureBorgBaseInit_repo' - see the borg output above for details. If this is rc 2, double check your client's borg version supports modern remote exit codes (>= 1.4.1, see FIX #50's comments)."
                ;;
        esac

        LASTFUNC="$ensureBorgBaseInit_CALLINGFUCNTION"
        unset ensureBorgBaseInit_CALLINGFUCNTION
        unset ensureBorgBaseInit_repo
        unset ensureBorgBaseInit_remotecmd
        unset ensureBorgBaseInit_encryption
        unset ensureBorgBaseInit_remotepath
        unset ensureBorgBaseInit_listcmd
        unset ensureBorgBaseInit_listrc
        return 0
    }

    checkBorg(){
        # BORG_VERIFY: runs "borg check" at a configurable depth after
        # pruning, so a corrupted/unrestorable repo is caught proactively
        # instead of discovered during an actual disaster recovery attempt.
        # $1 - mandatory repo path
        # $2 - optional borg remote command
        # $3 - mandatory verify depth: "off" (no-op), "repo"
        #      (--repository-only, cheapest - runs server-side for ssh://
        #      repos), "archive" (--archives-only, archive metadata, no
        #      file data read), or "data" (--verify-data, full
        #      cryptographic verification of all backed-up data - by far
        #      the most thorough, and the most expensive).
        checkBorg_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="checkBorg"
        checkBorg_repo="$1"
        checkBorg_remotecmd="$2"
        checkBorg_depth="$3"

        if [ -z "$checkBorg_depth" ] || [ "$checkBorg_depth" = "off" ]; then
            LASTFUNC="$checkBorg_CALLINGFUCNTION"
            unset checkBorg_CALLINGFUCNTION
            unset checkBorg_repo
            unset checkBorg_remotecmd
            unset checkBorg_depth
            return 0
        fi

        case "$checkBorg_depth" in
            repo) checkBorg_flags="--repository-only" ;;
            archive) checkBorg_flags="--archives-only" ;;
            data) checkBorg_flags="--verify-data" ;;
            *)
                msg "WARNING" "checkBorg: unknown verify depth '$checkBorg_depth' for repo '$checkBorg_repo' - skipping verification this run"
                LASTFUNC="$checkBorg_CALLINGFUCNTION"
                unset checkBorg_CALLINGFUCNTION
                unset checkBorg_repo
                unset checkBorg_remotecmd
                unset checkBorg_depth
                return 0
                ;;
        esac

        if [ -n "$checkBorg_remotecmd" ]; then
            checkBorg_remotepath="--remote-path=${checkBorg_remotecmd}"
        else
            checkBorg_remotepath="--remote-path=borg"
        fi

        msg "DEBUG" "--------------------------- CHECK BORG (depth: $checkBorg_depth) -----------------------------------"
        msg "DEBUG" "Repo is: $checkBorg_repo "

        if [ "${checkBorg_repo#ssh://}" != "$checkBorg_repo" ]; then
            checkBorg_cmdline="borg check $checkBorg_flags --show-rc $checkBorg_remotepath $checkBorg_repo"
        else
            checkBorg_cmdline="borg check $checkBorg_flags --show-rc $checkBorg_repo"
        fi
        msg "DEBUG" "Borg check cmdline: $checkBorg_cmdline"

        # Deliberately not exec_cmd/die on failure: a check finding a
        # problem is serious, but doesn't mean TODAY's backup itself is
        # bad - an OLDER archive could be the corrupted one. Aborting the
        # whole run over this would be disruptive for something that's
        # rarely urgently actionable mid-run. A WARNING is enough to get
        # picked up by FIX #48's mail escalation automatically (elevated
        # priority, surfaced at the top of the notification) - no new
        # mechanism needed.
        eval "$checkBorg_cmdline"
        checkBorg_rc=$?
        if [ "$checkBorg_rc" -ne 0 ]; then
            msg "WARNING" "borg check found a problem in repo '$checkBorg_repo' (depth: $checkBorg_depth, exit $checkBorg_rc) - see the check output above for details. This does not necessarily mean today's archive is affected; investigate before relying on this repo for a restore."
        else
            msg "INFO" "borg check (depth: $checkBorg_depth) passed for repo '$checkBorg_repo'"
        fi

        LASTFUNC="$checkBorg_CALLINGFUCNTION"
        unset checkBorg_CALLINGFUCNTION
        unset checkBorg_repo
        unset checkBorg_remotecmd
        unset checkBorg_depth
        unset checkBorg_remotepath
        unset checkBorg_cmdline
        unset checkBorg_flags
        unset checkBorg_rc
        return 0
    }

    checkRestoreBorg(){
        # RESTORE_VERIFY: proves the actual RESTORE PATH works
        # (extraction, decryption, permissions) - something BORG_VERIFY's
        # --verify-data can never show, since it only proves the stored
        # bytes are intact, not that getting them back out actually
        # works. Reads back the canary file startBackupMachine wrote into
        # the live dataset (and therefore into THIS run's own snapshot,
        # and therefore into the archive just created) and compares its
        # hash - a mismatch means the restore path is broken for this
        # specific repo, which is a genuine FAILURE, not a warning (see
        # the RESTOREVERIFY_FAILED comment in bckp_hdlr.sh for why).
        #
        # $1 - mandatory repo path
        # $2 - optional borg remote command
        # $3 - mandatory archive name (this run's own archive - not
        #      "latest", so this checks exactly what was just backed up)
        checkRestoreBorg_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="checkRestoreBorg"
        checkRestoreBorg_repo="$1"
        checkRestoreBorg_remotecmd="$2"
        checkRestoreBorg_archive="$3"

        if [ "${RESTOREVERIFY_ACTIVE:-off}" != "on" ]; then
            LASTFUNC="$checkRestoreBorg_CALLINGFUCNTION"
            unset checkRestoreBorg_CALLINGFUCNTION
            unset checkRestoreBorg_repo
            unset checkRestoreBorg_remotecmd
            unset checkRestoreBorg_archive
            return 0
        fi

        if [ -n "$checkRestoreBorg_remotecmd" ]; then
            checkRestoreBorg_remotepath="--remote-path=${checkRestoreBorg_remotecmd}"
        else
            checkRestoreBorg_remotepath="--remote-path=borg"
        fi

        msg "DEBUG" "--------------------------- CHECK RESTORE (borg) -----------------------------------"
        msg "DEBUG" "Repo is: $checkRestoreBorg_repo, archive: $checkRestoreBorg_archive"

        if [ "${checkRestoreBorg_repo#ssh://}" != "$checkRestoreBorg_repo" ]; then
            checkRestoreBorg_cmdline="borg extract --stdout $checkRestoreBorg_remotepath \"${checkRestoreBorg_repo}::${checkRestoreBorg_archive}\" \"$RESTOREVERIFY_CANARY_ARCHIVEPATH\""
        else
            checkRestoreBorg_cmdline="borg extract --stdout \"${checkRestoreBorg_repo}::${checkRestoreBorg_archive}\" \"$RESTOREVERIFY_CANARY_ARCHIVEPATH\""
        fi
        msg "DEBUG" "Restore-check cmdline: $checkRestoreBorg_cmdline"

        checkRestoreBorg_scratchfile=$(mktemp)
        eval "$checkRestoreBorg_cmdline" > "$checkRestoreBorg_scratchfile" 2>/dev/null
        checkRestoreBorg_extractrc=$?

        if [ "$checkRestoreBorg_extractrc" -ne 0 ]; then
            msg "ERROR" "restore verification FAILED for repo '$checkRestoreBorg_repo' (archive $checkRestoreBorg_archive) - could not extract the canary file (exit $checkRestoreBorg_extractrc). The restore path itself may be broken for this repo."
            RESTOREVERIFY_FAILED=1
        else
            checkRestoreBorg_actualhash=$(sha256sum "$checkRestoreBorg_scratchfile" 2>/dev/null | cut -d' ' -f1)
            if [ "$checkRestoreBorg_actualhash" != "$RESTOREVERIFY_CANARY_HASH" ]; then
                msg "ERROR" "restore verification FAILED for repo '$checkRestoreBorg_repo' (archive $checkRestoreBorg_archive) - canary content mismatch after extraction (expected $RESTOREVERIFY_CANARY_HASH, got $checkRestoreBorg_actualhash). The restore path may be corrupting or truncating data."
                RESTOREVERIFY_FAILED=1
            else
                msg "INFO" "restore verification passed for repo '$checkRestoreBorg_repo' (archive $checkRestoreBorg_archive)"
            fi
            unset checkRestoreBorg_actualhash
        fi
        rm -f "$checkRestoreBorg_scratchfile"
        unset checkRestoreBorg_scratchfile
        unset checkRestoreBorg_extractrc

        LASTFUNC="$checkRestoreBorg_CALLINGFUCNTION"
        unset checkRestoreBorg_CALLINGFUCNTION
        unset checkRestoreBorg_repo
        unset checkRestoreBorg_remotecmd
        unset checkRestoreBorg_archive
        unset checkRestoreBorg_remotepath
        unset checkRestoreBorg_cmdline
        return 0
    }

    checkRepoCapacity(){
        # $1 - mandatory repo path
        # Reports the repo's filesystem fill level (used/available/
        # percent) after backup - INFO normally, WARNING if it's at or
        # above the optional CAPACITY_WARN_PERCENT threshold. Best-effort
        # for remote (ssh://) repos: some providers' restricted shells
        # (see FIX #50's BorgBase discussion) may not support "df" at
        # all - this degrades gracefully to a DEBUG-level skip note
        # rather than treating that as an error.
        checkRepoCapacity_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="checkRepoCapacity"
        checkRepoCapacity_repo="$1"
        checkRepoCapacity_host=""
        checkRepoCapacity_path=""

        if [ "${checkRepoCapacity_repo#ssh://}" != "$checkRepoCapacity_repo" ]; then
            checkRepoCapacity_host="${checkRepoCapacity_repo#ssh://}"
            checkRepoCapacity_host="${checkRepoCapacity_host%%/*}"
            checkRepoCapacity_path="${checkRepoCapacity_repo#ssh://*/}"
            checkRepoCapacity_dfline=$(ssh "$checkRepoCapacity_host" df -Pk "$checkRepoCapacity_path" 2>/dev/null | tail -1)
        else
            checkRepoCapacity_dfline=$(df -Pk "$checkRepoCapacity_repo" 2>/dev/null | tail -1)
        fi

        if [ -n "$checkRepoCapacity_dfline" ]; then
            checkRepoCapacity_pct=$(printf '%s\n' "$checkRepoCapacity_dfline" | awk '{print $5}' | tr -d '%')
            checkRepoCapacity_avail=$(printf '%s\n' "$checkRepoCapacity_dfline" | awk '{print $4}')
            case "$checkRepoCapacity_pct" in
                ''|*[!0-9]*)
                    msg "DEBUG" "checkRepoCapacity: could not parse 'df' output for repo '$checkRepoCapacity_repo' - skipping capacity check this run"
                    ;;
                *)
                    checkRepoCapacity_availhuman=$(awk -v kb="$checkRepoCapacity_avail" 'BEGIN{if(kb>=1073741824)printf "%.1f TB",kb/1073741824;else if(kb>=1048576)printf "%.1f GB",kb/1048576;else if(kb>=1024)printf "%.1f MB",kb/1024;else printf "%d KB",kb}')
                    if [ -n "${CAPACITY_WARN_PERCENT:-}" ] && [ "$checkRepoCapacity_pct" -ge "$CAPACITY_WARN_PERCENT" ]; then
                        msg "WARNING" "repo '$checkRepoCapacity_repo' is ${checkRepoCapacity_pct}% full ($checkRepoCapacity_availhuman free) - at or above the configured CAPACITY_WARN_PERCENT=$CAPACITY_WARN_PERCENT"
                    else
                        msg "INFO" "repo '$checkRepoCapacity_repo' fill level: ${checkRepoCapacity_pct}% used, $checkRepoCapacity_availhuman free"
                    fi
                    unset checkRepoCapacity_availhuman
                    ;;
            esac
            unset checkRepoCapacity_pct
            unset checkRepoCapacity_avail
        else
            msg "DEBUG" "checkRepoCapacity: 'df' produced no output for repo '$checkRepoCapacity_repo' (a remote provider's restricted shell may not support it) - capacity check skipped"
        fi

        unset checkRepoCapacity_dfline
        unset checkRepoCapacity_host
        unset checkRepoCapacity_path
        LASTFUNC="$checkRepoCapacity_CALLINGFUCNTION"
        unset checkRepoCapacity_CALLINGFUCNTION
        unset checkRepoCapacity_repo
        return 0
    }

    backendBorg(){
        # FIX #41: backend wrapper called from startBackupMachine's repo
        # dispatch (see backup/bckp_hdlr.sh). Bundles the existing
        # init-if-needed / create / prune sequence behind one call, so the
        # dispatch itself doesn't need to know borg-specific details.
        # $1 - mandatory repo path
        # $2 - optional borg remote command
        # $3 - mandatory archive label (dataset-qualified, see FIX #33)
        # $4 - mandatory borg create options
        # $5 - mandatory source path (mounted snapshot directory)
        # $6 - mandatory prune options string (see FIX #1/#4/#33)
        # $7 - mandatory interval label (e.g. "monthly-20260719"; pruneBorg
        #      uses its prefix to decide whether to also run borg compact)
        # $8 - optional encryption mode for a fresh init (default: repokey)
        # $9 - optional repo type ("borg" or "borgbase"; default: "borg").
        #      "borgbase" uses ensureBorgBaseInit's borg-native (no shell)
        #      existence/init check instead of direxists/dircreate - see
        #      FIX #50 for why: BorgBase's forced-command SSH rejects any
        #      non-borg command at all, including ls/mkdir.
        # $10 - optional BORG_VERIFY depth for this run's interval
        #       ("off"/"repo"/"archive"/"data"; default: "off") - see
        #       checkBorg().
        backendBorg_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="backendBorg"
        backendBorg_repo="$1"
        backendBorg_remotecmd="$2"
        backendBorg_label="$3"
        backendBorg_createopts="$4"
        backendBorg_srcpath="$5"
        backendBorg_pruneopts="$6"
        backendBorg_intervallabel="$7"
        backendBorg_encryption="${8:-repokey}"
        backendBorg_repotype="${9:-borg}"
        backendBorg_verifydepth="${10:-off}"

        if [ "$backendBorg_repotype" = "borgbase" ]; then
            ensureBorgBaseInit "$backendBorg_repo" "$backendBorg_remotecmd" "$backendBorg_encryption"
        else
            if ! direxists "$backendBorg_repo"; then
                msg "INFO" "Creating repo directory: $backendBorg_repo"
                dircreate "$backendBorg_repo"
                msg "INFO" "Init Borg repo: $backendBorg_repo"
                if ! initBorg "$backendBorg_repo" "$backendBorg_remotecmd" "$backendBorg_encryption"; then
                    # FIX #57: initBorg already logged the failure loudly
                    # and returned nonzero - this repo isn't usable this
                    # run (createBorg/pruneBorg/checkBorg would just
                    # cascade into more failures against a never-
                    # initialized repo). Skip it, but let the dispatch
                    # loop in bckp_hdlr.sh continue normally to the next
                    # configured repo, matching FIX #36's philosophy.
                    LASTFUNC="$backendBorg_CALLINGFUCNTION"
                    unset backendBorg_CALLINGFUCNTION
                    unset backendBorg_repo
                    unset backendBorg_remotecmd
                    unset backendBorg_label
                    unset backendBorg_createopts
                    unset backendBorg_srcpath
                    unset backendBorg_pruneopts
                    unset backendBorg_intervallabel
                    unset backendBorg_encryption
                    unset backendBorg_repotype
                    unset backendBorg_verifydepth
                    return 0
                fi
            fi
        fi

        msg "DEBUG" "--------------------------- CREATE BORG -----------------------------------"
        msg "DEBUG" "Repo is: $backendBorg_repo "
        createBorg "$backendBorg_repo" "$backendBorg_label" "$backendBorg_createopts" "$backendBorg_srcpath" "$backendBorg_remotecmd"
        msg "DEBUG" "--------------------------- PRUNE BORG -----------------------------------"
        msg "DEBUG" "Repo is: $backendBorg_repo "
        pruneBorg "$backendBorg_repo" "$backendBorg_pruneopts" "$backendBorg_intervallabel" "$backendBorg_remotecmd"
        checkBorg "$backendBorg_repo" "$backendBorg_remotecmd" "$backendBorg_verifydepth"
        checkRestoreBorg "$backendBorg_repo" "$backendBorg_remotecmd" "$backendBorg_label"
        checkRepoCapacity "$backendBorg_repo"

        LASTFUNC="$backendBorg_CALLINGFUCNTION"
        unset backendBorg_CALLINGFUCNTION
        unset backendBorg_repo
        unset backendBorg_remotecmd
        unset backendBorg_label
        unset backendBorg_createopts
        unset backendBorg_srcpath
        unset backendBorg_pruneopts
        unset backendBorg_intervallabel
        unset backendBorg_encryption
        unset backendBorg_repotype
        unset backendBorg_verifydepth
        return 0
    }

fi