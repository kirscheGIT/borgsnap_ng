#!/bin/sh

# borgsnap_ng - licensed under GPLv3. See the LICENSE file for additional
# details.
#
# Perform a ZFS snapshot and rolling backups using borg.
# On the first of the month, a snapshot is done labeled "monthly-".
# Otherwise every Sunday, a snapshot is done is done labeled "weekly-".
# Otherwise every day, a snapshot is done labeled "daily-".
# If no monthly- or weekly- snapshots already exist, these will be done even
# if it is not the first of the month or Sunday.
#
# Keep up to MONTHLY_KEEP monthly backups, WEEKLY_KEEP weekly backups, and
# DAILY_KEEP daily backups.
#
# Usage: borgsnap <command> <config_file> [<args>]
#
# Configuration file documentation:
#
# The configuration file is blindly and dumbly sourced as shell variables,
# hence do not do things such as add whitespace around the "=". There are no
# defaults, all options must be specified. See the example configuration files
# to use as a template.
#
# FS - List ZFS filesystems to backup.
#   Example: FS="zroot/root zroot/home zdata/data"
#
# LOCAL - If specified (not ""), directory for local borgbackups. Backups
#       will be stored in subdirectories of pool and filesystem, for example
#       "/backup/borg/zroot/root". This directory must be created prior to
#       running borgsnap.
#   Example: LOCAL="/backup/borg"
#
# LOCAL_READABLE_BY_OTHERS - Make borg repo readable by non-root
#   Example: LOCAL_READABLE_BY_OTHERS=true
#
# SKIPLOCAL - If specified, borgsnap will skip local backup destinations and
#             only issue backup commands to REMOTE destination
#
# RECURSIVE - Create recursive ZFS snapshots for all child filsystems beneath 
#             all filesystems specified in "FS". All child filesystems will
#             be mounted for borgbackup.
#   Example: RECURSIVE=true
#            or
#            RECURSIVE=false
#
# COMPRESS - Choose compression algorithm for Borg backups. Default for borgbackup
#            is lz4, default here is zstd (which applies zstd,3)
#
# REMOTE - If specified (not ""), remote connect string and directory. Only
#          rsync.net has been tested. The remote directory (myhost in the
#          example) will be created if it does not exist.
#   Example: REMOTE=""
#   Example: REMOTE="XXXX@YYYY.rsync.net:myhost"
#
# PASS - Path to a file containing a single line with the passphrase for borg
#        encryption. I generate these with "pwgen 128 1 >/my/path/myhost.key".
#   Example: PASS="/path/to/my/super/secret/myhost.key"
#
# MONTHLY_KEEP - Number of monthly backups to keep.
#   Example: MONTHLY_KEEP=1
#
# WEEKLY_KEEP - Number of weekly backups to keep.
#   Example: WEEKLY_KEEP=4
#
# DAILY_KEEP - Number of daily backups to keep.
#   Example: DAILY_KEEP=7
#
# Note that semantics for lifecycles differ for local ZFS snapshots,
# local borg, and remote borg backups. For ZFS snapshots, we delete all but
# the last N snapshots matching the monthly-, weekly-, or daily- labels. For borg,
# this uses "borg prune" rather than "borg delete".

set -u

if [ -z "${LASTFUNC+x}" ]; then
    export LASTFUNC=""
fi


export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin"
export BINDDIR="/run/borgsnap"
export BORGPATH="borg1" # "borg1" for rsync.net, otherwise "borg" as appropriate

####################################################################################
# control script messaging/ debugging and error handling
####################################################################################
export MSG_DEFINED
export MSG_LEVEL=2
export ERR_HDLR_DEFINED

. ./common/msg_and_err_hdlr.sh

if [ -z "${ERR_HDLR_DEFINED+x}" ]; then
  die() {
    echo "$0: $*" >&2
    exit 1
  }
  echo "$0 - No external Error handler found - using simple internal one!"
  ERR_HDLR_DEFINED=1
fi

if [ -z "${MSG_DEFINED+x}" ]; then
    msg() {
        #########################
        # disable messaging
        #########################
        return 0
    }
    echo "$0 - No external message handler script defined - Messaging and Debug messages are disabled"
    export MSG_DEFINED=1
fi
####################################################################################

. ./common/dir_functions.sh
. ./filesystem/zfs_hdlr.sh
. ./filesystem/zfs_snap_mount.sh
. ./backup/bckp_hdlr.sh
. ./borg/borg_hdlr.sh
. ./cfg_file_hdlr.sh

msg "DEBUG" "$PATH"

usage() {
  cat << EOF

usage: $(basename "$0") <command> <config_file> [<args>]

commands:
    run             Run backup lifecycle.
                    usage: $(basename "$0") run <config_file>

    snap            Run backup for specific snapshot.
                    usage: $(basename "$0") snap <config_file> <snapshot-name>

    tidy            Unmount and remove snapshots/local backups for today
                    usage: $(basename "$0") tidy <config_file>
		    
EOF
  exit 1
}







# Main script execution
if [ "$#" -eq 0 ]; then
  usage
  # shellcheck disable=SC2317
  exit
fi

case "$1" in
  run)
    shift  # Remove the first argument
    readconfigfile "$@"
    startBackupMachine "$FS" "$REPOLIST" "$RETENTIONPERIOD" "" "" "";;
    #runBackup "$@";;
  snap)
    shift  # Remove the first argument
    backupSnapshot "$@";;
  tidy)
    shift  # Remove the first argument
    tidyUp "$@";;
  -h)
    usage;;
  *)
    echo "$1 is an unknown command!" && usage;;
esac

exit
# [ ] TODO: #23 readconfigfile before backup run?
