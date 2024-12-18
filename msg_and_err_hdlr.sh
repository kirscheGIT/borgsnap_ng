#!/bin/sh
# msg_and_err_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.

# shellcheck disable=SC3043
if [ -z "${MSG_AND_ERR_HDLR_SOURCED+x}" ]; then
    export MSG_AND_ERR_HDLR_SOURCED=1  
    
    set -u

    printf "msg_and_err_hdlr.sh invoked \n"

    if [ -z "${LASTFUNC+x}" ]; then
        export LASTFUNC=""
    fi

    if [ -z "${ERROR+x}" ]; then
        export ERROR=0
    fi
    if [ -z "${WARNING+x}" ]; then
        export WARNING=1
    fi
    if [ -z "${INFO+x}" ]; then
        export INFO=2
    fi
    if [ -z "${VERBOSE+x}" ]; then
        export VERBOSE=3
    fi
    if [ -z "${DEBUG+x}" ]; then
        export DEBUG=5
    fi
    ###################################################################################################
    if [ -z "${MSG_DEFINED+x}" ]; then
        MSG_DEFINED=1
        if [ -z "${MSG_LEVEL+x}" ]; then
            MSG_LEVEL=0
        fi
        printf "msg_and_err_hdlr.sh: Message handler is enabled with message level - %s - \n" "$MSG_LEVEL"
        msg() {
            local calling_function="$LASTFUNC"
            LASTFUNC="msg"
            if [ "$#" -eq 1 ]; then
                printf "%s\n" "$1"

            elif [ "$#" -eq 2 ]; then
                local msg_type="$1"
                local msg_content="$2"
                local msg_key
                local value

                value=$(eval "echo \$${msg_type##*[!0-9_a-z_A-Z]*}" 2>/dev/null)
            
                if [ -n "$value" ]; then
                    msg_key="$value"
                    if [ "$MSG_LEVEL" -ge "$msg_key" ]; then
                        printf "%s: %s in Function %s\n" "$msg_type" "$msg_content" "$calling_function"
                    fi
                else
                    echo "$1 Is a wrong key word"
                fi    
            else
                printf "USAGE ERROR: msg() function - Too many parameters.  max. 2 parameters alowed. Instead %i parameters were provided: %s\n" "$#" "$*"
            fi
            LASTFUNC="$calling_function"
            return 0;
        }
    else 
        printf "msg_and_err_hdlr.sh: Debug messaging already defined: %s\n" "$MSG_DEFINED"
    fi
    if [ -z "${ERR_HDLR_DEFINED+x}" ]; then
        ERR_HDLR_DEFINED=1
        err_hdlr() {
            case "$1" in
                1) msg "ERROR" "Got exit code 1"  ;;
                #echo "Error: Command failed with exit status 1." ;;
                2) msg "ERROR: Command failed with exit status 2." ;;
                *) msg "ERROR: An unknown error occurred." ;;
            esac
            exit 1
        }

        exec_cmd() {
            local exit_status
            "$@"  # Execute the command passed as arguments
            exit_status="$?"  # Capture the exit status
            msg "DEBUG" "Error status is $exit_status"
            if [ "$exit_status" -ne 0 ]; then
                err_hdlr "$exit_status"  # Handle the error if the command failed
            fi
        }
    fi
fi