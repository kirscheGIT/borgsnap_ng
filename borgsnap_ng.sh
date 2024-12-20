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
export MSG_LEVEL=5
export ERR_HDLR_DEFINED

. ./msg_and_err_hdlr.sh

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

. ./dir_functions.sh
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



# TODO: Modifiy to check if borg user is used
#[ "$(id -u)" -eq 0 ] || die "Must be run as root"
#[ "$(id -un)" = "root" ] || die "Must be run as root"
# username=$(id -un)
# msg "$username"

dow=$(date +"%w")
dom=$(date +"%d")
date=$(date +"%Y%m%d")

forcemonth=0
forceweek=0



findlast() {
  zfs list -t snap -o name | grep "${1}@${2}-" | sort -nr | head -1
}

findall() {
  zfs list -t snap -o name | grep "${1}@${2}-" | sort -nr
}

snapshot() {
  set +e
  SNAPSHOTEXISTS="$(zfs list -t snapshot | grep "${1}@${2}")" 
  echo "$SNAPSHOTEXISTS"
  if [ "$SNAPSHOTEXISTS" = "" ]; then
    set -e
    if [ "$RECURSIVE" = "true" ]; then
      echo "Recursive snapshot ${1}@${2}"
      zfs snapshot -r "${1}@${2}"
    else
      echo "Snapshot ${1}@${2}"
      zfs snapshot "${1}@${2}"
    fi
      # Check if the snapshot operation is still running
    while pgrep -f "zfs snapshot" > /dev/null; do
        echo "Waiting for the snapshot operation to complete..."
        sleep 5  #Sleep for a short time before checking again
    done
  else
    echo "Snapshot ${1}@${2} exists. Assuming last run did not finish - restarting borg"
  fi
}

destroysnapshot() {
  if [ "$RECURSIVE" = "true" ]; then
    echo "Recursive snapshot ${1}@${2}"
    zfs destroy -r "${1}@${2}"
  else
    echo "Snapshot ${1}@${2}"
    zfs destroy "${1}@${2}"
  fi

  # Check if the destroy operation is still running
  while pgrep -f "zfs destroy" > /dev/null; do
    echo "Waiting for the destroy operation to complete..."
    sleep 5  #Sleep for a short time before checking again
  done

  echo "Destroy operation has completed."
}


recursivezfsmount() {
  # $1 - volume, pool/dataset
  # $2 - snapshot label
  # Expects $bind_dir

  for R in $(zfs list -Hr -t snapshot -o name "$1" | grep "@$2$" | sed -e "s@^$1@@" -e "s/@$2$//"); do
    echo "Mounting child filesystem snapshot: $1$R@$2"
    mkdir -p "$bind_dir$R"
    mount -t zfs "$1$R@$2" "$bind_dir$R"
  done
}
recursivezfsumount() {
  # $1 - volume, pool/dataset
  # $2 - snapshot label
  # Expects $bind_dir

  for R in $(zfs list -Hr -t snapshot -o name "$1" | grep "@$2$" | sed -e "s@^$1@@" -e "s/@$2$//" | tac); do
    echo "Unmounting child filesystem snapshot: $bind_dir$R"
    umount "$bind_dir$R"
  done
}




dobackup() {
  # $1 - volume, i.e. zroot/home
  # $2 - label, i.e. monthly-20170602
  # Expects localdir, remotedir, BINDDIR
  LASTFUNC="dobackup"
  msg "------ $(date) ------"
  bind_dir="${BINDDIR}/${1}"
  exec_cmd mkdir -p "$bind_dir"
  msg "DEBUG" "bind_dir is: $bind_dir" 
  exec_cmd mount -t zfs "${1}@${2}" "$bind_dir"
  if [ "$RECURSIVE" = "true" ]; then
    recursivezfsmount "$1" "$2"
  fi
  BORG_OPTS="--info --stats --compression $COMPRESS --files-cache $CACHEMODE --exclude-if-present .noborg"
  if [ "$localdir" != "" ] && [ "$LOCALSKIP" != "true" ]; then
    echo "Doing local backup of ${1}@${2}"
    # shellcheck disable=SC2086
    borg create $BORG_OPTS "${localdir}::${2}" "$bind_dir"
    if [ "$LOCAL_READABLE_BY_OTHERS" = "true" ]; then
      echo "Set read permissions for others"
      chmod +rx "${localdir}" -R
    fi
  else
    msg "INFO" "Skipping local backup"
  fi
  if [ "$remotedir" != "" ]; then
    echo "Doing remote backup of ${1}@${2}"
    # shellcheck disable=SC2086
    borg create $BORG_OPTS --remote-path="${BORGPATH}" "${remotedir}::${2}" "$bind_dir"
  fi
  if [ "$RECURSIVE" = "true" ]; then
    recursivezfsumount "$1" "$2"
  fi

  umount -n "$bind_dir"
}

