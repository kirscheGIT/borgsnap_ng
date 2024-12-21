#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${BORG_HDLR_SOURCED+x}" ]; then
    export BORG_HDLR_SOURCED=1  
    
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
    msg "DEBUG" "-----------------------------------------------"
    msg "DEBUG" "sourced borg_hdlr.sh"
    msg "DEBUG" "-----------------------------------------------"
    
    
    initBorg(){
        # $1 - mandatory list of repo paths
        # $2 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!

        LASTFUNC="initBorg"
        lpathlist="$1"
        lborgpath="$2"
        lremotepath=""

        if [ -n "$lborgpath" ]; then
            msg "borgpath set"
            lremotepath="--remote-path="${lborgpath}
        fi

        for i in $lpathlist; do
            if [ "${i#ssh://}" != "$i" ]; then
                exec_cmd borg init --encryption=repokey "$lremotepath" "$i"
                  
                set -e
            else
                exec_cmd borg init --encryption=repokey "$i"  
                set -e
            fi
        done

        unset lborgpath
        unset lremotepath
        unset lpathlist
    }

    createBorg(){
        # $1 - mandatory list of repo paths
        # $2 - mandatory label of the backup
        # $3 - mandatory borg options like compression etc. 
        #      valid for all repos in the list
        # $4 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!

        LASTFUNC="createBorg"
        lpathlist="$1"
        lbackuplabel="$2"
        lborgopts="$3"
        lborgpath="$4"
        llocalpath="$5"
        lremotepath=""

        if [ -n "$lborgpath" ]; then
            msg "borgpath set"
            lremotepath="--remote-path="${lborgpath}
        fi

        for i in $lpathlist; do
            if [ "${i#ssh://}" != "$i" ]; then
                exec_cmd borg create "$lborgopts" --encryption=repokey "$lremotepath" "${i}::${lbackuplabel}" "$llocalpath"
                  
                set -e
            else 
                exec_cmd borg create "$lborgopts" --encryption=repokey  "${i}::${lbackuplabel}" "$llocalpath"
                  
                set -e
            fi
        done

        
        
        unset lpathlist
        unset lbackuplabel
        unset lborgopts
        unset lborgpath
        unset llocalpath
        unset lremotepath

    }

fi