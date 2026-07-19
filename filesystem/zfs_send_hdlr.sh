#!/bin/sh
# zfs_send_hdlr.sh - licensed under GPLv3. See the LICENSE file for additional
# details.
#
# Placeholder for the "zfssend" backend (REPOLIST entries prefixed
# "zfssend:"). This file exists so the backend dispatch introduced in
# backup/bckp_hdlr.sh (see the FIX #41 comment there) has something real to
# call - the actual zfs send/receive implementation (bookmarks, resumable
# receive, target pool lifecycle) is a separate, later piece of work.
# Until that lands, backendZfsSend() fails loudly and specifically, so a
# REPOLIST entry using "zfssend:" today gets a clear, actionable error
# instead of being silently skipped or mishandled by the borg codepath.
# shellcheck disable=SC3043
if [ -z "${ZFS_SEND_HDLR_SOURCED+x}" ]; then
    export ZFS_SEND_HDLR_SOURCED=1

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

    set -u
    msg "DEBUG" "-----------------------------------------------"
    msg "DEBUG" "sourced zfs_send_hdlr.sh"
    msg "DEBUG" "-----------------------------------------------"

    backendZfsSend(){
        # $1 - mandatory zfssend target: a local ZFS pool/dataset path that
        #      the source dataset gets mirrored underneath (e.g. target
        #      "backuppool/kirsche-local" + source "tank/data" -> received
        #      dataset "backuppool/kirsche-local/tank/data")
        # $2 - optional remote command (kept for call-site symmetry with
        #      backendBorg; local-only in this step, not used yet)
        # $3 - mandatory source ZFS dataset
        # $4 - mandatory snapshot label (interval-date, e.g. "daily-20260719")
        # $5 - mandatory keep duration for this interval (not used yet -
        #      send-side retention is a later step)
        bckndZfsSend_CALLINGFUCNTION="$LASTFUNC"
        LASTFUNC="backendZfsSend"
        bckndZfsSend_target="$1"
        bckndZfsSend_remotecmd="$2"
        bckndZfsSend_dataset="$3"
        bckndZfsSend_label="$4"
        bckndZfsSend_keepduration="$5"

        bckndZfsSend_targetdataset="$bckndZfsSend_target/$bckndZfsSend_dataset"
        unset bckndZfsSend_target
        bckndZfsSend_targetparent="${bckndZfsSend_targetdataset%/*}"

        msg "DEBUG" "backendZfsSend: $bckndZfsSend_dataset@$bckndZfsSend_label -> $bckndZfsSend_targetdataset (remote cmd: ${bckndZfsSend_remotecmd:-none}, keep $bckndZfsSend_keepduration)"

        # Ensure the parent dataset hierarchy exists on the target. zfs
        # receive creates exactly the leaf dataset it's given - it doesn't
        # create missing parents the way `mkdir -p` would for directories.
        if [ "$bckndZfsSend_targetparent" != "$bckndZfsSend_targetdataset" ]; then
            if ! zfs list -H "$bckndZfsSend_targetparent" >/dev/null 2>&1; then
                msg "INFO" "Creating parent dataset hierarchy: $bckndZfsSend_targetparent"
                exec_cmd zfs create -p "$bckndZfsSend_targetparent"
            fi
        fi

        # FIX #42, step 1 of the zfs-send backend: only the very first,
        # full send is implemented so far. Incremental sends (step 2),
        # bookmark-based chains that survive source-side retention (step
        # 3), resumable receive (step 4), target readonly + separate
        # target-side retention (step 5), and removable-media pool
        # import/export (step 6) are deliberately not yet handled - each
        # is its own later, separately tested increment.
        if zfs list -H "$bckndZfsSend_targetdataset" >/dev/null 2>&1; then
            unset bckndZfsSend_remotecmd
            unset bckndZfsSend_keepduration
            unset bckndZfsSend_targetparent
            LASTFUNC="$bckndZfsSend_CALLINGFUCNTION"
            unset bckndZfsSend_CALLINGFUCNTION
            die "zfssend: target dataset '$bckndZfsSend_targetdataset' already exists - incremental sends aren't implemented yet (only the first, full send is). Destroy it manually if you want to re-run the initial send, or wait for incremental support."
        fi

        # The actual send|receive pipe. Both sides run in subshells (pipe
        # semantics), so - same lesson as FIX #37, but this time the data
        # itself is a binary stream and can't go through a $(...) capture -
        # each side's exit code is written to its own temp file instead of
        # relying on the pipeline's own $? (which POSIX only defines as the
        # LAST command's exit code) or bash-only $PIPESTATUS.
        bckndZfsSend_sendrc_file=$(mktemp)
        bckndZfsSend_recvrc_file=$(mktemp)

        msg "DEBUG" "Full send: $bckndZfsSend_dataset@$bckndZfsSend_label -> $bckndZfsSend_targetdataset"
        msg "DEBUG" "exec_cmd parameters in $LASTFUNC: zfs send $bckndZfsSend_dataset@$bckndZfsSend_label | zfs receive $bckndZfsSend_targetdataset"

        { zfs send "$bckndZfsSend_dataset@$bckndZfsSend_label"; echo "$?" > "$bckndZfsSend_sendrc_file"; } | \
        { zfs receive "$bckndZfsSend_targetdataset"; echo "$?" > "$bckndZfsSend_recvrc_file"; }

        bckndZfsSend_sendrc=$(cat "$bckndZfsSend_sendrc_file")
        bckndZfsSend_recvrc=$(cat "$bckndZfsSend_recvrc_file")
        rm -f "$bckndZfsSend_sendrc_file" "$bckndZfsSend_recvrc_file"
        msg "DEBUG" "send rc=$bckndZfsSend_sendrc, receive rc=$bckndZfsSend_recvrc"

        LASTFUNC="$bckndZfsSend_CALLINGFUCNTION"
        unset bckndZfsSend_CALLINGFUCNTION
        unset bckndZfsSend_remotecmd
        unset bckndZfsSend_keepduration
        unset bckndZfsSend_targetparent
        unset bckndZfsSend_sendrc_file
        unset bckndZfsSend_recvrc_file

        if [ "$bckndZfsSend_sendrc" -ne 0 ]; then
            unset bckndZfsSend_dataset
            unset bckndZfsSend_label
            unset bckndZfsSend_targetdataset
            unset bckndZfsSend_recvrc
            err_hdlr "$bckndZfsSend_sendrc"
        fi
        if [ "$bckndZfsSend_recvrc" -ne 0 ]; then
            unset bckndZfsSend_dataset
            unset bckndZfsSend_label
            unset bckndZfsSend_targetdataset
            err_hdlr "$bckndZfsSend_recvrc"
        fi

        msg "INFO" "zfssend: full send of $bckndZfsSend_dataset@$bckndZfsSend_label to $bckndZfsSend_targetdataset succeeded"
        unset bckndZfsSend_dataset
        unset bckndZfsSend_label
        unset bckndZfsSend_targetdataset
        unset bckndZfsSend_sendrc
        unset bckndZfsSend_recvrc
        return 0
    }
fi