purgeold() {
  # $1 - volume, i.e. zroot/home
  # $2 - prefix, i.e. monthly, weekly, or daily
  # $3 - number to keep
  # Expects localdir, remotedir

  echo "------ $(date) ------"
  total=$(findall "$1" "$2" | wc -l)

  if [ "$total" -le "$3" ]; then
    echo "No old backups to purge"
  else
    delete=$((total - $3))
    echo "Keep: $3, found: $total, will delete $delete"
    for i in $(findall "$1" "$2" | tail -n "$delete"); do
      echo "Purging old snapshot $i"
      zfs destroy -r "$i"
    done
    BORG_OPTS="--info --stats --keep-daily=$DAILY_KEEP --keep-weekly=$WEEKLY_KEEP --keep-monthly=$MONTHLY_KEEP"
    if [ "$localdir" != "" ] && [ "$LOCALSKIP" != true ]; then
      echo "Pruning local borg"
      # shellcheck disable=SC2086
      borg prune $BORG_OPTS "$localdir"
    fi
    if [ "$remotedir" != "" ]; then
      echo "Pruning remote borg"
      # shellcheck disable=SC2086
      borg prune $BORG_OPTS --remote-path="${BORGPATH}" "$remotedir"
    fi
  fi
}

runBackup() {
  if [ "$#" -eq 1 ]; then
    readconfigfile "$1"
  else
    usage
  fi

  echo "====== $(date) ======"
  for i in $FS; do
    dataset="$i"
    localdir="${LOCAL:+$LOCAL/$dataset}"
    #remotedir="${REMOTE:+$REMOTE/$dataset}"
    remotedir="${REMOTESSHCONFIG:+"ssh://"$REMOTESSHCONFIG/$REMOTEDIRPSX/$dataset}"

    msg "INFO" "Processing $dataset"
    msg "INFO" "remotedir is $remotedir"
    if [ "$localdir" != "" ] && [ ! -d "$localdir" ] && [ "$LOCALSKIP" != true ]; then
      echo "Initializing borg $localdir"
      mkdir -p "$localdir"
      borg init --encryption=repokey "$localdir"
    fi
    if [ "$remotedir" != "" ]; then
      #checkdirexists "$remotedir"
      #checkdirexists "$REMOTE" "$dataset"
      #direxists "$REMOTESSHCONFIG" "$REMOTEDIRPSX" "$dataset"
      # if [ $? -eq 1 ]; then
      if ! direxists "$REMOTESSHCONFIG" "$REMOTEDIRPSX" "$dataset"; then
        set -e
        echo "Initializing remote $remotedir"
        
        #createdir "$remotedir"
        dircreate "$REMOTESSHCONFIG" "$REMOTEDIRPSX" "$dataset"
        #temp disabled for debug purposes
        exit 0
     #   borg init --encryption=repokey --remote-path="${BORGPATH}" "$remotedir"
      fi
      set -e
    fi

    lastmonthly=$(findlast "$i" monthly)
    if [ "$lastmonthly" = "" ]; then
      forcemonth=1
    fi

    lastweekly=$(findlast "$i" weekly)
    if [ "$lastweekly" = "" ]; then
      forceweek=1
    fi

    if [ "$PRE_SCRIPT" != "" ]; then
      echo "====== $(date) ======"
      echo "Executing pre-snapshot script: $PRE_SCRIPT"
      if [ -x "$PRE_SCRIPT" ]; then
        "$PRE_SCRIPT" "$i"
        sleep 3
      fi
    fi

    if [ "$forcemonth" = 1 ] || [ "$dom" -eq 1 ]; then
      label="monthly-$date"
      snapshot "$i" "$label"
      dobackup "$i" "$label"
      purgeold "$i" monthly "$MONTHLY_KEEP"
    elif [ "$forceweek" = 1 ] || [ "$dow" -eq 0 ]; then
      label="weekly-$date"
      snapshot "$i" "$label"
      dobackup "$i" "$label"
      purgeold "$i" weekly "$WEEKLY_KEEP"
    else
      label="daily-$date"
      snapshot "$i" "$label"
      dobackup "$i" "$label"
      purgeold "$i" daily "$DAILY_KEEP"
    fi

    if [ "$POST_SCRIPT" != "" ]; then
      echo "====== $(date) ======"
      echo "Executing post-snapshot script: $POST_SCRIPT"
      if [ -x "$POST_SCRIPT" ]; then
        "$POST_SCRIPT" "$i"
      fi
    fi
  done
  echo "====== $(date) ======"

  echo "Backup Done $(date)"
}

