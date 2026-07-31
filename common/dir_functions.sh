#!/bin/sh
# dir_functions.sh is part of borgsnap_ng - licensed under GPLv3. See the LICENSE file for additional
# details.

# shellcheck disable=SC3043
if [ -z "${REMOTE_DIR_FUNCTION_SCRIPT_SOURCED+x}" ]; then
    export REMOTE_DIR_FUNCTION_SCRIPT_SOURCED=1    
    set +e
    #set -x
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
    
    msg "DEBUG" "-----------------------------------------------"
    msg "DEBUG" "sourced dir_functions.sh"
    msg "DEBUG" "-----------------------------------------------"
    


    direxists(){
        # $1 - target directory to be created
        # Strings that work at exampel:
        # for local directories  /tmp/test
        # for remote directories ssh://my_ssh_borg_server/dir0/dataset
        dirExists_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="direxists"
        dirExists_testdir="$1"
        dirExists_remotessh=""
        dirExists_chkpath=""
        dirExists_chkcmd=""
        dirExists_isremote=0
        dirExists_maxattempts=1
        dirExists_attempt=1

        dirExists_OLD_IFS="$IFS"
        IFS=' '

        if [ -z "$dirExists_testdir" ]; then
            msg "ERROR" "Empty directory string was given!"
            LASTFUNC="$dirExists_CALLINGFUCNTION"
            unset dirExists_CALLINGFUCNTION
            unset dirExists_testdir
            unset dirExists_remotessh
            unset dirExists_chkpath
            unset dirExists_chkcmd
            unset dirExists_isremote
            unset dirExists_maxattempts
            unset dirExists_attempt
            IFS="$dirExists_OLD_IFS"
            unset dirExists_OLD_IFS
            return 2
        fi

        if [ "${dirExists_testdir#ssh://}" != "$dirExists_testdir" ]; then
            # Remove "ssh://" from the string
            dirExists_chkpath="${dirExists_testdir#ssh://}"
            dirExists_remotessh="${dirExists_chkpath%%/*}"
            dirExists_chkpath="${dirExists_chkpath#*/}"
            dirExists_chkpath="$dirExists_chkpath"
            dirExists_chkcmd="ssh $dirExists_remotessh ls"; 
            # FIX #58: a remote check is one SSH round-trip over the
            # internet away from a transient hiccup (a real one was
            # observed in practice: manually re-running the exact same
            # "ssh host ls path" command immediately afterward succeeded
            # cleanly). Relying on a single attempt for a decision as
            # consequential as "should I try to init a brand new repo
            # here" is fragile - retry a few times with a short pause
            # before concluding the repo genuinely doesn't exist. Local
            # checks below are unaffected - no network involved, nothing
            # to retry.
            dirExists_isremote=1
            dirExists_maxattempts=3
        else
            msg "DEBUG" "Local directory to test is: $dirExists_testdir"
            dirExists_chkpath=$dirExists_testdir
            dirExists_chkcmd="ls ";
        fi

        msg "DEBUG" "Checkcmd is $dirExists_chkcmd"
        msg "DEBUG" "Checkpath is $dirExists_chkpath"

        while [ "$dirExists_attempt" -le "$dirExists_maxattempts" ]; do
            if  $dirExists_chkcmd "$dirExists_chkpath" > /dev/null 2>&1; then
                msg "INFO" "Directory $dirExists_chkpath - exist"
                set +x
                LASTFUNC="$dirExists_CALLINGFUCNTION"
                unset dirExists_CALLINGFUCNTION
                unset dirExists_testdir
                unset dirExists_remotessh
                unset dirExists_chkpath
                unset dirExists_chkcmd
                unset dirExists_isremote
                unset dirExists_maxattempts
                unset dirExists_attempt
                IFS="$dirExists_OLD_IFS"
                unset dirExists_OLD_IFS
                return 0
            fi
            if [ "$dirExists_isremote" = 1 ] && [ "$dirExists_attempt" -lt "$dirExists_maxattempts" ]; then
                msg "WARNING" "Directory $dirExists_chkpath - remote check attempt $dirExists_attempt/$dirExists_maxattempts failed, retrying shortly (could be a transient network hiccup)"
                sleep 2
            fi
            dirExists_attempt=$((dirExists_attempt + 1))
        done

        LASTFUNC="$dirExists_CALLINGFUCNTION"
        unset dirExists_CALLINGFUCNTION
        msg "INFO" "Directory $dirExists_chkpath doesn't exist"
        set +x
        unset dirExists_testdir
        unset dirExists_remotessh
        unset dirExists_chkpath
        unset dirExists_chkcmd
        unset dirExists_isremote
        unset dirExists_maxattempts
        unset dirExists_attempt
        IFS="$dirExists_OLD_IFS"
        unset dirExists_OLD_IFS
        return 1
        
    }
    
    dircreate() {
        # $1 - target directory to be created
        # Strings that work at exampel:
        # for local directories  /tmp/test
        # for remote directories ssh://my_ssh_borg_server/dir0/dataset
        dirCreate_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="dircreate"
	    msg "DEBUG" " ---- dircreate start IFS = $IFS ------------------"
        dirCreate_OLD_IFS="$IFS"
        IFS=' '
        dirCreate_tgtdir="$1"
        dirCreate_crtpath=""
        dirCreate_crtcmd=""
	    dirCreate_remotessh=""
        
        msg "DEBUG" "Path is $PATH"
         if [ -z "$dirCreate_tgtdir" ]; then
            msg "ERROR" "Empty directory string was given!"
            LASTFUNC="$dirCreate_CALLINGFUCNTION"
            unset dirCreate_CALLINGFUCNTION
            IFS="$dirCreate_OLD_IFS"
            unset dirCreate_OLD_IFS
            unset dirCreate_tgtdir
            unset dirCreate_crtpath
            unset dirCreate_remotessh
            unset dirCreate_crtcmd
            return 2
        fi
        

        if [ "${dirCreate_tgtdir#ssh://}" != "$dirCreate_tgtdir" ]; then
            # Remove "ssh://" from the path string
            dirCreate_crtpath="${dirCreate_tgtdir#ssh://}"
            # Get the first part of the ssh:// string
            dirCreate_remotessh="${dirCreate_crtpath%%/*}"
            # build the correct tgt path 
            dirCreate_crtpath="${dirCreate_crtpath#*/}"
            msg "DEBUG" "directory create path is: $dirCreate_crtpath"
            #dirCreate_crtpath="$dirCreate_crtpath"
            dirCreate_crtcmd="ssh $dirCreate_remotessh mkdir -p"; 
        else
            msg "DEBUG" "Local directory to test is: $dirCreate_tgtdir"
            dirCreate_crtpath=$dirCreate_tgtdir
            dirCreate_crtcmd="mkdir -p";
        fi

        #msg "DEBUG" "Remote dir is $lremotedir"
        #msg "DEBUG" "Dataset dir is $ldataset"
        #lcreatepath="/$lremotedir/$ldataset"
        msg "INFO" "Creating Path at path $dirCreate_crtpath"
        msg "INFO" "Create command is $dirCreate_crtcmd"
        # when the ssh mkdir fails, we need the error handler
        
        # because the expansion won't work otherwise, we need to disable the
        # check for the next line
        # shellcheck disable=SC2086
        msg "DEBUG" "---- DIRCREATE ------------------"
        eval exec_cmd "$dirCreate_crtcmd" "$dirCreate_crtpath"
        LASTFUNC="$dirCreate_CALLINGFUCNTION"
        unset dirCreate_CALLINGFUCNTION
        IFS="$dirCreate_OLD_IFS"
        msg "DEBUG" " ---- dircreate end IFS = $IFS ------------------"
        unset dirCreate_OLD_IFS
        unset dirCreate_tgtdir
        unset dirCreate_crtpath
        unset dirCreate_remotessh
        unset dirCreate_crtcmd
        
        return 0
    }
fi
