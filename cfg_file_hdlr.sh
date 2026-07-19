#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${CFG_FILE_HDLR_SOURCED+x}" ]; then
    export CFG_FILE_HDLR_SOURCED=1  
    
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
#[ ] TODO #19 Rename local variables to unique names / complete rework to reflect the changes made in the whole process
    set -u
    msg "DEBUG" "-----------------------------------------------"
    msg "msg_and_err_hdlr.sh invoked"
    msg "DEBUG" "-----------------------------------------------"

    readconfigfile() {
        lconfigfile_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="readconfigfile"
        lconfigfile="$1"
       
         
        [ -r "$lconfigfile" ] || die "$LASTFUNC: Unable to open $lconfigfile"
        msg "DEBUG" "$LASTFUNC: Reading Config File $lconfigfile"
        # shellcheck disable=SC1090
        . "$lconfigfile"

        # [ ] TODO: #20 Modifiy to check if borg user is used
        [ "$(id -un)" = "$LOCAL_BORG_USER" ] || die "Configured user is $LOCAL_BORG_USER - Executing user is $(id -un)"
   
        # [ ] TODO: #31 Automated creation of the PASS file if not existend? @kirscheGIT
        BORG_PASSPHRASE=$(cat "$PASS")
        export BORG_PASSPHRASE
        
        [ "$BORG_PASSPHRASE" != "" ] || die "Unable to read passphrase from file $PASS"

        
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

        # [ ] TODO: #30 BASEDIR logic needs a rework @kirscheGIT
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
        if [ "$LOCAL_READABLE_BY_OTHERS" = "" ]; then
            export LOCAL_READABLE_BY_OTHERS="false"
            msg "INFO" "LOCAL_READABLE_BY_OTHERS not configured, defaulting to false"
        else
            export LOCAL_READABLE_BY_OTHERS
            msg "INFO" "LOCAL_READABLE_BY_OTHERS set to $LOCAL_READABLE_BY_OTHERS"
        fi

        if [ "$COMPRESS" = "" ]; then
            export COMPRESS="zstd,8"
            msg "INFO" "COMPRESS not configured, defaulting to zstd,8"
        else
            export COMPRESS
            msg "INFO" "COMPRESS set to $COMPRESS"
        fi

        if [ "$REPOLIST" != "" ]; then
            export REPOLIST
            msg "INFO" "Repolist configured: $REPOLIST "
        else
            die "Empty REPOLIST in $lconfigfile"
        fi

        if [ "$REPOSKIP" = "" ]; then
            export REPOSKIP="NONE"
            msg "INFO" "REPOSKIP not configured, defaulting to NONE"
        else
            export REPOSKIP
            msg "INFO" "REPOSKIP set to $REPOSKIP"
        fi
        
        if [ "$RETENTIONPERIOD" != "" ]; then
            export RETENTIONPERIOD
            msg "INFO" "Repolist configured: $RETENTIONPERIOD "
        else
            die "Empty RETENTIONPERIOD in $lconfigfile"
        fi

        if [ "$FS" != "" ]; then
            export FS
            msg "INFO" "Filesystems configured: $FS "
        else
            die "Empty FS in $lconfigfile"
        fi

        # [x] TODO: #21 Check $FS variable if empty
        # [x] TODO: #29 Read the following parameters @kirscheGIT
        # LOCAL_READABLE_BY_OTHERS -> DEFAULT = false
        # COMPRESS -> DEFAULT = "zstd,8"
        # REPOLIST -> No Default - Throw error if empty
        # REPOSKIP -> DEFAULT = "NONE"
        # RETENTIONPERIOD -> No Default - Throw error if empty

        LASTFUNC="$lconfigfile_CALLINGFUCNTION"
        unset lconfigfile_CALLINGFUCNTION
        unset lconfigfile

        }
fi