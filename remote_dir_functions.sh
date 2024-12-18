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

    # Function name to check
    # func_name="msg"

    # # Check if the function is defined
    # if ! eval "type $func_name" >/dev/null 2>&1; then
    #     # Function does not exist, define it
    #     msg() {
    #         #printf "DEBUG is not enabled"
    #         return 0
    #     }
    # fi

    # Check if the function is defined using a variable

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
        local remotessh="$1"
        local remotedir="$2"
        local dataset="$3"
        local checkpath=""

        msg "DEBUG" "Remote dir is $remotedir"
        msg "DEBUG" "Dataset dir is $dataset"
        checkpath="$remotedir$dataset"
        msg "DEBUG" "Remote path to check is $checkpath"
        if ssh "$remotessh" 'ls '"$checkpath" > /dev/null 2>&1; then
            msg "INFO" "remotedir - $remotedir - and dataset - $dataset - exist"
            set +x
            return 0
        else
            msg "INFO" "Directory $checkpath doesn't exist"
            set +x
            return 1
        fi
    }
    
    remotedircreate() {
        # $1 - remote directory
        set +e
        LASTFUNC="remotedircreate"
        local remotessh="$1"
        local remotedir="$2"
        local dataset="$3"
        local createpath=""

        msg "DEBUG" "Remote dir is $remotedir"
        msg "DEBUG" "Dataset dir is $dataset"
        createpath="$remotedir$dataset"
        msg "INFO" "Creating Path at remote path $createpath"
        # when the ssh mkdir fails, we need the error handler
        exec_cmd ssh "$remotessh" 'mkdir -p '"$createpath"
        return 0
    }
fi