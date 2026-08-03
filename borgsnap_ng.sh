#!/bin/sh

# borgsnap_ng - licensed under GPLv3. See the LICENSE file for additional
# details.
#
# Snapshots ZFS filesystems and backs them up - to local and/or remote
# borg repos, and/or via native ZFS send/receive - see REPOLIST below.
# On the first of the month, a snapshot is taken labeled "monthly-".
# Otherwise every Sunday, "weekly-". Otherwise every day, "daily-". If no
# monthly-/weekly- snapshot exists yet, one is taken even if today isn't
# the 1st/a Sunday. How many of each to keep is controlled by
# RETENTIONPERIOD below - there are no separate MONTHLY_KEEP/WEEKLY_KEEP/
# DAILY_KEEP variables.
#
# Usage: borgsnap_ng.sh <command> <config_file> [<args>]
#   run  - the main command: snapshot + mount + back up + prune, for
#          every configured filesystem and repo
#   snap - take a snapshot only (see backupSnapshot in backup/bckp_hdlr.sh)
#   tidy - clean up only (see tidyUp)
#
# Configuration file documentation:
#
# The configuration file is sourced directly as shell variables - don't
# add whitespace around "=". sample.conf is the canonical, fully
# documented reference for every option, its defaults, and worked
# examples; this is a short overview of what exists and where to look.
#
# LOCAL_BORG_USER - user that runs the backup. A dedicated, non-root user
#   is strongly recommended - see ops/least-privilege/README.md for the
#   sudo/ZFS-delegation setup that needs.
#
# MSG_LEVEL - optional message verbosity (0=errors only ... 5=full
#   debug); a genuine failure is always shown regardless. See sample.conf
#   for the exact thresholds.
#
# FS - semicolon-separated list of ZFS filesystems to back up, each
#   paired with a comma-separated recursion flag ("r"/"R" for recursive,
#   anything else/empty for a single, non-recursive mount).
#   Example: FS="zroot/root,; zroot/home,; zdata/data,r"
#   See sample.conf for the pitfall of backing up the same dataset both
#   recursively (as part of a parent) and separately as its own entry.
#
# COMPRESS - borg compression setting, e.g. "auto,zstd,3".
#
# CACHEMODE - borg's --files-cache mode, e.g. "mtime,size".
#
# PASS - path to a file containing the borg encryption passphrase.
#
# BASEDIR - optional borg cache-file base directory.
#
# LOCAL_READABLE_BY_OTHERS - logged, not yet enforced - see BACKLOG.md.
#
# REPOLIST - semicolon-separated list of backup destinations. Each entry
#   is "path, remotecmd, encryption" (the last two optional), optionally
#   prefixed with a backend type: "borg:" (default if no prefix),
#   "zfssend:" (native ZFS send/receive - see
#   filesystem/zfs_send_hdlr.sh), or "borgbase:" for BorgBase's forced-
#   command SSH repos specifically. Remote (ssh://) entries need a
#   matching Host alias in the backup user's own ~/.ssh/config, with
#   key-based auth already set up. See sample.conf for concrete examples
#   of each backend type.
#
# REPOSKIP - "LOCAL", "REMOTE", or "NONE" - skip that whole category of
#   repo for this run.
#
# RETENTIONPERIOD - "monthly,N;weekly,N;daily,N" - how many of each to
#   keep, both for ZFS snapshots (source side) and for borg archives (via
#   "borg prune"). The interval names must be exactly "monthly",
#   "weekly", and "daily" - nothing else is recognized. See SNAPSHOT_TAG
#   below if you need to avoid a naming collision with another tool.
#
# SNAPSHOT_TAG - optional, empty by default. Inserts a fixed prefix into
#   every ZFS snapshot label ("TAG-monthly-20260730" instead of plain
#   "monthly-20260730") - lets borgsnap_ng coexist on the same dataset as
#   another backup tool (including the original borgsnap, which shares
#   this same interval-date label convention) without a snapshot-name
#   collision. Letters, digits, and underscore only. Doesn't affect borg
#   archive names or repo paths - only the ZFS side.
#
# MONTHLY_DAY - optional, defaults to 1. Which day-of-month triggers a
#   fresh "monthly" snapshot/verify for this dataset - lets several
#   datasets/configs stagger their monthly (and the expensive
#   BORG_VERIFY "data"-depth check that often rides on it) across
#   different days instead of all spiking load on the 1st. Must be
#   1-28 - every month has at least 28 days, so any value outside that
#   range would silently skip that dataset's entire monthly in some
#   months rather than just shifting it.
#
# BORG_VERIFY - optional, runs "borg check" after pruning at a
#   configurable depth (repo/archive/data) per interval, to catch a
#   corrupted/unrestorable repo proactively instead of discovering it
#   during an actual disaster recovery. See sample.conf for the full
#   depth-level explanation and the "default:" fallback syntax.
#
# RESTORE_VERIFY - optional, proves the actual restore path works end to
#   end - not just that borg check's on-disk bytes are intact - via a
#   small, automatically written and rewritten canary file. See
#   sample.conf for exactly how, and the one place this needs write
#   access where this project is otherwise read-only.
#
# CAPACITY_WARN_PERCENT - optional, escalates the routine destination
#   fill-level report to a WARNING once usage is at or above this
#   percentage.
#
# PRE_SCRIPT / POST_SCRIPT - paths to scripts intended to run before/
#   after the backup. Currently validated at config-load time (must
#   exist, must be executable) but not yet actually invoked anywhere in
#   the backup flow - see BACKLOG.md.
#
# MAILTO - optional, read by mail_wrapper.sh (not this script directly)
#   to send exactly one SUCCESS/FAILURE/PARTIAL FAILURE email per run
#   instead of relying on cron's own unreliable mail-on-output behavior.
#   See ops/README.md.

