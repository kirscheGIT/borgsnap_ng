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
    msg "DEBUG" "cfg_file_hdlr.sh invoked"
    msg "DEBUG" "-----------------------------------------------"

    checkFilePerms() {
        # $1 - mandatory file path to check
        # $2 - mandatory human-readable label for the warning message
        # FIX #40: warns (does not die - see call site) if a file is
        # readable or writable by group or others. Uses `ls -ld` instead of
        # `stat`, since stat's flags differ between GNU (-c) and BSD/macOS
        # (-f) - ls -l's leading permission-string format is far more
        # universally consistent across POSIX-ish systems.
        chkFilePerms_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="checkFilePerms"
        chkFilePerms_target="$1"
        chkFilePerms_label="$2"

        if [ ! -e "$chkFilePerms_target" ]; then
            LASTFUNC="$chkFilePerms_CALLINGFUCNTION"
            unset chkFilePerms_CALLINGFUCNTION
            unset chkFilePerms_target
            unset chkFilePerms_label
            return 0
        fi

        chkFilePerms_perms=$(ls -ld -- "$chkFilePerms_target" 2>/dev/null | awk '{print $1}')
        chkFilePerms_group=$(printf '%s' "$chkFilePerms_perms" | cut -c5-7)
        chkFilePerms_other=$(printf '%s' "$chkFilePerms_perms" | cut -c8-10)

        if [ "$chkFilePerms_group" != "---" ] || [ "$chkFilePerms_other" != "---" ]; then
            msg "WARNING" "$chkFilePerms_label ($chkFilePerms_target) is readable or writable by group/others ($chkFilePerms_perms) - recommend: chmod 600 $chkFilePerms_target"
        fi

        LASTFUNC="$chkFilePerms_CALLINGFUCNTION"
        unset chkFilePerms_CALLINGFUCNTION
        unset chkFilePerms_target
        unset chkFilePerms_label
        unset chkFilePerms_perms
        unset chkFilePerms_group
        unset chkFilePerms_other
        return 0
    }

    readconfigfile() {
        lconfigfile_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="readconfigfile"
        lconfigfile="$1"
       
         
        [ -r "$lconfigfile" ] || die "$LASTFUNC: Unable to open $lconfigfile"
        # FIX #40: readability alone doesn't mean the permissions are sane -
        # a world-readable config file (or worse, passphrase file) is a
        # real information leak on any multi-user system. Warn (don't die -
        # this shouldn't break an existing working setup on first upgrade),
        # loudly, for both the config file and the PASS file below.
        checkFilePerms "$lconfigfile" "config file"
        msg "DEBUG" "$LASTFUNC: Reading Config File $lconfigfile"
        # shellcheck disable=SC1090
        . "$lconfigfile"

        # MSG_LEVEL: optional, lets a config file override the message
        # verbosity that's otherwise hardcoded in borgsnap_ng.sh (0=errors
        # only, 1=+warnings, 2=+info, 3=+verbose, 5=full debug - see
        # msg_and_err_hdlr.sh for the exact thresholds). If the config
        # file doesn't set it, whatever borgsnap_ng.sh set before sourcing
        # this file stands unchanged - this is purely validation, not a
        # default-setting step. Messages logged before this point (during
        # early sourcing) already used the pre-config level and can't be
        # retroactively changed.
        case "$MSG_LEVEL" in
            ''|*[!0-9]*)
                die "MSG_LEVEL: invalid value '$MSG_LEVEL' - must be a non-negative integer (0=errors only ... 5=full debug)"
                ;;
        esac
        export MSG_LEVEL
        msg "DEBUG" "MSG_LEVEL is $MSG_LEVEL"

        # SNAPSHOT_TAG: optional, empty by default. Inserted as
        # "TAG-interval-date" instead of the plain "interval-date" ZFS
        # snapshot label - lets borgsnap_ng coexist on the same dataset
        # as another backup tool (including the original borgsnap, which
        # shares this same interval-date label convention) without a
        # snapshot-name collision. Restricted to letters/digits/
        # underscore - it becomes part of a ZFS snapshot name and is
        # matched via exact-prefix string operations elsewhere, so
        # anything that could be ambiguous with the "-" separator between
        # tag/interval/date, or that ZFS itself would reject, is rejected
        # here up front instead of failing confusingly later.
        if [ -n "${SNAPSHOT_TAG:-}" ]; then
            case "$SNAPSHOT_TAG" in
                *[!a-zA-Z0-9_]*)
                    die "SNAPSHOT_TAG: invalid value '$SNAPSHOT_TAG' - only letters, digits, and underscore are allowed"
                    ;;
            esac
        fi
        export SNAPSHOT_TAG
        msg "DEBUG" "SNAPSHOT_TAG is ${SNAPSHOT_TAG:-<not set>}"

        # MONTHLY_DAY: optional, defaults to 1 (the historical, hardcoded
        # behavior - unset or empty means nothing changes for existing
        # configs). Which day-of-month triggers a fresh "monthly"
        # snapshot/verify for THIS dataset. Lets different datasets'
        # monthly runs (and, critically, their BORG_VERIFY "data"-depth
        # checks, which are the expensive part) land on different days
        # instead of every configured dataset hitting the exact same day
        # - useful for spreading load across a billing period instead of
        # spiking it all on the 1st.
        #
        # Restricted to 1-28: every month has at least 28 days, so any
        # value in this range is guaranteed to occur every month. A value
        # of 29-31 would silently skip that dataset's monthly entirely in
        # any month too short to contain it (e.g. 30 in February) - not a
        # one-off missed day, a fully skipped month with no monthly
        # snapshot or verify at all - so rejected up front rather than
        # left to fail unpredictably, once a year, in a way that would be
        # easy to miss.
        if [ -n "${MONTHLY_DAY:-}" ]; then
            case "$MONTHLY_DAY" in
                ''|*[!0-9]*)
                    die "MONTHLY_DAY: invalid value '$MONTHLY_DAY' - must be a number from 1 to 28"
                    ;;
            esac
            if [ "$MONTHLY_DAY" -lt 1 ] || [ "$MONTHLY_DAY" -gt 28 ]; then
                die "MONTHLY_DAY: invalid value '$MONTHLY_DAY' - must be between 1 and 28 (not every month has a 29th-31st, so a value outside this range would skip that dataset's monthly snapshot/verify entirely in some months)"
            fi
        else
            MONTHLY_DAY=1
        fi
        export MONTHLY_DAY
        msg "DEBUG" "MONTHLY_DAY is $MONTHLY_DAY"

        [ "$(id -un)" = "$LOCAL_BORG_USER" ] || die "Configured user is $LOCAL_BORG_USER - Executing user is $(id -un)"
   
        checkFilePerms "$PASS" "PASS (borg passphrase) file"
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

        # BORG_VERIFY: optional, per-interval "borg check" depth, e.g.
        # "daily:off;weekly:repo;monthly:data". Unset/empty means no
        # verification at all for every interval - preserves existing
        # behavior for every config that predates this feature. Validated
        # here (not silently ignored later) so a typo'd depth is caught at
        # config load time, not discovered months later when a scheduled
        # check never actually ran.
        if [ "${BORG_VERIFY:-}" = "" ]; then
            export BORG_VERIFY=""
            msg "INFO" "BORG_VERIFY not configured, defaulting to no verification"
        else
            export BORG_VERIFY
            msg "INFO" "BORG_VERIFY set to $BORG_VERIFY"
            lconfigfile_verify_OLD_IFS="$IFS"
            IFS=';'
            for lconfigfile_verify_entry in $BORG_VERIFY; do
                lconfigfile_verify_depth="${lconfigfile_verify_entry#*:}"
                case "$lconfigfile_verify_depth" in
                    off|repo|archive|data) ;;
                    *)
                        lconfigfile_verify_msg="BORG_VERIFY: invalid depth '$lconfigfile_verify_depth' in entry '$lconfigfile_verify_entry' - must be one of: off, repo, archive, data" # noqa:unset
                        IFS="$lconfigfile_verify_OLD_IFS"
                        unset lconfigfile_verify_OLD_IFS
                        unset lconfigfile_verify_entry
                        unset lconfigfile_verify_depth
                        die "$lconfigfile_verify_msg"
                        ;;
                esac
            done
            IFS="$lconfigfile_verify_OLD_IFS"
            unset lconfigfile_verify_OLD_IFS
            unset lconfigfile_verify_entry
            unset lconfigfile_verify_depth
        fi

        # RESTORE_VERIFY: optional, per-interval restore-path verification,
        # e.g. "daily:off;monthly:on". Unlike BORG_VERIFY (which checks
        # that the stored BYTES are intact), this checks that the actual
        # RESTORE PATH works - extraction/mount, permissions, the whole
        # pipeline - by writing a known "canary" file into the dataset
        # before every run this is enabled for, then reading it back from
        # each backend after the backup completes and comparing. Unset/
        # empty means no verification for every interval - preserves
        # existing behavior for every config that predates this feature.
        # Validated here for the same reason as BORG_VERIFY: catch a
        # typo'd value at config load time, not months later when a
        # scheduled check never actually ran.
        if [ "${RESTORE_VERIFY:-}" = "" ]; then
            export RESTORE_VERIFY=""
            msg "INFO" "RESTORE_VERIFY not configured, defaulting to no verification"
        else
            export RESTORE_VERIFY
            msg "INFO" "RESTORE_VERIFY set to $RESTORE_VERIFY"
            lconfigfile_rverify_OLD_IFS="$IFS"
            IFS=';'
            for lconfigfile_rverify_entry in $RESTORE_VERIFY; do
                lconfigfile_rverify_depth="${lconfigfile_rverify_entry#*:}"
                case "$lconfigfile_rverify_depth" in
                    off|on) ;;
                    *)
                        lconfigfile_rverify_msg="RESTORE_VERIFY: invalid value '$lconfigfile_rverify_depth' in entry '$lconfigfile_rverify_entry' - must be one of: off, on" # noqa:unset
                        IFS="$lconfigfile_rverify_OLD_IFS"
                        unset lconfigfile_rverify_OLD_IFS
                        unset lconfigfile_rverify_entry
                        unset lconfigfile_rverify_depth
                        die "$lconfigfile_rverify_msg"
                        ;;
                esac
            done
            IFS="$lconfigfile_rverify_OLD_IFS"
            unset lconfigfile_rverify_OLD_IFS
            unset lconfigfile_rverify_entry
            unset lconfigfile_rverify_depth
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