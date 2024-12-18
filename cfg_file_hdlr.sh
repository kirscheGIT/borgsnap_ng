#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${CFG_FILE_HDLR_SOURCED+x}" ]; then
    export CFG_FILE_HDLR_SOURCED=1  
    
    . ./msg_and_err_hdlr.sh
    
    if [ -z "${LASTFUNC+x}" ]; then
        export LASTFUNC=""
    fi

    set -u

    msg "msg_and_err_hdlr.sh invoked"


    readconfigfile() {
        LASTFUNC="readconfigfile"
        local lconfigfile="$1"

        [ -r "$lconfigfile" ] || die "$LASTFUNC: Unable to open $lconfigfile"
        msg "DEBUG" "$LASTFUNC: Reading Config File $lconfigfile"
        # shellcheck disable=SC1090
        . "$lconfigfile"

        BORG_PASSPHRASE=$(cat "$PASS")
        export BORG_PASSPHRASE

        if [ "$RSH" != "" ]; then
            BORG_RSH="$RSH"
        else
            BORG_RSH=ssh
        fi
        echo "RSH = $BORG_RSH"
        export BORG_RSH

        [ "$BORG_PASSPHRASE" != "" ] || die "Unable to read passphrase from file $PASS"
        if [ "$LOCAL" != "" ]; then
            [ -d "$LOCAL" ] || die "Non-existent output directory $LOCAL"
        fi
        scriptpath="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
        echo "scriptpath is $scriptpath/$PRE_SCRIPT"
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
            echo "Borgbackup basedir set to $BORG_BASE_DIR"
            else
            die "Non-existent BASEDIR $BASEDIR"
            fi
        fi
        if [ "$CACHEMODE" = "" ]; then
            export CACHEMODE="ctime,size,inode"
            echo "CACHEMODE not configured, defaulting to ctime,size,inode"
        else
            echo "CACHEMODE set to $CACHEMODE"
            export CACHEMODE
        fi
        if [ "$REMOTE_BORG_COMMAND" = "" ]; then
            export BORGPATH="borg1"
            echo "REMOTE_BORG_COMMAND not configured, defaulting to $BORGPATH (for rsync.net)"
        else
            export BORGPATH="$REMOTE_BORG_COMMAND"
            echo "REMOTE_BORG_COMMAND set to $BORGPATH"
        fi

        export REMOTESSHCONFIG="$REMOTE_SSH_CONFIG"
        export REMOTEDIRPSX="$REMOTE_DIR_PSX"


        }
fi