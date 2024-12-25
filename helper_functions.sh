#!/bin/sh
# helper_functions.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${HELPER_FUNCTIONS_SOURCED+x}" ]; then
    export HELPER_FUNCTIONS_SOURCED=1  
    
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
    msg "helper_functions.sh invoked"
    msg "DEBUG" "-----------------------------------------------"

    chkDateStr() {
        LASTFUNC="chkDateStr"
        ldatestr="$1"

        if echo "$ldatestr" | grep -qE '[0-9]{8}'; then
            msg "DEBUG" "$ldatestr contains a date."
            unset ldatestr
            return 0     
        elif [ "$ldatestr" = "daily" ] || [ "$ldatestr" = "weekly" ] || [ "$ldatestr" = monthly ]; then
            msg "DEBUG" "$ldatestr contains a backup interval."
            unset ldatestr
            return 1     
        else
            msg "ERROR" "$ldatestr does not contain a date or valid backup interval name."
            unset ldatestr
            return 2
        fi
        

        }
fi