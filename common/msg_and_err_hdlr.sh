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
            lcalling_function="$LASTFUNC"
            LASTFUNC="msg"
            if [ "$#" -eq 1 ]; then
                printf "%s\n" "$1" >&2 

            elif [ "$#" -eq 2 ]; then
                lmsg_type="$1"
                lmsg_content="$2"
                lmsg_key=
                lvalue=

                lvalue=$(eval "echo \$${lmsg_type##*[!0-9_a-z_A-Z]*}" 2>/dev/null)
            
                if [ -n "$lvalue" ]; then
                    lmsg_key="$lvalue"
                    if [ "$MSG_LEVEL" -ge "$lmsg_key" ]; then
                        printf "%s: %s in Function %s\n" "$lmsg_type" "$lmsg_content" "$lcalling_function" >&2 
                    fi
                else
                    echo "$1 Is a wrong key word" >&2 
                fi    
            else
                printf "USAGE ERROR: msg() function - Too many parameters.  max. 2 parameters alowed. Instead %i parameters were provided: %s\n" "$#" "$*" >&2 
            fi
            LASTFUNC="$lcalling_function"
            unset lcalling_function
            unset lmsg_type
            unset lmsg_content
            unset lmsg_key
            unset lvalue
            return 0;
        }
    else 
        printf "msg_and_err_hdlr.sh: Debug messaging already defined: %s\n" "$MSG_DEFINED"
    fi
    if [ -z "${ERR_HDLR_DEFINED+x}" ]; then
        ERR_HDLR_DEFINED=1
        err_hdlr() {
            # errHdlr_LASTFUNC is intentionally never unset: this function
            # always terminates the process via `exit 1` below, it never
            # returns control to the caller, so there's no later code path
            # where a stale value could cause harm.
            errHdlr_LASTFUNC="$LASTFUNC" # noqa:unset
            # FIX #8: MOUNT_BORG_BASE_DIR is only set after the first mount.
            # If an error occurs before that, referencing it under set -u
            # crashed the error handler itself.
            if [ "$LASTFUNC" != "unmountZFSSnapshot" ] && [ -n "${MOUNT_BORG_BASE_DIR:-}" ]; then
               umountZFSSnapshot "$MOUNT_BORG_BASE_DIR"
               LASTFUNC="$errHdlr_LASTFUNC"
            fi
            case "$1" in
                1) msg "ERROR" "Got exit code 1"  ;;
                #echo "Error: Command failed with exit status 1." ;;
                2) msg "ERROR: Command failed with exit status 2." ;;
                *) msg "ERROR: An unknown error occurred." ;;
            esac
            exit 1
        }

        exec_cmd() {
            exec_cmd_OLD_IFS="$IFS"
            IFS=' '
            # lexit_status carries the wrapped command's real exit code all
            # the way to the `return` below (see FIX #35), so it can't be
            # unset before that point like the other locals in this
            # function - it IS the return value.
            lexit_status= # noqa:unset
            exec_cmd_string="$@"
	        msg "DEBUG" "exec_cmd parameters in $LASTFUNC: $exec_cmd_string"
            "$@"  # Execute the command passed as arguments
            lexit_status="$?"  # noqa:unset - see comment above; carries the return value
            msg "DEBUG" "Error status is $lexit_status"
            if [ "$lexit_status" -ne 0 ] && [ "$LASTFUNC" != "createBorg" ] ; then
                IFS="$exec_cmd_OLD_IFS"
                err_hdlr "$lexit_status"  # Handle the error if the command failed
            fi
            IFS="$exec_cmd_OLD_IFS"
            unset exec_cmd_OLD_IFS
            unset exec_cmd_string
            # FIX #35: propagate the real exit code instead of a hardcoded
            # 0. When exec_cmd runs directly (no pipe/substitution), this
            # changes nothing observable - err_hdlr already exited the
            # process above on failure, so reaching this line always means
            # lexit_status is 0, OR LASTFUNC was "createBorg" (the
            # intentional multi-repo-resilience carve-out - see FIX #36 in
            # borg_hdlr.sh for how that case is now surfaced instead of
            # silently swallowed). When exec_cmd runs inside a pipe or
            # command substitution, this is what lets the caller detect the
            # failure via $? in its own (non-subshell) context.
            return "$lexit_status"
        }

         die() {
            echo "$0: $*" >&2
            exit 1
        }
    fi
fi