set -u

# FIX #49: cd to this script's own directory before any of the relative
# ". ./..." sourcing lines further down - otherwise this script only
# works when invoked with CWD already set to its own directory. Every one
# of this project's own tests always did that (masking the bug for a long
# time), but it breaks the moment something calls it via an absolute path
# from elsewhere - a real cron/systemd invocation, or mail_wrapper.sh.
#
# The config-file argument ($2, for the run/snap/tidy subcommands) is
# resolved to an absolute path FIRST, before the cd below - otherwise a
# relative config path would incorrectly resolve against this script's
# own directory instead of the CALLER's original working directory. If
# it can't be resolved (e.g. a typo'd path that doesn't exist), it's left
# alone - readconfigfile's own "[ -r ... ]" check further down already
# produces a clear error for that case, no need to duplicate it here.
if [ "$#" -ge 2 ]; then
    case "$2" in
        /*) : ;;
        *)
            if [ -e "$2" ]; then
                bsng_resolved_arg2="$(cd -- "$(dirname -- "$2")" 2>/dev/null && pwd -P)/$(basename -- "$2")"
                bsng_first_arg="$1"
                shift 2
                set -- "$bsng_first_arg" "$bsng_resolved_arg2" "$@"
                unset bsng_first_arg
                unset bsng_resolved_arg2
            fi
            ;;
    esac
fi
bsng_scriptdir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
cd -- "$bsng_scriptdir" || { echo "borgsnap_ng.sh: cannot cd to script directory: $bsng_scriptdir" >&2; exit 1; }
unset bsng_scriptdir

if [ -z "${LASTFUNC+x}" ]; then
    export LASTFUNC=""
fi


export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin"
export BINDDIR="/run/borgsnap"

####################################################################################
# control script messaging/ debugging and error handling
####################################################################################
export MSG_DEFINED
export MSG_LEVEL=1
export ERR_HDLR_DEFINED
export BORG_EXIT_CODES=modern

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
. ./filesystem/zfs_send_hdlr.sh
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

# FIX #9: prevent concurrent runs (cron + manual, or a hanging previous run).
# mkdir is atomic and POSIX; the PID inside allows stale-lock detection.
LOCKDIR="${BORGSNAP_LOCKDIR:-/tmp/borgsnap_ng.lock}"
acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" > "$LOCKDIR/pid"
    trap 'rm -rf "$LOCKDIR"' EXIT INT TERM HUP
  else
    lockpid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "?")
    if [ "$lockpid" != "?" ] && ! kill -0 "$lockpid" 2>/dev/null; then
      msg "WARNING" "Removing stale lock of dead PID $lockpid"
      rm -rf "$LOCKDIR"
      acquire_lock
    else
      die "Another borgsnap_ng instance (PID $lockpid) is running - aborting"
    fi
  fi
}

case "$1" in
  run)
    shift  # Remove the first argument
    acquire_lock
    readconfigfile "$@"
    # FIX #68: this used to hardcode "" here regardless of COMPRESS/
    # CACHEMODE, silently triggering bckp_hdlr.sh's own internal fallback
    # ("auto,zstd,9"/"ctime,size,inode") on every single run - COMPRESS/
    # CACHEMODE were validated and logged by cfg_file_hdlr.sh, but never
    # actually threaded through to the real borg command.
    startBackupMachine "$FS" "$REPOLIST" "$RETENTIONPERIOD" "--info --stats --compression=${COMPRESS} --files-cache=${CACHEMODE} --show-rc" "" "";;
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
