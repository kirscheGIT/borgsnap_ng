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

        initBorg_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="initBorg"
        initBorg_OLD_IFS="$IFS"
        IFS=' '
        initBorg_pathlist="$1"
        initBorg_borgpath="$2"
        initBorg_encryption="${3:-repokey}"
        
        initBorg_remotepath=""
        initBorg_cmdline=""

        if [ -n "$initBorg_borgpath" ]; then
            msg "borgpath set"
            initBorg_remotepath="--remote-path=${initBorg_borgpath}"
        else
            msg "borgpath not set - default to borg"
            initBorg_remotepath="--remote-path=borg"
        fi

        for i in $initBorg_pathlist; do
            msg "DEBUG" "Init Borg path is: $i "
            if [ "${i#ssh://}" != "$i" ]; then
                msg "DEBUG" "Initialize Remote path"
                initBorg_cmdline="borg init --encryption=$initBorg_encryption --show-rc "$initBorg_remotepath" "$i""
                msg "DEBUG" "Init Borg cmdline is $initBorg_cmdline"
                #exec_cmd borg init --encryption=repokey --show-rc "$initBorg_remotepath" "$i"
                exec_cmd eval "$initBorg_cmdline"  
                #set -e
            else
                exec_cmd borg init --encryption="$initBorg_encryption" --show-rc "$i"  
                #set -e
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
        return 0
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
            msg "borgpath set"
            crtBorg_remotepath="--remote-path=${crtBorg_borgpath}"
        else
            msg "borgpath not set - default to borg"
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
            msg "borgpath set"
            pruneBorg_remotepath="--remote-path=${pruneBorg_borgpath}"
        else
            msg "borgpath not set - default to borg"
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

        if [ "$backendBorg_repotype" = "borgbase" ]; then
            ensureBorgBaseInit "$backendBorg_repo" "$backendBorg_remotecmd" "$backendBorg_encryption"
        else
            if ! direxists "$backendBorg_repo"; then
                msg "INFO" "Creating repo directory: $backendBorg_repo"
                dircreate "$backendBorg_repo"
                msg "INFO" "Init Borg repo: $backendBorg_repo"
                initBorg "$backendBorg_repo" "$backendBorg_remotecmd" "$backendBorg_encryption"
            fi
        fi

        msg "DEBUG" "--------------------------- CREATE BORG -----------------------------------"
        msg "DEBUG" "Repo is: $backendBorg_repo "
        createBorg "$backendBorg_repo" "$backendBorg_label" "$backendBorg_createopts" "$backendBorg_srcpath" "$backendBorg_remotecmd"
        msg "DEBUG" "--------------------------- PRUNE BORG -----------------------------------"
        msg "DEBUG" "Repo is: $backendBorg_repo "
        pruneBorg "$backendBorg_repo" "$backendBorg_pruneopts" "$backendBorg_intervallabel" "$backendBorg_remotecmd"

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
        return 0
    }

fi