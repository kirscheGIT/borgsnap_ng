#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
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

        for i in $FS; do
            dataset="$i"
            localdir="${LOCAL:+$LOCAL/$dataset}"
            remotedir="${REMOTESSHCONFIG:+"ssh://"$REMOTESSHCONFIG/$REMOTEDIRPSX/$dataset}"

            msg "INFO" "Processing $dataset"
            msg "INFO" "remotedir is $remotedir"
            if [ "$localdir" != "" ] && [ ! -d "$localdir" ] && [ "$LOCALSKIP" != true ]; then
                msg "INFO" "Initializing borg $localdir"
                exec_cmd mkdir -p "$localdir"
                exec_cmd borg init --encryption=repokey "$localdir"
            fi
            if [ "$remotedir" != "" ]; then
                #remotedirexists "$REMOTESSHCONFIG" "$REMOTEDIRPSX" "$dataset"
                if remotedirexists "$REMOTESSHCONFIG" "$REMOTEDIRPSX" "$dataset"; then
                    set -e
                    msg "INFO" "Initializing remote $remotedir"
                    remotedircreate "$REMOTESSHCONFIG" "$REMOTEDIRPSX" "$dataset"
                    exec_cmd borg init --encryption=repokey --remote-path="${BORGPATH}" "$remotedir"
                    
                fi
                set -e
            fi
        done
    }    
    

fi