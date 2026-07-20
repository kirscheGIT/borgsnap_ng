#!/bin/sh
# zfs_send_hdlr.sh - licensed under GPLv3. See the LICENSE file for additional
# details.
#
# zfs-send backend (REPOLIST entries prefixed "zfssend:"), called from the
# backend dispatch in backup/bckp_hdlr.sh (see the FIX #41 comment there).
#
# Implemented so far:
#   FIX #42 (step 1): first-time full send/receive to a fresh target, with
#            automatic parent-dataset creation on the target.
#   FIX #43 (step 3): bookmark-based incremental sends for every subsequent
#            call - the bookmark survives source-side retention deleting
#            the snapshot it was created from, which a plain
#            snapshot-to-snapshot incremental could not (see the
#            conversation this was designed in for why step 2, plain
#            snapshot-based incrementals, was skipped deliberately).
#
# Not yet implemented (deliberately, each is its own later, separately
# tested increment): resumable receive, target readonly + separate
# target-side retention, removable-media pool import/export, raw send for
# encrypted sources.
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
        # FIX #43: a bookmark name is scoped per-target (via this slug), so
        # the same source dataset can be sent to more than one zfssend
        # target, each tracked independently.
        bckndZfsSend_targetslug=$(echo "$bckndZfsSend_target" | tr '/' '_')
        unset bckndZfsSend_target
        bckndZfsSend_targetparent="${bckndZfsSend_targetdataset%/*}"
        bckndZfsSend_bookmark="$bckndZfsSend_dataset#zfssend-$bckndZfsSend_targetslug"
        unset bckndZfsSend_targetslug

        msg "DEBUG" "backendZfsSend: $bckndZfsSend_dataset@$bckndZfsSend_label -> $bckndZfsSend_targetdataset (remote cmd: ${bckndZfsSend_remotecmd:-none}, keep $bckndZfsSend_keepduration, bookmark $bckndZfsSend_bookmark)"

        # Ensure the parent dataset hierarchy exists on the target. zfs
        # receive creates exactly the leaf dataset it's given - it doesn't
        # create missing parents the way `mkdir -p` would for directories.
        if [ "$bckndZfsSend_targetparent" != "$bckndZfsSend_targetdataset" ]; then
            if ! zfs list -H "$bckndZfsSend_targetparent" >/dev/null 2>&1; then
                msg "INFO" "Creating parent dataset hierarchy: $bckndZfsSend_targetparent"
                exec_cmd zfs create -p "$bckndZfsSend_targetparent"
            fi
        fi
        unset bckndZfsSend_targetparent

        # FIX #43: full vs incremental. If the target dataset already
        # exists, this must be an incremental send, which requires the
        # bookmark left behind by the previous successful send - a bookmark
        # survives even if the snapshot it pointed to has since been
        # destroyed by source-side retention (pruneZFSSnapshot), which is
        # exactly the problem plain snapshot-to-snapshot incrementals can't
        # survive.
        bckndZfsSend_mode="full"
        if zfs list -H "$bckndZfsSend_targetdataset" >/dev/null 2>&1; then
            if ! zfs list -t bookmark -H "$bckndZfsSend_bookmark" >/dev/null 2>&1; then
                unset bckndZfsSend_remotecmd
                unset bckndZfsSend_keepduration
                unset bckndZfsSend_mode
                die "zfssend: target dataset '$bckndZfsSend_targetdataset' already exists but its tracking bookmark '$bckndZfsSend_bookmark' is missing - can't determine what has already been sent. This shouldn't happen in normal operation (the bookmark is created automatically after every successful send). If you're recovering from a manually deleted bookmark, either restore it, or destroy the target dataset to force a fresh full send."
            fi
            bckndZfsSend_mode="incremental"
        fi

        bckndZfsSend_sendrc_file=$(mktemp)
        bckndZfsSend_recvrc_file=$(mktemp)

        # The actual send|receive pipe. Both sides run in subshells (pipe
        # semantics), so - same lesson as FIX #37, but this time the data
        # itself is a binary stream and can't go through a $(...) capture -
        # each side's exit code is written to its own temp file instead of
        # relying on the pipeline's own $? (which POSIX only defines as the
        # LAST command's exit code) or bash-only $PIPESTATUS.
        if [ "$bckndZfsSend_mode" = "full" ]; then
            msg "DEBUG" "Full send: $bckndZfsSend_dataset@$bckndZfsSend_label -> $bckndZfsSend_targetdataset"
            msg "DEBUG" "exec_cmd parameters in $LASTFUNC: zfs send $bckndZfsSend_dataset@$bckndZfsSend_label | zfs receive $bckndZfsSend_targetdataset"
            { zfs send "$bckndZfsSend_dataset@$bckndZfsSend_label"; echo "$?" > "$bckndZfsSend_sendrc_file"; } | \
            { zfs receive "$bckndZfsSend_targetdataset"; echo "$?" > "$bckndZfsSend_recvrc_file"; }
        else
            msg "DEBUG" "Incremental send: $bckndZfsSend_bookmark -> $bckndZfsSend_dataset@$bckndZfsSend_label -> $bckndZfsSend_targetdataset"
            msg "DEBUG" "exec_cmd parameters in $LASTFUNC: zfs send -i $bckndZfsSend_bookmark $bckndZfsSend_dataset@$bckndZfsSend_label | zfs receive $bckndZfsSend_targetdataset"
            { zfs send -i "$bckndZfsSend_bookmark" "$bckndZfsSend_dataset@$bckndZfsSend_label"; echo "$?" > "$bckndZfsSend_sendrc_file"; } | \
            { zfs receive "$bckndZfsSend_targetdataset"; echo "$?" > "$bckndZfsSend_recvrc_file"; }
        fi

        bckndZfsSend_sendrc=$(cat "$bckndZfsSend_sendrc_file")
        bckndZfsSend_recvrc=$(cat "$bckndZfsSend_recvrc_file")
        rm -f "$bckndZfsSend_sendrc_file" "$bckndZfsSend_recvrc_file"
        msg "DEBUG" "send rc=$bckndZfsSend_sendrc, receive rc=$bckndZfsSend_recvrc"

        unset bckndZfsSend_sendrc_file
        unset bckndZfsSend_recvrc_file
        unset bckndZfsSend_remotecmd
        unset bckndZfsSend_keepduration

        # NOTE: LASTFUNC is deliberately NOT restored to the caller before
        # these err_hdlr calls (fixing a latent bug from step 1, where it
        # was restored too early and would have misattributed the failure
        # to the wrong function in the error log).
        if [ "$bckndZfsSend_sendrc" -ne 0 ]; then
            unset bckndZfsSend_dataset
            unset bckndZfsSend_label
            unset bckndZfsSend_targetdataset
            unset bckndZfsSend_bookmark
            unset bckndZfsSend_mode
            unset bckndZfsSend_recvrc
            err_hdlr "$bckndZfsSend_sendrc"
        fi
        if [ "$bckndZfsSend_recvrc" -ne 0 ]; then
            unset bckndZfsSend_dataset
            unset bckndZfsSend_label
            unset bckndZfsSend_targetdataset
            unset bckndZfsSend_bookmark
            unset bckndZfsSend_mode
            err_hdlr "$bckndZfsSend_recvrc"
        fi

        msg "INFO" "zfssend: $bckndZfsSend_mode send of $bckndZfsSend_dataset@$bckndZfsSend_label to $bckndZfsSend_targetdataset succeeded"
        unset bckndZfsSend_mode

        # FIX #43: move the tracking bookmark forward to the snapshot just
        # sent, so the next call can send incrementally from here. Only
        # done after send+receive both succeeded - bookmarking a snapshot
        # that was never actually replicated would silently break the next
        # incremental (it would believe this snapshot IS on the target when
        # it isn't). destroy the old bookmark first: zfs refuses to create
        # one with a name that's already taken, and a bookmark can't be
        # "moved" in place.
        zfs destroy "$bckndZfsSend_bookmark" >/dev/null 2>&1
        exec_cmd zfs bookmark "$bckndZfsSend_dataset@$bckndZfsSend_label" "$bckndZfsSend_bookmark"

        LASTFUNC="$bckndZfsSend_CALLINGFUCNTION"
        unset bckndZfsSend_CALLINGFUCNTION
        unset bckndZfsSend_dataset
        unset bckndZfsSend_label
        unset bckndZfsSend_targetdataset
        unset bckndZfsSend_bookmark
        unset bckndZfsSend_sendrc
        unset bckndZfsSend_recvrc
        return 0
    }
fi
