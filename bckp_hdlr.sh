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

    execBackup(){
        LASTFUNC="execBackup"
        OLD_IFS="$IFS"
        IFS=';'
        for dataset in $FS; do
            dataset=$(echo "$dataset" | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
            
            for repo in $REPOS; do
                repo=$(echo "$repo" | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
                # now we check if the current repo has to be skipped
                if { [ "${repo#ssh://}" != "$repo" ] && [ "$REPOSKIP" != "REMOTE" ]; } || \
                    { [ "${repo#ssh://}" = "$repo" ] && [ "$REPOSKIP" != "LOCAL" ]; }; then
                     
                    if direxists "$repo"; then
                        msg "INFO" "Creating repo directory: $repo"
                        dircreate "$repo"
                        msg "INFO" "Init Borg repo: $repo"
                        initBorg "$repo" # TODO Add Borg remote command
                    fi
                fi

            done
            
        done
        IFS="$OLD_IFS"
    }    
    

fi