#!/bin/sh
# remote_dir_functions.sh is part of borgsnap_ng - licensed under GPLv3. See the LICENSE file for additional
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

    remotedirexists(){
        LASTFUNC="remotedirexists"
        lremotessh="$1"
        lremotedir="$2"
        ldataset="$3"
        lcheckpath=""

        msg "DEBUG" "Remote dir is $lremotedir"
        msg "DEBUG" "Dataset dir is $ldataset"
        lcheckpath="$lremotedir$ldataset"
        msg "DEBUG" "Remote path to check is $lcheckpath"
        if ssh "$lremotessh" 'ls '"$lcheckpath" > /dev/null 2>&1; then
            msg "INFO" "remotedir - $lremotedir - and dataset - $ldataset - exist"
            set +x
            unset lremotessh
            unset lremotedir
            unset ldataset
            unset lcheckpath

            return 0
        else
            msg "INFO" "Directory $lcheckpath doesn't exist"
            set +x
            unset lremotessh
            unset lremotedir
            unset ldataset
            unset lcheckpath

            return 1
        fi
    }
    
    remotedircreate() {
        # $1 - remote directory
        set +e
        LASTFUNC="remotedircreate"
        lremotessh="$1"
        lremotedir="$2"
        ldataset="$3"
        lcreatepath=""

        msg "DEBUG" "Remote dir is $lremotedir"
        msg "DEBUG" "Dataset dir is $ldataset"
        lcreatepath="$lremotedir$ldataset"
        msg "INFO" "Creating Path at remote path $lcreatepath"
        # when the ssh mkdir fails, we need the error handler
        exec_cmd ssh "$lremotessh" 'mkdir -p '"$lcreatepath"

        unset lremotessh
        unset lremotedir
        unset ldataset
        unset lcreatepath
        return 0
    }
fi