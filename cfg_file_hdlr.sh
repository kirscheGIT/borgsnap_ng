#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${CFG_FILE_HDLR_SOURCED+x}" ]; then
    export CFG_FILE_HDLR_SOURCED=1  
    
    . ./common/msg_and_err_hdlr.sh
    
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
#[ ] TODO #19 Rename local variables to unique names / complete rework to reflect the changes made in the whole process
    set -u
    msg "DEBUG" "-----------------------------------------------"
    msg "msg_and_err_hdlr.sh invoked"
    msg "DEBUG" "-----------------------------------------------"

    readconfigfile() {
        LASTFUNC="readconfigfile"
        lconfigfile="$1"
       
       # msg "DEBUG" "Jetzt rufen wir mal das Script auf!!!"
       # exec_cmd "/root/git/conf_bak/test_folder/local_var_test2.sh"
       
       
        [ -r "$lconfigfile" ] || die "$LASTFUNC: Unable to open $lconfigfile"
        msg "DEBUG" "$LASTFUNC: Reading Config File $lconfigfile"
        # shellcheck disable=SC1090
        . "$lconfigfile"

        # [ ] TODO: #20 Modifiy to check if borg user is used
        #[ "$(id -u)" -eq 0 ] || die "Must be run as root"
        [ "$(id -un)" = "$LOCAL_BORG_USER" ] || die "Configured user is $LOCAL_BORG_USER - Executing user is $(id -un)"
   
        BORG_PASSPHRASE=$(cat "$PASS")
        export BORG_PASSPHRASE
        
        [ "$BORG_PASSPHRASE" != "" ] || die "Unable to read passphrase from file $PASS"

        if [ "$LOCAL" != "" ]; then
            [ -d "$LOCAL" ] || die "Non-existent output directory $LOCAL"
        fi
        
        scriptpath="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit; pwd -P)"
        msg "INFO" "$LASTFUNC: scriptpath is $scriptpath/$PRE_SCRIPT"
        if [ "$PRE_SCRIPT" != "" ]; then
            [ -f "$PRE_SCRIPT" ] || die "PRE_SCRIPT specified but could not be found: $PRE_SCRIPT"
            [ -x "$PRE_SCRIPT" ] || die "PRE_SCRIPT specified but could not be executed (run command: chmod +x $PRE_SCRIPT)"
        fi

        if [ "$POST_SCRIPT" != "" ]; then
            [ -f "$POST_SCRIPT" ] || die "POST_SCRIPT specified but could not be found: $POST_SCRIPT"
            [ -x "$POST_SCRIPT" ] || die "POST_SCRIPT specified but could not be executed (run command: chmod +x $POST_SCRIPT)"
        fi

        if [ "$BASEDIR" != "" ]; then
            if [ -d "$BASEDIR" ]; then
                BORG_BASE_DIR="$BASEDIR"
                export BORG_BASE_DIR
                msg "INFO" "Borgbackup basedir set to $BORG_BASE_DIR"
            else
                die "Non-existent BASEDIR $BASEDIR"
            fi
        fi
        if [ "$CACHEMODE" = "" ]; then
            export CACHEMODE="ctime,size,inode"
            msg "INFO" "CACHEMODE not configured, defaulting to ctime,size,inode"
        else
            msg "INFO" "CACHEMODE set to $CACHEMODE"
            export CACHEMODE
        fi
        if [ "$REMOTE_BORG_COMMAND" = "" ]; then
            export BORGPATH="borg1"
            msg "INFO" "REMOTE_BORG_COMMAND not configured, defaulting to $BORGPATH (for rsync.net)"
        else
            export BORGPATH="$REMOTE_BORG_COMMAND"
            msg "INFO" "REMOTE_BORG_COMMAND set to $BORGPATH"
        fi

        export REMOTESSHCONFIG="$REMOTE_SSH_CONFIG"
        msg "DEBUG" "Remote ssh config is: $REMOTESSHCONFIG"
        export REMOTEDIRPSX="$REMOTE_DIR_PSX"

        # [ ] TODO: #21 Check $FS variable if empty

        unset lconfigfile

        }
fi