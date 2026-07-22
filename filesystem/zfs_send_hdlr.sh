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
#   FIX #44 (step 4): resumable receive. Every zfs receive uses -s, and a
#            leftover receive_resume_token is checked for and completed
#            BEFORE anything else - an interrupted transfer might be for an
#            older label than today's, so that call finishes only the old
#            transfer and defers today's new backup to the next run rather
#            than layering a fresh stream on a partially-received target.
#   FIX #45 (step 5): readonly=on on the target after every successful
#            send (zfs receive itself still works fine against a readonly
#            target - only normal POSIX writes are blocked), plus
#            target-side retention by reusing pruneZFSSnapshot as-is
#            against the target dataset instead of the source - it's fully
#            generic and needed no target-specific variant.
#   FIX #46 (step 6): removable-media pool lifecycle. If the target's pool
#            isn't currently imported, import it before doing anything
#            else; if import fails (drive not attached), skip this backend
#            call gracefully - same carve-out spirit as createBorg (FIX
#            #36), one unavailable destination doesn't abort the whole
#            run. Export the pool again afterward, but ONLY if we were the
#            one who imported it - a permanently-attached pool is left
#            exactly as found.
#
# Not yet implemented (deliberately, each is its own later, separately
# tested increment): raw send for encrypted sources, remote (SSH) targets.
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
        # FIX #46: the pool name is the target's first path component -
        # needed to check/attempt import before touching anything on it.
        bckndZfsSend_pool="${bckndZfsSend_target%%/*}"
        # FIX #43: a bookmark name is scoped per-target (via this slug), so
        # the same source dataset can be sent to more than one zfssend
        # target, each tracked independently.
        bckndZfsSend_targetslug=$(echo "$bckndZfsSend_target" | tr '/' '_')
        unset bckndZfsSend_target
        bckndZfsSend_targetparent="${bckndZfsSend_targetdataset%/*}"
        bckndZfsSend_bookmark="$bckndZfsSend_dataset#zfssend-$bckndZfsSend_targetslug"
        unset bckndZfsSend_targetslug

        msg "DEBUG" "backendZfsSend: $bckndZfsSend_dataset@$bckndZfsSend_label -> $bckndZfsSend_targetdataset (remote cmd: ${bckndZfsSend_remotecmd:-none}, keep $bckndZfsSend_keepduration, bookmark $bckndZfsSend_bookmark, pool $bckndZfsSend_pool)"

        # FIX #46: pool lifecycle for removable-media targets. If the
        # target's pool isn't currently imported, try to import it. A
        # failed import (e.g. the removable drive simply isn't attached
        # right now) is an EXPECTED, common state for this kind of target -
        # not a fatal error. Skip this backend call gracefully (matching
        # the createBorg carve-out from FIX #36 - one destination being
        # unavailable shouldn't abort the whole run, including the other
        # configured repos) rather than aborting the whole process via
        # die/err_hdlr.
        bckndZfsSend_pool_imported_by_us=0
        if ! zpool list -H "$bckndZfsSend_pool" >/dev/null 2>&1; then
            msg "INFO" "zfssend: pool '$bckndZfsSend_pool' is not currently imported - attempting import"
            if zpool import "$bckndZfsSend_pool" >/dev/null 2>&1; then
                bckndZfsSend_pool_imported_by_us=1
            else
                msg "WARNING" "zfssend: pool '$bckndZfsSend_pool' could not be imported (not attached?) - skipping this backup target for now"
                LASTFUNC="$bckndZfsSend_CALLINGFUCNTION"
                unset bckndZfsSend_CALLINGFUCNTION
                unset bckndZfsSend_pool
                unset bckndZfsSend_pool_imported_by_us
                unset bckndZfsSend_dataset
                unset bckndZfsSend_label
                unset bckndZfsSend_keepduration
                unset bckndZfsSend_remotecmd
                unset bckndZfsSend_targetdataset
                unset bckndZfsSend_targetparent
                unset bckndZfsSend_bookmark
                return 0
            fi
        fi

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

        # FIX #44: check for a leftover resume token FIRST, before deciding
        # full vs incremental. If the target has an incomplete receive in
        # progress (a previous call got interrupted - network loss, process
        # killed, power loss), that must be finished before anything new is
        # attempted; layering a fresh stream on top of a partially-received
        # dataset isn't a coherent operation. A resumed transfer may be for
        # an OLDER label than today's $bckndZfsSend_label (e.g. yesterday's
        # daily got interrupted and never retried) - so this call completes
        # only that old transfer and returns; today's new backup, if any,
        # goes out on the next run once the target is in a clean state
        # again.
        bckndZfsSend_resumetoken=$(zfs get -H -o value receive_resume_token "$bckndZfsSend_targetdataset" 2>/dev/null)
        [ "$bckndZfsSend_resumetoken" = "-" ] && bckndZfsSend_resumetoken=""

        if [ -n "$bckndZfsSend_resumetoken" ]; then
            bckndZfsSend_mode="resume"
        elif zfs list -H "$bckndZfsSend_targetdataset" >/dev/null 2>&1; then
            # FIX #43: full vs incremental. If the target dataset already
            # exists (and there's no resume in progress), this must be an
            # incremental send, which requires the bookmark left behind by
            # the previous successful send - a bookmark survives even if
            # the snapshot it pointed to has since been destroyed by
            # source-side retention (pruneZFSSnapshot), which is exactly
            # the problem plain snapshot-to-snapshot incrementals can't
            # survive.
            if ! zfs list -t bookmark -H "$bckndZfsSend_bookmark" >/dev/null 2>&1; then
                unset bckndZfsSend_remotecmd
                unset bckndZfsSend_keepduration
                unset bckndZfsSend_resumetoken
                unset bckndZfsSend_pool
                unset bckndZfsSend_pool_imported_by_us
                die "zfssend: target dataset '$bckndZfsSend_targetdataset' already exists but its tracking bookmark '$bckndZfsSend_bookmark' is missing - can't determine what has already been sent. This shouldn't happen in normal operation (the bookmark is created automatically after every successful send). If you're recovering from a manually deleted bookmark, either restore it, or destroy the target dataset to force a fresh full send."
            fi
            bckndZfsSend_mode="incremental"
        else
            bckndZfsSend_mode="full"
        fi

        bckndZfsSend_sendrc_file=$(mktemp)
        bckndZfsSend_recvrc_file=$(mktemp)

        # The actual send|receive pipe. Both sides run in subshells (pipe
        # semantics), so - same lesson as FIX #37, but this time the data
        # itself is a binary stream and can't go through a $(...) capture -
        # each side's exit code is written to its own temp file instead of
        # relying on the pipeline's own $? (which POSIX only defines as the
        # LAST command's exit code) or bash-only $PIPESTATUS. `-s` on every
        # receive is what makes an interruption resumable in the first
        # place - without it, a killed receive just leaves a half-received,
        # unrecoverable dataset.
        case "$bckndZfsSend_mode" in
            resume)
                msg "DEBUG" "Resuming interrupted transfer to $bckndZfsSend_targetdataset (today's new backup, if any, will follow on the next run)"
                msg "DEBUG" "exec_cmd parameters in $LASTFUNC: zfs send -t <token> | zfs receive -s $bckndZfsSend_targetdataset"
                { zfs send -t "$bckndZfsSend_resumetoken"; echo "$?" > "$bckndZfsSend_sendrc_file"; } | \
                { zfs receive -s "$bckndZfsSend_targetdataset"; echo "$?" > "$bckndZfsSend_recvrc_file"; }
                ;;
            full)
                msg "DEBUG" "Full send: $bckndZfsSend_dataset@$bckndZfsSend_label -> $bckndZfsSend_targetdataset"
                msg "DEBUG" "exec_cmd parameters in $LASTFUNC: zfs send $bckndZfsSend_dataset@$bckndZfsSend_label | zfs receive -s $bckndZfsSend_targetdataset"
                { zfs send "$bckndZfsSend_dataset@$bckndZfsSend_label"; echo "$?" > "$bckndZfsSend_sendrc_file"; } | \
                { zfs receive -s "$bckndZfsSend_targetdataset"; echo "$?" > "$bckndZfsSend_recvrc_file"; }
                ;;
            *)
                msg "DEBUG" "Incremental send: $bckndZfsSend_bookmark -> $bckndZfsSend_dataset@$bckndZfsSend_label -> $bckndZfsSend_targetdataset"
                msg "DEBUG" "exec_cmd parameters in $LASTFUNC: zfs send -i $bckndZfsSend_bookmark $bckndZfsSend_dataset@$bckndZfsSend_label | zfs receive -s $bckndZfsSend_targetdataset"
                { zfs send -i "$bckndZfsSend_bookmark" "$bckndZfsSend_dataset@$bckndZfsSend_label"; echo "$?" > "$bckndZfsSend_sendrc_file"; } | \
                { zfs receive -s "$bckndZfsSend_targetdataset"; echo "$?" > "$bckndZfsSend_recvrc_file"; }
                ;;
        esac
        unset bckndZfsSend_resumetoken

        bckndZfsSend_sendrc=$(cat "$bckndZfsSend_sendrc_file")
        bckndZfsSend_recvrc=$(cat "$bckndZfsSend_recvrc_file")
        rm -f "$bckndZfsSend_sendrc_file" "$bckndZfsSend_recvrc_file"
        msg "DEBUG" "send rc=$bckndZfsSend_sendrc, receive rc=$bckndZfsSend_recvrc"

        unset bckndZfsSend_sendrc_file
        unset bckndZfsSend_recvrc_file
        unset bckndZfsSend_remotecmd

        # NOTE: LASTFUNC is deliberately NOT restored to the caller before
        # these err_hdlr calls (fixing a latent bug from step 1, where it
        # was restored too early and would have misattributed the failure
        # to the wrong function in the error log). A failed resume leaves
        # the resume token in place (the mock and real zfs both do this
        # automatically - the token is only cleared on a successful
        # receive), so the next run will simply try to resume again.
        if [ "$bckndZfsSend_sendrc" -ne 0 ]; then
            unset bckndZfsSend_dataset
            unset bckndZfsSend_label
            unset bckndZfsSend_targetdataset
            unset bckndZfsSend_bookmark
            unset bckndZfsSend_mode
            unset bckndZfsSend_keepduration
            unset bckndZfsSend_recvrc
            unset bckndZfsSend_pool
            unset bckndZfsSend_pool_imported_by_us
            err_hdlr "$bckndZfsSend_sendrc"
        fi
        if [ "$bckndZfsSend_recvrc" -ne 0 ]; then
            unset bckndZfsSend_dataset
            unset bckndZfsSend_label
            unset bckndZfsSend_targetdataset
            unset bckndZfsSend_bookmark
            unset bckndZfsSend_mode
            unset bckndZfsSend_keepduration
            unset bckndZfsSend_pool
            unset bckndZfsSend_pool_imported_by_us
            err_hdlr "$bckndZfsSend_recvrc"
        fi

        # FIX #44: for a resumed transfer, the label that actually landed
        # may not be today's $bckndZfsSend_label - it's whatever the
        # interrupted transfer was originally for. Query the target's own
        # newest snapshot instead of trusting the parameter, so the
        # bookmark ends up pointing at what's really there.
        if [ "$bckndZfsSend_mode" = "resume" ]; then
            bckndZfsSend_landedlabel=$(zfs list -H -o name -t snapshot -s creation "$bckndZfsSend_targetdataset" 2>/dev/null | tail -1)
            bckndZfsSend_landedlabel="${bckndZfsSend_landedlabel#*@}"
            if [ -z "$bckndZfsSend_landedlabel" ]; then
                unset bckndZfsSend_dataset
                unset bckndZfsSend_targetdataset
                unset bckndZfsSend_bookmark
                unset bckndZfsSend_mode
                unset bckndZfsSend_sendrc
                unset bckndZfsSend_recvrc
                unset bckndZfsSend_pool
                unset bckndZfsSend_pool_imported_by_us
                die "zfssend: resume of $bckndZfsSend_targetdataset reported success, but no snapshot could be found on the target afterward - refusing to guess which label to bookmark."
            fi
            bckndZfsSend_label="$bckndZfsSend_landedlabel"
            unset bckndZfsSend_landedlabel
            msg "INFO" "zfssend: resumed and completed an interrupted transfer for $bckndZfsSend_dataset@$bckndZfsSend_label to $bckndZfsSend_targetdataset - today's new backup (if different) will be sent on the next run"
        else
            msg "INFO" "zfssend: $bckndZfsSend_mode send of $bckndZfsSend_dataset@$bckndZfsSend_label to $bckndZfsSend_targetdataset succeeded"
        fi
        unset bckndZfsSend_mode

        # FIX #43: move the tracking bookmark forward to the snapshot just
        # sent (or, for a resume, to whatever snapshot actually landed - see
        # above), so the next call can send incrementally from here. Only
        # done after send+receive both succeeded - bookmarking a snapshot
        # that was never actually replicated would silently break the next
        # incremental (it would believe this snapshot IS on the target when
        # it isn't). destroy the old bookmark first: zfs refuses to create
        # one with a name that's already taken, and a bookmark can't be
        # "moved" in place.
        zfs destroy "$bckndZfsSend_bookmark" >/dev/null 2>&1
        exec_cmd zfs bookmark "$bckndZfsSend_dataset@$bckndZfsSend_label" "$bckndZfsSend_bookmark"

        # FIX #45: readonly=on protects the received dataset from
        # accidental manual writes. Real zfs receive (full, incremental, or
        # resumed) still works fine against a readonly=on target -
        # readonly only blocks normal POSIX file writes, not zfs-level
        # receive operations - so this is safe to set unconditionally
        # after every successful send.
        exec_cmd zfs set readonly=on "$bckndZfsSend_targetdataset"

        # FIX #45: target-side retention, reusing pruneZFSSnapshot as-is -
        # it's fully generic (just a dataset name + label + keepduration,
        # nothing source-specific baked in). Without this, the target would
        # accumulate every sent snapshot forever.
        pruneZFSSnapshot "$bckndZfsSend_targetdataset" "$bckndZfsSend_label" "$bckndZfsSend_keepduration" ""

        # FIX #46: export the pool again if WE were the one who imported
        # it - leave an already-attached (permanent) pool alone. A failed
        # export doesn't abort the run (the backup itself already
        # succeeded) - it just means the drive isn't safe to detach yet,
        # which is worth a clear warning but not worth losing the rest of
        # this run's other repos over.
        if [ "$bckndZfsSend_pool_imported_by_us" = 1 ]; then
            if zpool export "$bckndZfsSend_pool" >/dev/null 2>&1; then
                msg "INFO" "zfssend: exported pool '$bckndZfsSend_pool' - safe to detach"
            else
                msg "WARNING" "zfssend: backup succeeded, but pool '$bckndZfsSend_pool' could not be exported afterward - do not detach it yet (check for busy/held datasets)"
            fi
        fi

        LASTFUNC="$bckndZfsSend_CALLINGFUCNTION"
        unset bckndZfsSend_CALLINGFUCNTION
        unset bckndZfsSend_dataset
        unset bckndZfsSend_label
        unset bckndZfsSend_targetdataset
        unset bckndZfsSend_bookmark
        unset bckndZfsSend_keepduration
        unset bckndZfsSend_sendrc
        unset bckndZfsSend_recvrc
        unset bckndZfsSend_pool
        unset bckndZfsSend_pool_imported_by_us
        return 0
    }
fi
