#!/bin/sh
# helper_functions.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${HELPER_FUNCTIONS_SOURCED+x}" ]; then
    export HELPER_FUNCTIONS_SOURCED=1  
    
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
    msg "helper_functions.sh invoked"
    msg "DEBUG" "-----------------------------------------------"

    chkDateStr() {
        chkDateStr_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="chkDateStr"
        chkDateStr_OLD_IFS="$IFS"
        IFS=' '
        chkDateStr_datestr="$1"

        if echo "$chkDateStr_datestr" | grep -qE '[0-9]{8}'; then
            msg "DEBUG" "$chkDateStr_datestr contains a date."
            LASTFUNC="$chkDateStr_CALLINGFUCNTION"
            unset chkDateStr_CALLINGFUCNTION
            unset chkDateStr_datestr
            IFS="$chkDateStr_OLD_IFS"
            unset chkDateStr_OLD_IFS
            return 0     
        elif [ "$chkDateStr_datestr" = "daily" ] || [ "$chkDateStr_datestr" = "weekly" ] || [ "$chkDateStr_datestr" = monthly ]; then
            msg "DEBUG" "$chkDateStr_datestr contains a backup interval."
            LASTFUNC="$chkDateStr_CALLINGFUCNTION"
            unset chkDateStr_CALLINGFUCNTION
            unset chkDateStr_datestr
            IFS="$chkDateStr_OLD_IFS"
            unset chkDateStr_OLD_IFS            
            return 1     
        else
            msg "ERROR" "$chkDateStr_datestr does not contain a date or valid backup interval name."
            LASTFUNC="$chkDateStr_CALLINGFUCNTION"
            unset chkDateStr_CALLINGFUCNTION
            unset chkDateStr_datestr
            IFS="$chkDateStr_OLD_IFS"
            unset chkDateStr_OLD_IFS            
            return 2
        fi
        

        }
fi