backupSnapshot() {
  if [ "$#" -eq 2 ]; then
    readconfigfile "$1"
  else
    usage
  fi

  for i in $FS; do
    dataset=${i}
    if [ "$LOCAL" != "" ]; then
      localdir="$LOCAL/$dataset"
    else
      localdir=""
    fi
    if [ "$REMOTE" != "" ]; then
      remotedir="$REMOTE/$dataset"
    else
      remotedir=""
    fi

    msg "INFO" "backupsnapshot() Processing $dataset"

    if [ "$localdir" != "" ] && [ ! -d "$localdir" ]; then
      echo "Initializing borg $localdir"
      mkdir -p "$localdir"
      borg init --encryption=repokey "$localdir"
    fi
    if [ "$remotedir" != "" ]; then
      direxists "$remotedir"
      if [ $? -eq 1 ]; then
        set -e
        echo "Initializing remote $remotedir"
        dircreate "$remotedir"
        borg init --encryption=repokey --remote-path="${BORGPATH}" "$remotedir"
      fi
      set -e
    fi

    label="$2"
    dobackup "$i" "$label"

    echo "Backup Done $dataset@$2"
  done
}

tidybackup() {
  # $1 - volume, i.e. zroot/home
  # $2 - label, i.e. monthly-20170602
  # Expects localdir, BINDDIR

  echo "------ $(date) ------"
  bind_dir="${BINDDIR}/${1}"
  if [ "$LOCAL" != "" ]; then
    localdir="$LOCAL/$dataset"
  else
    localdir=""
  fi
  if [ "$REMOTE" != "" ]; then
    remotedir="$REMOTE/$dataset"
  else
    remotedir=""
  fi
  mkdir -p "$bind_dir"
  BORG_OPTS="--info --stats"
  if [ "$localdir" != "" ] && [ "$LOCALSKIP" != true ]; then
    echo "Deleting local backup of ${1}@${2}"
    # shellcheck disable=SC2086
    borg delete $BORG_OPTS "${localdir}::${2}" 
    if [ "$LOCAL_READABLE_BY_OTHERS" ]; then
      echo "Set read permissions for others"
      chmod +rx "${localdir}" -R
    fi
  fi

  if [ "$remotedir" != "" ]; then
    echo "Deleting remote backup of ${1}@${2}"
    # shellcheck disable=SC2086
    borg delete $BORG_OPTS --remote-path="${BORGPATH}" "$remotedir::${2}"
  fi
}

tidyUp() {
  if [ "$#" -eq 1 ]; then
    readconfigfile "$1"
  else
    usage
  fi

  echo "====== $(date) ======"
  echo "Unmounting snapshots"
  
  # Unmounting snapshots in reverse order
  mount | grep ' on /run/borgsnap/' | sed 's/^.* on //' | sed 's/\ type zfs.*//' | awk '{ lines[NR] = $0 } END { for (i = NR; i > 0; i--) print lines[i] }' | while read -r f; do
    umount "$f"
  done

  echo "Removing today's snapshots/backups"
  for i in $FS; do
    dataset=${i}
    lastmonthly=$(findlast "$i" monthly)
    if [ "$lastmonthly" = "" ]; then
      forcemonth=1
    fi

    lastweekly=$(findlast "$i" weekly)
    if [ "$lastweekly" = "" ]; then
      forceweek=1
    fi

    if [ "$forcemonth" = 1 ] || [ "$dom" -eq 1 ]; then
      label="monthly-$date"
      destroysnapshot "$i" "$label"
      tidybackup "$i" "$label"
    elif [ "$forceweek" = 1 ] || [ "$dow" -eq 0 ]; then
      label="weekly-$date"
      destroysnapshot "$i" "$label"
      tidybackup "$i" "$label"
    else
      label="daily-$date"
      destroysnapshot "$i" "$label"
      tidybackup "$i" "$label"
    fi
  done

  echo "Tidy Done $(date)"
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
    runBackup "$@";;
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
# TODO: readconfigfile before backup run?
# TODO: Change the IFS and trim whitespaces
# # Original IFS value
# OLD_IFS="$IFS"
# Set IFS to semicolon
# IFS=';'
# for i in $FS; do
#    trimmed=$(echo "$i" | sed 's/^[ \t]*//;s/[ \t]*$//')  # Trim leading and trailing whitespace
#    echo '$trimmed'"
# done
## Reset IFS to its original value
# IFS="$OLD_IFS"