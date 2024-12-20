#!/bin/sh
# dir_functions.sh is part of borgsnap_ng - licensed under GPLv3. See the LICENSE file for additional
# details.

# shellcheck disable=SC3043
if [ -z "${REMOTE_DIR_FUNCTION_SCRIPT_SOURCED+x}" ]; then
    export REMOTE_DIR_FUNCTION_SCRIPT_SOURCED=1    
    set +e
    #set -x
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

    msg "DEBUG" "sourced checkdirexists.sh"

    direxists(){
        LASTFUNC="direxists"
        lremotessh="$1"
        lremotedir="$2"
        ldataset="$3"
        lcheckpath=""
        lchkcmd=""

        if [ -z "$lremotessh" ]; then
            lchkcmd="ls ";
        else
            lchkcmd="ssh $lremotessh ls"; 
        fi

        msg "DEBUG" "Remote dir is $lremotedir"
        msg "DEBUG" "Dataset dir is $ldataset"
        msg "DEBUG" "Checkpath is $lchkcmd"
        #lcheckpath="/$lremotedir/$ldataset"
        lcheckpath="/""$lremotedir""/""$ldataset"
        msg "DEBUG" "Remote path to check is $lcheckpath"
        msg "$lchkcmd$lcheckpath"
        #exec_cmd $lchkcmd$lcheckpath
        if  $lchkcmd "$lcheckpath" > /dev/null 2>&1; then
            msg "INFO" "remotedir - $lremotedir - and dataset - $ldataset - exist"
            set +x
            unset lremotessh
            unset lremotedir
            unset ldataset
            unset lcheckpath
            unset lchkcmd
            return 0
        else
            msg "INFO" "Directory $lcheckpath doesn't exist"
            set +x
            unset lremotessh
            unset lremotedir
            unset ldataset
            unset lcheckpath
            unset lchkcmd
            return 1
        fi
    }
    
    dircreate() {
        # $1 - remote directory
        set +e
        LASTFUNC="dircreate"
        lremotessh="$1"
        lremotedir="$2"
        ldataset="$3"
        lcreatepath=""
        lmkpath=""

        if [ -z "$lremotessh" ]; then
            lmkpath="mkdir -p";
        else
            lmkpath="ssh $lremotessh mkdir -p"; 
        fi

        msg "DEBUG" "Remote dir is $lremotedir"
        msg "DEBUG" "Dataset dir is $ldataset"
        lcreatepath="/$lremotedir/$ldataset"
        msg "INFO" "Creating Path at remote path $lcreatepath"
        # when the ssh mkdir fails, we need the error handler
        exec_cmd $lmkpath "$lcreatepath"

        unset lmkpath
        unset lremotessh
        unset lremotedir
        unset ldataset
        unset lcreatepath
        return 0
    }
fi