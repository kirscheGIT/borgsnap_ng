#!/bin/sh
# TESTKIT_VERSION=2026-07-20.40
# Mock-based smoke test for borgsnap_ng.
# Runs the full "run" lifecycle against mocked zfs/borg/mount binaries and
# asserts the behavior of fixes #1-#5, #7, #9, #11.
set -u
TESTROOT="$(cd -- "$(dirname "$0")" && pwd -P)"
REPOROOT="$(dirname "$TESTROOT")"
WORKDIR="$(mktemp -d)"

export MOCK_LOG="$WORKDIR/mock.log"
export MOCK_STATE="$WORKDIR/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"

# mocks first in PATH; script re-exports PATH, so we also bind-mount via symlinks
# into a dir the script's hardcoded PATH contains: /usr/local/bin
#
# IMPORTANT: this VM is long-lived (stop/start persists its filesystem), not
# a throwaway container - so these symlinks MUST be removed again on exit.
# Left in place, a stale mock `sudo` (a deliberate no-op passthrough, see
# mocks/sudo) silently stops every future `sudo` call in this VM from
# actually elevating privileges, with no error - this bit us for real once
# already. BACKUP_DIR preserves anything that legitimately existed at these
# paths before we touched them (unlikely for these names, but not
# impossible), so cleanup restores the prior state exactly rather than just
# deleting.
BACKUP_DIR="$WORKDIR/path-backup"
mkdir -p "$BACKUP_DIR"

cleanup_mocks() {
  for b in zfs zpool borg mount umount sudo date sendmail ssh; do
    if [ -e "$BACKUP_DIR/$b" ] || [ -L "$BACKUP_DIR/$b" ]; then
      mv "$BACKUP_DIR/$b" "/usr/local/bin/$b"
    else
      rm -f "/usr/local/bin/$b"
    fi
  done
}
trap cleanup_mocks EXIT INT TERM HUP

for b in zfs zpool borg mount umount sudo date sendmail ssh; do
  if [ -e "/usr/local/bin/$b" ] || [ -L "/usr/local/bin/$b" ]; then
    mv "/usr/local/bin/$b" "$BACKUP_DIR/$b"
  fi
  ln -sf "$TESTROOT/mocks/$b" "/usr/local/bin/$b"
done

mkdir -p "$WORKDIR/repo1" "$WORKDIR/repo2" "$WORKDIR/snapmnt"
KEYFILE="$WORKDIR/test.key"; echo "testpassphrase" > "$KEYFILE"

cat > "$WORKDIR/test.conf" << EOF
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,r; tank/home,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$KEYFILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR/repo1, ; $WORKDIR/repo2, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF

# Pre-seed snapshot state: existing monthly & weekly so today becomes a daily,
# plus 9 old dailies so prune has 2+ to delete (keep 7).
for d in 01 02 03 04 05 06 07 08 09; do
  echo "tank/data@daily-202607$d" >> "$MOCK_STATE"
  echo "tank/home@daily-202607$d" >> "$MOCK_STATE"
done
echo "tank/data@monthly-20260701" >> "$MOCK_STATE"
echo "tank/home@monthly-20260701" >> "$MOCK_STATE"
echo "tank/data@weekly-20260712" >> "$MOCK_STATE"
echo "tank/home@weekly-20260712" >> "$MOCK_STATE"

cd "$REPOROOT"
sh ./borgsnap_ng.sh run "$WORKDIR/test.conf" > "$WORKDIR/run.log" 2>&1
RC=$?

PASS_CNT=0; FAIL_CNT=0
assert() { # $1 description, $2 command
  if eval "$2" > /dev/null 2>&1; then
    echo "PASS: $1"; PASS_CNT=$((PASS_CNT+1))
  else
    echo "FAIL: $1"; FAIL_CNT=$((FAIL_CNT+1))
  fi
}

assert "run finishes with exit code 0 (rc=$RC)" "[ $RC -eq 0 ]"
assert "FIX2: recursive snapshot taken for tank/data (zfs snapshot -r)" \
  "grep -q 'zfs snapshot -r tank/data@daily-' '$MOCK_LOG'"
assert "FIX2: non-recursive snapshot for tank/home (no -r)" \
  "grep 'zfs snapshot tank/home@daily-' '$MOCK_LOG'"
assert "FIX1: borg prune restricted via --glob-archives 'daily-*'" \
  "grep 'borg prune' '$MOCK_LOG' | grep -q 'glob-archives tank_data-daily-\\|glob-archives tank_home-daily-'"
assert "FIX4: no accumulated duplicate --keep flags in any prune call" \
  "! grep 'borg prune' '$MOCK_LOG' | grep -q 'keep-daily=7.*--keep-daily=7'"
assert "FIX3: zfs destroy issued for old snapshots (prune works again)" \
  "grep -q 'zfs destroy -r tank/' '$MOCK_LOG'"
assert "FIX3: oldest daily (20260701) destroyed, newest kept" \
  "grep -q 'zfs destroy -r tank/data@daily-20260701' '$MOCK_LOG' && ! grep -q 'destroy -r tank/data@daily-20260709' '$MOCK_LOG'"
assert "FIX55: unmount happens before pruning destroys old snapshots, not after" \
  "[ \"\$(grep -n 'umount .*/tank/data\$' '$MOCK_LOG' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'zfs destroy -r tank/data@daily-20260701' '$MOCK_LOG' | head -1 | cut -d: -f1)\" ]"
assert "FIX5: umount called for real mountpoints (depth 2)" \
  "grep -q 'umount .*/tank/data' '$MOCK_LOG'"
assert "FIX5: recursive child mount also unmounted" \
  "grep -q 'umount .*/tank/data/child' '$MOCK_LOG'"
assert "FIX52: the top-level dataset itself is mounted, not just its child" \
  "grep -q \"mount -t zfs tank/data@\" '$MOCK_LOG'"
assert "FIX39: snapshot mount base is /run/borgsnap, not /tmp" \
  "grep -q '/run/borgsnap/tank/data' '$MOCK_LOG' && ! grep -q '/tmp/borgsnap_ng' '$MOCK_LOG'"
assert "FIX7: no pgrep wait loop hangs (run.log has no waiting messages)" \
  "! grep -q 'Waiting for the' '$WORKDIR/run.log'"
assert "borg create called once per repo per dataset (4 creates)" \
  "[ \$(grep -c 'borg create' '$MOCK_LOG') -eq 4 ]"
assert "FIX9: lock released after run" "[ ! -d '$BORGSNAP_LOCKDIR' ]"

# FIX9: second instance must be rejected while lock is held
mkdir -p "$BORGSNAP_LOCKDIR"; echo 99999999 > "$BORGSNAP_LOCKDIR/pid"
sh ./borgsnap_ng.sh run "$WORKDIR/test.conf" > "$WORKDIR/run2.log" 2>&1
assert "FIX9: stale lock (dead pid) is detected and removed" \
  "grep -q 'stale lock' '$WORKDIR/run2.log' || [ ! -d '$BORGSNAP_LOCKDIR' ]"

echo "-------------------------------------"
echo "Error-path fixes (FIX #35-#37)"
echo "-------------------------------------"

WORKDIR2="$(mktemp -d)"
mkdir -p "$WORKDIR2/repo1" "$WORKDIR2/repo2"
cat > "$WORKDIR2/test2.conf" << EOF2
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$KEYFILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR2/repo1, ; $WORKDIR2/repo2, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF2

export MOCK_LOG="$WORKDIR2/mock.log"
export MOCK_STATE="$WORKDIR2/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR2/lock"

# --- Scenario A: a failing "zfs list" must abort the run (FIX #37) -----
# Before the fix, exec_cmd piped directly into grep ran in a subshell, so
# a failing zfs list was silently swallowed - the run finished with exit 0
# as if nothing had happened.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_FAIL_LIST=1 sh ./borgsnap_ng.sh run "$WORKDIR2/test2.conf" > "$WORKDIR2/run_zfsfail.log" 2>&1
RC_ZFSFAIL=$?
assert "FIX37: a failing 'zfs list' aborts the run (was silently swallowed)" \
  "[ $RC_ZFSFAIL -ne 0 ]"
assert "FIX38: the zfs list failure is caught directly, not via an unrelated downstream cascade" \
  "grep -q 'ERROR: Got exit code 1 in Function startBackupMachine' '$WORKDIR2/run_zfsfail.log' && ! grep -q \"Source directory doesn't exist\" '$WORKDIR2/run_zfsfail.log'"

# --- Scenario B: borg create failing for ONE repo must not abort the run,
#     must be reported, and the other repo must still get its archive
#     (FIX #36). Before the fix this produced zero output outside DEBUG
#     mode - the failure was completely invisible. ----------------------
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_FAIL_CREATE_REPO="$WORKDIR2/repo1" sh ./borgsnap_ng.sh run "$WORKDIR2/test2.conf" > "$WORKDIR2/run_borgfail.log" 2>&1
RC_BORGFAIL=$?
assert "FIX36: run still succeeds overall when one repo's create fails" \
  "[ $RC_BORGFAIL -eq 0 ]"
assert "FIX36: the failure is visible in the run output" \
  "grep -q 'borg create failed' '$WORKDIR2/run_borgfail.log'"
assert "FIX36: the OTHER repo still received a create attempt" \
  "grep -q \"borg create.*$WORKDIR2/repo2\" '$MOCK_LOG'"

echo "-------------------------------------"
echo "Config permission checks (FIX #40)"
echo "-------------------------------------"

PERM644="$WORKDIR2/insecure.key"; echo "x" > "$PERM644"; chmod 644 "$PERM644"
PERM600="$WORKDIR2/secure.key"; echo "x" > "$PERM600"; chmod 600 "$PERM600"

PERM_OUT=$(
  cd "$REPOROOT" || exit 1
  msg() { echo "MSG[$*]"; }
  export MSG_DEFINED=1 LASTFUNC=""
  # shellcheck disable=SC1091
  . ./common/msg_and_err_hdlr.sh
  # shellcheck disable=SC1091
  . ./cfg_file_hdlr.sh
  checkFilePerms "$PERM644" "insecure test file"
  checkFilePerms "$PERM600" "secure test file"
)

assert "FIX40: insecure (644) file triggers a permission warning" \
  "printf '%s\n' \"\$PERM_OUT\" | grep -q 'insecure test file.*is readable or writable by group/others'"
assert "FIX40: secure (600) file does NOT trigger a warning" \
  "! printf '%s\n' \"\$PERM_OUT\" | grep -q \"\$PERM600.*is readable or writable\""

echo "-------------------------------------"
echo "Backend split (FIX #41)"
echo "-------------------------------------"

# FIX #41a: pruneZFSSnapshot must run once per dataset/interval, not once
# per repo. Empirically verified (not just asserted): the same scenario
# with the old per-repo-loop placement produces 22 "zfs list -H -t
# snapshot -o name" calls in $MOCK_LOG; with the fix, exactly 18. Fewer
# repos would shrink the gap, more would widen it - this exact count is
# specific to this test's 2 datasets x 2 repos x 2 intervals-checked setup.
assert "FIX41a: pruneZFSSnapshot runs once per dataset, not once per repo (18 zfs list calls, not 22)" \
  "[ \$(grep -c 'zfs list -H -t snapshot -o name\$' '$WORKDIR/mock.log') -eq 18 ]"

WORKDIR3="$(mktemp -d)"
mkdir -p "$WORKDIR3/repo1"
cat > "$WORKDIR3/test3.conf" << EOF3
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$KEYFILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="borg:$WORKDIR3/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF3

export MOCK_LOG="$WORKDIR3/mock.log"
export MOCK_STATE="$WORKDIR3/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR3/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"

# FIX #41b: an explicit "borg:" prefix must behave identically to no prefix.
sh ./borgsnap_ng.sh run "$WORKDIR3/test3.conf" > "$WORKDIR3/run_borgprefix.log" 2>&1
RC_BORGPREFIX=$?
assert "FIX41b: explicit 'borg:' prefix run succeeds" "[ $RC_BORGPREFIX -eq 0 ]"
assert "FIX41b: explicit 'borg:' prefix still creates a borg archive" \
  "grep -q \"borg create.*$WORKDIR3/repo1\" '$MOCK_LOG'"

# FIX #42/#43: zfs-send backend. Step 1 (full send only) plus step 3
# (bookmark-based incremental, skipping the fragile plain-snapshot
# intermediate step 2 entirely - see conversation).
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sed "s|REPOLIST=.*|REPOLIST=\"zfssend:tank/zfssendtarget, \"|" "$WORKDIR3/test3.conf" > "$WORKDIR3/test3-zfssend.conf"

# First run: target doesn't exist yet -> the full send must succeed, and a
# tracking bookmark must be created afterward.
sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend1.log" 2>&1
RC_ZFSSEND1=$?
assert "FIX42: first zfssend run (fresh target) succeeds" "[ $RC_ZFSSEND1 -eq 0 ]"
assert "FIX42: zfs send (full, no -i) was invoked for the source snapshot" \
  "grep -q 'zfs send tank/data@' '$MOCK_LOG'"
assert "FIX42: zfs receive -s was invoked for the mirrored target path" \
  "grep -q 'zfs receive -s -F tank/zfssendtarget/tank/data' '$MOCK_LOG'"
assert "FIX42: target dataset exists after the send (mirrored under the target prefix)" \
  "grep -q '^tank/zfssendtarget/tank/data' '$MOCK_STATE'"
assert "FIX43: tracking bookmark was created after the first send" \
  "grep -q '^tank/data#zfssend-tank_zfssendtarget\$' '$MOCK_STATE'"

# Second run against the SAME (now-existing) target: must send
# incrementally FROM THE BOOKMARK (not a plain snapshot, not a full send),
# and move the bookmark forward to the new snapshot afterward.
: > "$MOCK_LOG"
sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend2.log" 2>&1
RC_ZFSSEND2=$?
assert "FIX43: second zfssend run (incremental via bookmark) succeeds" "[ $RC_ZFSSEND2 -eq 0 ]"
assert "FIX43: zfs send -i used the bookmark as its base, not a plain snapshot" \
  "grep -q 'zfs send -i tank/data#zfssend-tank_zfssendtarget tank/data@' '$MOCK_LOG'"
assert "FIX43: bookmark still exists (recreated), pointing at the new snapshot" \
  "grep -q '^tank/data#zfssend-tank_zfssendtarget\$' '$MOCK_STATE'"

# Simulate a manually deleted bookmark while the target still exists - must
# fail with the specific, actionable message, not silently re-send
# everything or corrupt the target.
zfs destroy "tank/data#zfssend-tank_zfssendtarget"
: > "$MOCK_LOG"
sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend3.log" 2>&1
RC_ZFSSEND3=$?
assert "FIX43: target exists but bookmark missing -> run fails" "[ $RC_ZFSSEND3 -ne 0 ]"
assert "FIX43: missing-bookmark run gives the specific actionable message" \
  "grep -q 'tracking bookmark' '$WORKDIR3/run_zfssend3.log' && grep -q 'is missing' '$WORKDIR3/run_zfssend3.log'"
assert "FIX53: die() cleans up the mount that happened before it fired, not just err_hdlr" \
  "grep -q 'umount ' '$MOCK_LOG'"

# Fault injection on both sides of the send|receive pipe - this is the
# whole point of the dual-tempfile exit-code pattern (see the comment in
# backendZfsSend): each side's real exit code must be caught
# independently, not just whichever happens to be the pipeline's last
# command.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_FAIL_SEND=1 sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_sendfail.log" 2>&1
RC_SENDFAIL=$?
# FIX #59: a failing send no longer aborts the whole run - it's reported
# loudly and the dispatch loop continues, matching FIX #36's "one
# destination's problem doesn't block the others" philosophy (this
# config only has the one zfssend repo, so the overall run now succeeds).
assert "FIX59: a failing zfs send is reported but does not abort the run" "[ $RC_SENDFAIL -eq 0 ]"
assert "FIX59: the send failure is clearly logged" \
  "grep -q 'zfssend: send failed' '$WORKDIR3/run_zfssend_sendfail.log'"

: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_FAIL_RECEIVE=1 sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_recvfail.log" 2>&1
RC_RECVFAIL=$?
assert "FIX59: a failing zfs receive is reported but does not abort the run" "[ $RC_RECVFAIL -eq 0 ]"
assert "FIX59: the receive failure is clearly logged" \
  "grep -q 'zfssend: receive failed' '$WORKDIR3/run_zfssend_recvfail.log'"

# FIX #43: a failing bookmark creation (after a successful send/receive)
# must also abort the run, not silently leave the target without a usable
# tracking bookmark for next time.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_FAIL_BOOKMARK=1 sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_bookmarkfail.log" 2>&1
RC_BOOKMARKFAIL=$?
assert "FIX43: a failing bookmark creation aborts the run" "[ $RC_BOOKMARKFAIL -ne 0 ]"
assert "FIX43: send and receive DID succeed before the bookmark failure (data wasn't lost)" \
  "grep -q '^tank/zfssendtarget/tank/data' '$MOCK_STATE'"

echo "-------------------------------------"
echo "Resumable receive (FIX #44)"
echo "-------------------------------------"

: > "$MOCK_LOG"; : > "$MOCK_STATE"

# An interrupted first-ever send: the run must fail, and a resume token
# must be left behind - not silently lost, not a hard unrecoverable
# failure.
MOCK_ZFS_INTERRUPT_RECEIVE=1 sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_interrupt1.log" 2>&1
RC_INTERRUPT1=$?
# FIX #59: an interrupted send is now reported and gracefully skipped
# rather than aborting the whole run (this config only has the one
# zfssend repo, so the overall run succeeds) - the resume token still
# gets left behind exactly as before, so the next run picks up the resume
# normally.
assert "FIX59: an interrupted send is reported but does not abort the run" "[ $RC_INTERRUPT1 -eq 0 ]"
assert "FIX44: a resume token is left behind after interruption" \
  "grep -q '^tank/zfssendtarget/tank/data::resume::' '$MOCK_STATE'"

# The next run (no interrupt flag) must detect and complete the resume via
# 'zfs send -t', not attempt a fresh send.
: > "$MOCK_LOG"
sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_resume.log" 2>&1
RC_RESUME=$?
assert "FIX44: the next run resumes and succeeds" "[ $RC_RESUME -eq 0 ]"
assert "FIX44: zfs send -t (resume) was used, not a fresh send" \
  "grep -q 'zfs send -t MOCKTOKEN' '$MOCK_LOG'"
assert "FIX44: exactly one snapshot landed on the target (the resumed one only - today's new backup is deferred to the next run)" \
  "[ \$(zfs list -H -t snapshot -o name tank/zfssendtarget/tank/data 2>/dev/null | wc -l) -eq 1 ]"
assert "FIX44: resume token is cleared after successful completion" \
  "! grep -q '^tank/zfssendtarget/tank/data::resume::' '$MOCK_STATE'"
assert "FIX44: bookmark exists, pointing at the resumed (originally interrupted) label" \
  "grep -q '^tank/data#zfssend-tank_zfssendtarget\$' '$MOCK_STATE'"

# A second interruption DURING the resume attempt itself: the token must
# survive so a future run can retry - it must not be silently lost just
# because the retry also failed.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_INTERRUPT_RECEIVE=1 sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > /dev/null 2>&1
MOCK_ZFS_INTERRUPT_RECEIVE=1 sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_doubleinterrupt.log" 2>&1
RC_DOUBLEINTERRUPT=$?
assert "FIX59: a second interruption during resume is reported but does not abort the run" "[ $RC_DOUBLEINTERRUPT -eq 0 ]"
assert "FIX44: resume token survives a repeated interruption (not lost)" \
  "grep -q '^tank/zfssendtarget/tank/data::resume::' '$MOCK_STATE'"

echo "-------------------------------------"
echo "Target readonly + retention (FIX #45)"
echo "-------------------------------------"

# readonly=on: dedicated fresh full-send scenario (can't reuse an earlier
# scenario's log - it's been reset multiple times since by the FIX43/44
# tests).
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_readonly.log" 2>&1
RC_READONLY=$?
assert "FIX45: fresh zfssend run for the readonly check succeeds" "[ $RC_READONLY -eq 0 ]"
assert "FIX45: readonly=on is set on the target after a successful send" \
  "grep -q 'zfs set readonly=on tank/zfssendtarget/tank/data' '$MOCK_LOG'"

# Direct unit-style test of pruneZFSSnapshot reused against a target
# dataset - proves the exact claim step 5 relies on: the function is fully
# generic and needs no target-specific variant. Pre-seed 9 old daily
# snapshots (matching the keep-daily=7 used elsewhere in this test) plus
# today's, so pruning has real work to do.
: > "$MOCK_STATE"; : > "$MOCK_LOG"
for d in 01 02 03 04 05 06 07 08 09 10; do
  echo "tank/prunetarget/tank/data@daily-202607$d" >> "$MOCK_STATE"
done

(
  cd "$REPOROOT" || exit 1
  msg() { :; }
  export MSG_DEFINED=1 LASTFUNC=""
  # shellcheck disable=SC1091
  . ./common/msg_and_err_hdlr.sh
  # shellcheck disable=SC1091
  . ./filesystem/zfs_hdlr.sh
  pruneZFSSnapshot "tank/prunetarget/tank/data" "daily-99999999" "7" ""
) >/dev/null 2>&1

assert "FIX45: target-side prune (via reused pruneZFSSnapshot) destroys exactly the oldest 3 (10 found, keep 7)" \
  "[ \$(grep -c 'zfs destroy -r tank/prunetarget/tank/data@' '$MOCK_LOG') -eq 3 ]"
assert "FIX45: target-side prune keeps the newest snapshot (daily-20260710)" \
  "! grep -q 'zfs destroy -r tank/prunetarget/tank/data@daily-20260710' '$MOCK_LOG'"
assert "FIX45: target-side prune destroys the oldest (daily-20260701)" \
  "grep -q 'zfs destroy -r tank/prunetarget/tank/data@daily-20260701' '$MOCK_LOG'"

echo "-------------------------------------"
echo "Pool lifecycle for removable targets (FIX #46)"
echo "-------------------------------------"

WORKDIR4="$(mktemp -d)"
cat > "$WORKDIR4/test4-zfssend.conf" << EOF4
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$KEYFILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="zfssend:usbpool/backups, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF4

export MOCK_LOG="$WORKDIR4/mock.log"
export MOCK_STATE="$WORKDIR4/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR4/lock"

: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZPOOL_NOT_IMPORTED="usbpool" sh ./borgsnap_ng.sh run "$WORKDIR4/test4-zfssend.conf" > "$WORKDIR4/run_pool_import.log" 2>&1
RC_POOLIMPORT=$?
assert "FIX46: run succeeds when the target pool needs importing first" "[ $RC_POOLIMPORT -eq 0 ]"
assert "FIX46: zpool import was attempted" "grep -q 'zpool import usbpool' '$MOCK_LOG'"
assert "FIX46: zpool export happened afterward (we imported it ourselves)" "grep -q 'zpool export usbpool' '$MOCK_LOG'"
assert "FIX46: the actual backup still happened" "grep -q 'zfs receive -s -F usbpool/backups/tank/data' '$MOCK_LOG'"

: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZPOOL_NOT_IMPORTED="usbpool" MOCK_ZPOOL_FAIL_IMPORT=1 sh ./borgsnap_ng.sh run "$WORKDIR4/test4-zfssend.conf" > "$WORKDIR4/run_pool_notattached.log" 2>&1
RC_POOLNOTATTACHED=$?
assert "FIX46: run still succeeds overall when the target pool can't be imported (not attached)" "[ $RC_POOLNOTATTACHED -eq 0 ]"
assert "FIX46: a clear warning about the unavailable pool is shown" \
  "grep -q 'could not be imported' '$WORKDIR4/run_pool_notattached.log'"
assert "FIX46: no send/receive was attempted for the unavailable target" \
  "! grep -q 'zfs receive -s usbpool' '$MOCK_LOG'"

: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR4/test4-zfssend.conf" > "$WORKDIR4/run_pool_alreadyimported.log" 2>&1
RC_POOLALREADY=$?
assert "FIX46: run succeeds when the target pool was already imported" "[ $RC_POOLALREADY -eq 0 ]"
assert "FIX46: no zpool import was attempted (it was already there)" "! grep -q 'zpool import' '$MOCK_LOG'"
assert "FIX46: no zpool export happened (we didn't import it, so we leave it alone)" \
  "! grep -q 'zpool export' '$MOCK_LOG'"

: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZPOOL_NOT_IMPORTED="usbpool" MOCK_ZPOOL_FAIL_EXPORT=1 sh ./borgsnap_ng.sh run "$WORKDIR4/test4-zfssend.conf" > "$WORKDIR4/run_pool_exportfail.log" 2>&1
RC_POOLEXPORTFAIL=$?
assert "FIX46: run still succeeds when the pool export fails afterward" "[ $RC_POOLEXPORTFAIL -eq 0 ]"
assert "FIX46: a clear warning about the failed export is shown" \
  "grep -q 'could not be exported afterward' '$WORKDIR4/run_pool_exportfail.log'"

WORKDIR5="$(mktemp -d)"
mkdir -p "$WORKDIR5/repo1"
cat > "$WORKDIR5/test5-mixed.conf" << EOF5
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$KEYFILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="borg:$WORKDIR5/repo1, ; zfssend:usbpool/backups, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF5

export MOCK_LOG="$WORKDIR5/mock.log"
export MOCK_STATE="$WORKDIR5/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR5/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZPOOL_NOT_IMPORTED="usbpool" MOCK_ZPOOL_FAIL_IMPORT=1 sh ./borgsnap_ng.sh run "$WORKDIR5/test5-mixed.conf" > "$WORKDIR5/run_mixed.log" 2>&1
RC_MIXED=$?
assert "FIX46: mixed repolist (borg + unavailable zfssend) still succeeds overall" "[ $RC_MIXED -eq 0 ]"
assert "FIX46: the borg repo still got its backup despite the zfssend target being unavailable" \
  "grep -q \"borg create.*$WORKDIR5/repo1\" '$MOCK_LOG'"

echo "-------------------------------------"
echo "Mail notification wrapper (FIX #47)"
echo "-------------------------------------"

WORKDIR6="$(mktemp -d)"
mkdir -p "$WORKDIR6/repo1"
MAILKEYFILE="$WORKDIR6/mail_test.key"; echo "testpassphrase" > "$MAILKEYFILE"; chmod 600 "$MAILKEYFILE"
cat > "$WORKDIR6/test6-mail.conf" << EOF6
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR6/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MAILTO="admin@example.com"
EOF6
chmod 600 "$WORKDIR6/test6-mail.conf"

export MOCK_LOG="$WORKDIR6/mock.log"
export MOCK_STATE="$WORKDIR6/mock.state"
export MOCK_MAIL_LOG="$WORKDIR6/mail.log"
export BORGSNAP_LOCKDIR="$WORKDIR6/lock"

# Scenario A: successful run -> SUCCESS subject, no priority headers, the
# wrapper's own exit code matches the (successful) backup.
: > "$MOCK_LOG"; : > "$MOCK_STATE"; : > "$MOCK_MAIL_LOG"
sh ./mail_wrapper.sh "$WORKDIR6/test6-mail.conf" > "$WORKDIR6/wrap_success.log" 2>&1
RC_MAILSUCCESS=$?
assert "FIX47: mail wrapper forwards a successful run's exit code (0)" "[ $RC_MAILSUCCESS -eq 0 ]"
assert "FIX47: success email has the correct subject" \
  "grep -q '^Subject: \[borgsnap_ng\] SUCCESS:' '$MOCK_MAIL_LOG'"
assert "FIX47: success email has NO high-priority headers" \
  "! grep -q 'X-Priority' '$MOCK_MAIL_LOG'"
assert "FIX47: success email is addressed to MAILTO from the config" \
  "grep -q '^To: admin@example.com' '$MOCK_MAIL_LOG'"

# Scenario B: failing run - FAILURE subject, high-priority headers, and the
# wrapper's exit code must be the REAL (nonzero) backup exit code, not
# swallowed by the mail-sending step that runs after it.
: > "$MOCK_LOG"; : > "$MOCK_STATE"; : > "$MOCK_MAIL_LOG"
MOCK_ZFS_FAIL_LIST=1 sh ./mail_wrapper.sh "$WORKDIR6/test6-mail.conf" > "$WORKDIR6/wrap_failure.log" 2>&1
RC_MAILFAILURE=$?
assert "FIX47: mail wrapper forwards a failing run's real (nonzero) exit code" "[ $RC_MAILFAILURE -ne 0 ]"
assert "FIX47: failure email has the correct subject" \
  "grep -q '^Subject: \[borgsnap_ng\] FAILURE:' '$MOCK_MAIL_LOG'"
assert "FIX47: failure email has high-priority headers" \
  "grep -q '^X-Priority: 1' '$MOCK_MAIL_LOG' && grep -q '^Importance: High' '$MOCK_MAIL_LOG'"
assert "FIX47: failure email states the same exit code the wrapper itself returned" \
  "grep -q \"Exit code:       $RC_MAILFAILURE\" '$MOCK_MAIL_LOG'"

# Scenario C: no MAILTO configured - the backup still runs normally, no
# email is attempted at all (not even an empty/broken one).
cat > "$WORKDIR6/test6-nomail.conf" << EOF7
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$KEYFILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR6/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF7
: > "$MOCK_LOG"; : > "$MOCK_STATE"; : > "$MOCK_MAIL_LOG"
sh ./mail_wrapper.sh "$WORKDIR6/test6-nomail.conf" > "$WORKDIR6/wrap_nomail.log" 2>&1
RC_NOMAIL=$?
assert "FIX47: without MAILTO, the run still succeeds normally" "[ $RC_NOMAIL -eq 0 ]"
assert "FIX47: without MAILTO, no email is sent" "[ ! -s '$MOCK_MAIL_LOG' ]"

echo "-------------------------------------"
echo "Success-with-warnings escalation (FIX #48)"
echo "-------------------------------------"

# Deliberately NOT chmod 600 - checkFilePerms (FIX #40) will warn about it,
# even though the backup itself succeeds. That's exactly the case FIX #48
# closes: without it, this warning would be buried, unremarked, inside an
# ordinary SUCCESS email.
cat > "$WORKDIR6/test6-warn.conf" << EOF8
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$KEYFILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR6/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MAILTO="admin@example.com"
EOF8

: > "$MOCK_LOG"; : > "$MOCK_STATE"; : > "$MOCK_MAIL_LOG"
sh ./mail_wrapper.sh "$WORKDIR6/test6-warn.conf" > "$WORKDIR6/wrap_warn.log" 2>&1
RC_MAILWARN=$?
assert "FIX48: a run with only a permission warning still succeeds (exit 0)" "[ $RC_MAILWARN -eq 0 ]"
assert "FIX48: subject is escalated to SUCCESS (with warnings)" \
  "grep -q '^Subject: \[borgsnap_ng\] SUCCESS (with warnings):' '$MOCK_MAIL_LOG'"
assert "FIX48: priority is elevated (High) but not maximum (not the FAILURE level)" \
  "grep -q '^X-Priority: 2 (High)' '$MOCK_MAIL_LOG' && ! grep -q '^X-Priority: 1' '$MOCK_MAIL_LOG'"
assert "FIX48: the warning is summarized before the full log, not just buried in it" \
  "grep -q 'warning(s) detected' '$MOCK_MAIL_LOG'"
assert "FIX48: the actual warning text is included in the summary" \
  "grep -q 'is readable or writable by group/others' '$MOCK_MAIL_LOG'"

echo "-------------------------------------"
echo "Script directory resolution (FIX #49)"
echo "-------------------------------------"

# All the tests above always `cd "$REPOROOT"` before invoking
# borgsnap_ng.sh - which would have silently masked a real bug: the
# script's own ". ./..." sourcing lines are relative, so it only worked
# when CWD already happened to be the script's own directory. This
# section deliberately runs from somewhere else entirely, via an absolute
# path, to guard against that regressing.
WORKDIR7="$(mktemp -d)"
mkdir -p "$WORKDIR7/repo1"
MAILKEYFILE7="$WORKDIR7/test7.key"; echo "testpassphrase" > "$MAILKEYFILE7"; chmod 600 "$MAILKEYFILE7"
cat > "$WORKDIR7/test7.conf" << EOF9
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE7"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR7/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF9
chmod 600 "$WORKDIR7/test7.conf"

export MOCK_LOG="$WORKDIR7/mock.log"
export MOCK_STATE="$WORKDIR7/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR7/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"

WORKDIR7_ELSEWHERE="$(mktemp -d)"
( cd "$WORKDIR7_ELSEWHERE" && sh "$REPOROOT/borgsnap_ng.sh" run "$WORKDIR7/test7.conf" > "$WORKDIR7/run_absolute.log" 2>&1 )
RC_ABSPATH=$?
assert "FIX49: invoked via absolute path from a directory other than the repo root, the run still succeeds" \
  "[ $RC_ABSPATH -eq 0 ]"
assert "FIX49: it did not fail trying to source its own dependencies" \
  "! grep -q 'cannot open.*msg_and_err_hdlr' '$WORKDIR7/run_absolute.log'"

# A relative config-file argument must resolve against the CALLER's cwd
# (where $WORKDIR7/test7.conf's directory is), not the script's own
# directory.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
( cd "$WORKDIR7" && sh "$REPOROOT/borgsnap_ng.sh" run "test7.conf" > "$WORKDIR7/run_relative.log" 2>&1 )
RC_RELPATH=$?
assert "FIX49: a relative config path resolves against the caller's cwd, not the script's own directory" \
  "[ $RC_RELPATH -eq 0 ]"

echo "-------------------------------------"
echo "BorgBase repo-state detection (FIX #50)"
echo "-------------------------------------"

WORKDIR8="$(mktemp -d)"
MAILKEYFILE8="$WORKDIR8/test8.key"; echo "testpassphrase" > "$MAILKEYFILE8"; chmod 600 "$MAILKEYFILE8"
cat > "$WORKDIR8/test8-borgbase.conf" << EOF10
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE8"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="borgbase:ssh://borgbase_repo/./repo, borg, repokey-blake2"
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF10
chmod 600 "$WORKDIR8/test8-borgbase.conf"

export MOCK_LOG="$WORKDIR8/mock.log"
export MOCK_STATE="$WORKDIR8/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR8/lock"

# Scenario A: repo exists but not yet initialized (rc 15) -> borg init runs
# with the configured encryption mode, then create/prune proceed normally.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_LIST_RC=15 sh ./borgsnap_ng.sh run "$WORKDIR8/test8-borgbase.conf" > "$WORKDIR8/run_needinit.log" 2>&1
RC_NEEDINIT=$?
assert "FIX50: rc 15 (not yet initialized) - run succeeds" "[ $RC_NEEDINIT -eq 0 ]"
assert "FIX50: borg list was used to check repo state" "grep -q '^borg list' '$MOCK_LOG'"
assert "FIX50: borg init ran with the configured encryption mode" \
  "grep -q '^borg init --encryption=repokey-blake2' '$MOCK_LOG'"
assert "FIX50: borg create still ran afterward" "grep -q '^borg create' '$MOCK_LOG'"
assert "FIX50: no shell ls/mkdir was attempted (BorgBase can't run those at all)" \
  "! grep -qE '^(ls|mkdir) ' '$MOCK_LOG'"

# Scenario B: repo already initialized (rc 0) -> no init, straight to create.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
echo "BORG_INIT:ssh://borgbase_repo/./repo" >> "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR8/test8-borgbase.conf" > "$WORKDIR8/run_alreadyinit.log" 2>&1
RC_ALREADYINIT=$?
assert "FIX50: rc 0 (already initialized) - run succeeds" "[ $RC_ALREADYINIT -eq 0 ]"
assert "FIX50: borg init was NOT called (already initialized)" "! grep -q '^borg init' '$MOCK_LOG'"
assert "FIX50: borg create still ran" "grep -q '^borg create' '$MOCK_LOG'"

# Scenario C: genuinely wrong path (rc 13) - BorgBase can't create one for
# us, so this must be a clear, actionable configuration error, not a crash.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_LIST_RC=13 sh ./borgsnap_ng.sh run "$WORKDIR8/test8-borgbase.conf" > "$WORKDIR8/run_wrongpath.log" 2>&1
RC_WRONGPATH=$?
assert "FIX50/FIX71: rc 13 (does not exist) - run still succeeds overall (this repo is skipped, not fatal)" "[ $RC_WRONGPATH -eq 0 ]"
assert "FIX50: the error explains BorgBase repos need the web UI" \
  "grep -q 'must be created via their web UI first' '$WORKDIR8/run_wrongpath.log'"
assert "FIX50: borg init was NOT attempted for a genuinely wrong path" "! grep -q '^borg init' '$MOCK_LOG'"

# Scenario D: an unexpected exit code - surfaced clearly, not silently
# misinterpreted as either state.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_LIST_RC=2 sh ./borgsnap_ng.sh run "$WORKDIR8/test8-borgbase.conf" > "$WORKDIR8/run_unexpected.log" 2>&1
RC_UNEXPECTED=$?
assert "FIX50/FIX71: an unexpected borg list exit code still lets the run succeed overall (this repo is skipped, not fatal)" "[ $RC_UNEXPECTED -eq 0 ]"
assert "FIX50: the error surfaces the unexpected exit code" "grep -q 'unexpectedly' '$WORKDIR8/run_unexpected.log'"

# Default encryption: a borgbase entry with NO third REPOLIST field must
# still default to repokey, matching every other repo type unchanged.
cat > "$WORKDIR8/test8-borgbase-noenc.conf" << EOF11
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE8"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="borgbase:ssh://borgbase_repo/./repo, borg"
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF11
chmod 600 "$WORKDIR8/test8-borgbase-noenc.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_LIST_RC=15 sh ./borgsnap_ng.sh run "$WORKDIR8/test8-borgbase-noenc.conf" > "$WORKDIR8/run_noenc.log" 2>&1
RC_NOENC=$?
assert "FIX50: no encryption field specified - run still succeeds" "[ $RC_NOENC -eq 0 ]"
assert "FIX50: defaults to repokey when no encryption field is given" \
  "grep -q '^borg init --encryption=repokey ' '$MOCK_LOG'"

echo "-------------------------------------"
echo "zfssend leading-slash target validation (FIX #51)"
echo "-------------------------------------"

WORKDIR9="$(mktemp -d)"
MAILKEYFILE9="$WORKDIR9/test9.key"; echo "testpassphrase" > "$MAILKEYFILE9"; chmod 600 "$MAILKEYFILE9"
cat > "$WORKDIR9/test9-leadingslash.conf" << EOF12
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE9"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="zfssend:/borgsnap_test_zfs_rcv, ;"
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF12
chmod 600 "$WORKDIR9/test9-leadingslash.conf"

export MOCK_LOG="$WORKDIR9/mock.log"
export MOCK_STATE="$WORKDIR9/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR9/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR9/test9-leadingslash.conf" > "$WORKDIR9/run_leadingslash.log" 2>&1
RC_LEADINGSLASH=$?
assert "FIX51: a leading-slash target fails the run (not a silent empty-pool cascade)" "[ $RC_LEADINGSLASH -ne 0 ]"
assert "FIX51: the error names the actual problem (leading slash)" \
  "grep -q \"starts with '/'\" '$WORKDIR9/run_leadingslash.log'"
assert "FIX51: the error suggests the actual fix (path without the slash)" \
  "grep -q 'borgsnap_test_zfs_rcv' '$WORKDIR9/run_leadingslash.log'"
assert "FIX51: no confusing empty-pool-name message appears" \
  "! grep -q \"pool '' \" '$WORKDIR9/run_leadingslash.log'"

echo "-------------------------------------"
echo "Recursive mount with zero actual children (FIX #52)"
echo "-------------------------------------"

# The mock normally simulates one synthetic child for every recursive
# snapshot (see test/mocks/zfs), which would make it impossible to ever
# hit the real-world case this bug needed: a dataset with the recursive
# flag set, but genuinely zero children. MOCK_ZFS_NO_CHILD=1 disables
# that simulation for this section specifically.
WORKDIR10="$(mktemp -d)"
mkdir -p "$WORKDIR10/repo1"
MAILKEYFILE10="$WORKDIR10/test10.key"; echo "testpassphrase" > "$MAILKEYFILE10"; chmod 600 "$MAILKEYFILE10"
cat > "$WORKDIR10/test10-nochild.conf" << EOF13
LOCAL_BORG_USER="$(id -un)"
FS="tank/nochild,r ;"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE10"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR10/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF13
chmod 600 "$WORKDIR10/test10-nochild.conf"

export MOCK_LOG="$WORKDIR10/mock.log"
export MOCK_STATE="$WORKDIR10/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR10/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_NO_CHILD=1 sh ./borgsnap_ng.sh run "$WORKDIR10/test10-nochild.conf" > "$WORKDIR10/run_nochild.log" 2>&1
RC_NOCHILD=$?
assert "FIX52: a recursive dataset with zero actual children still succeeds" "[ $RC_NOCHILD -eq 0 ]"
assert "FIX52: the top-level (childless) dataset itself gets mounted" \
  "grep -q 'mount -t zfs tank/nochild@' '$MOCK_LOG'"
assert "FIX52: borg create ran against the mounted top-level directory" \
  "grep -q 'borg create.*tank/nochild' '$MOCK_LOG'"

echo "-------------------------------------"
echo "zfssend sibling-target empty-parent false positive (FIX #54)"
echo "-------------------------------------"

# Reproduces a real-world scenario: two INDEPENDENT zfssend configs share
# the same target prefix, and one source dataset is the parent of the
# other (e.g. "tank/data" and "tank/data/child" backed up separately).
# Sending the child first auto-creates an EMPTY placeholder at the
# parent's own target path (zfs create -p, to make room for the child's
# target underneath it) - that placeholder was never itself a genuine
# send destination. A later, independent run targeting the PARENT
# dataset must not mistake that empty scaffold for "a previous send
# happened here, but the bookmark is now missing".
WORKDIR11="$(mktemp -d)"
MAILKEYFILE11="$WORKDIR11/test11.key"; echo "testpassphrase" > "$MAILKEYFILE11"; chmod 600 "$MAILKEYFILE11"

cat > "$WORKDIR11/test11-child.conf" << EOF14
LOCAL_BORG_USER="$(id -un)"
FS="tank/data/child,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE11"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="zfssend:siblingtarget, ;"
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF14
chmod 600 "$WORKDIR11/test11-child.conf"

cat > "$WORKDIR11/test11-parent.conf" << EOF15
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE11"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="zfssend:siblingtarget, ;"
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF15
chmod 600 "$WORKDIR11/test11-parent.conf"

export MOCK_LOG="$WORKDIR11/mock.log"
export MOCK_STATE="$WORKDIR11/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR11/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"

# Step 1: back up the CHILD first - this auto-creates
# "siblingtarget/tank/data" as an empty parent placeholder while actually
# sending to "siblingtarget/tank/data/child".
sh ./borgsnap_ng.sh run "$WORKDIR11/test11-child.conf" > "$WORKDIR11/run_child.log" 2>&1
RC_SIBLINGCHILD=$?
assert "FIX54: the child's own backup succeeds" "[ $RC_SIBLINGCHILD -eq 0 ]"
assert "FIX54: sending the child auto-creates the empty parent placeholder" \
  "grep -q 'zfs create -p siblingtarget/tank/data\$' '$MOCK_LOG'"

# Step 2: back up the PARENT, targeting the same prefix - its target
# dataset is exactly that empty placeholder. This must succeed as a FULL
# send, not die complaining about a missing bookmark for a "previous"
# send that never actually happened.
: > "$MOCK_LOG"
sh ./borgsnap_ng.sh run "$WORKDIR11/test11-parent.conf" > "$WORKDIR11/run_parent.log" 2>&1
RC_SIBLINGPARENT=$?
assert "FIX54: the parent's independent backup succeeds despite the empty placeholder" \
  "[ $RC_SIBLINGPARENT -eq 0 ]"
assert "FIX54: it did NOT wrongly complain about a missing bookmark" \
  "! grep -q 'tracking bookmark' '$WORKDIR11/run_parent.log'"
assert "FIX54: it correctly did a full send (not incremental) to the empty placeholder" \
  "grep -q '^zfs send tank/data@' '$MOCK_LOG'"
assert "FIX56: the -F full send used for the empty placeholder does not touch the child's real data" \
  "grep -qxF 'siblingtarget/tank/data/child' '$MOCK_STATE'"

echo "-------------------------------------"
echo "Restorability verification depth (BORG_VERIFY)"
echo "-------------------------------------"

WORKDIR12="$(mktemp -d)"
mkdir -p "$WORKDIR12/repo1"
MAILKEYFILE12="$WORKDIR12/test12.key"; echo "testpassphrase" > "$MAILKEYFILE12"; chmod 600 "$MAILKEYFILE12"

export MOCK_LOG="$WORKDIR12/mock.log"
export MOCK_STATE="$WORKDIR12/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR12/lock"

# Scenario A: BORG_VERIFY not set at all - no "borg check" call, existing
# behavior unchanged for every config that predates this feature.
cat > "$WORKDIR12/test12-noverify.conf" << EOF16
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF16
chmod 600 "$WORKDIR12/test12-noverify.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-noverify.conf" > "$WORKDIR12/run_noverify.log" 2>&1
RC_NOVERIFY=$?
assert "BORG_VERIFY: unset - run succeeds normally" "[ $RC_NOVERIFY -eq 0 ]"
assert "BORG_VERIFY: unset - no borg check is ever called" "! grep -q '^borg check' '$MOCK_LOG'"

# Determine which interval label this mock date actually produces, so the
# remaining scenarios target a depth that will genuinely be looked up
# (rather than guessing and silently testing nothing).
ACTUAL_INTERVAL=$(grep -oE 'borg create.*::[a-z_]+-([a-z]+)-[0-9]+ ' "$MOCK_LOG" | head -1 | sed -E 's/.*-([a-z]+)-[0-9]+ /\1/')

# Scenario B: configured depth "repo" for today's actual interval.
cat > "$WORKDIR12/test12-repo.conf" << EOF17
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="${ACTUAL_INTERVAL}:repo"
EOF17
chmod 600 "$WORKDIR12/test12-repo.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-repo.conf" > "$WORKDIR12/run_repo.log" 2>&1
RC_REPO=$?
assert "BORG_VERIFY: depth 'repo' - run succeeds" "[ $RC_REPO -eq 0 ]"
assert "BORG_VERIFY: depth 'repo' - borg check --repository-only was called" \
  "grep -q '^borg check --repository-only' '$MOCK_LOG'"

# Scenario C: configured depth "archive".
cat > "$WORKDIR12/test12-archive.conf" << EOF18
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="${ACTUAL_INTERVAL}:archive"
EOF18
chmod 600 "$WORKDIR12/test12-archive.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-archive.conf" > "$WORKDIR12/run_archive.log" 2>&1
RC_ARCHIVE=$?
assert "BORG_VERIFY: depth 'archive' - run succeeds" "[ $RC_ARCHIVE -eq 0 ]"
assert "BORG_VERIFY: depth 'archive' - borg check --archives-only was called" \
  "grep -q '^borg check --archives-only' '$MOCK_LOG'"

# Scenario D: configured depth "data".
cat > "$WORKDIR12/test12-data.conf" << EOF19
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="${ACTUAL_INTERVAL}:data"
EOF19
chmod 600 "$WORKDIR12/test12-data.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-data.conf" > "$WORKDIR12/run_data.log" 2>&1
RC_DATA=$?
assert "BORG_VERIFY: depth 'data' - run succeeds" "[ $RC_DATA -eq 0 ]"
assert "BORG_VERIFY: depth 'data' - borg check --verify-data was called" \
  "grep -q '^borg check --verify-data' '$MOCK_LOG'"

# Scenario E: BORG_VERIFY configured, but for a DIFFERENT interval than
# today's - no matching entry, defaults to off, no check call.
cat > "$WORKDIR12/test12-nomatch.conf" << EOF20
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="some_other_interval_never_matches:data"
EOF20
chmod 600 "$WORKDIR12/test12-nomatch.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-nomatch.conf" > "$WORKDIR12/run_nomatch.log" 2>&1
RC_NOMATCH=$?
assert "BORG_VERIFY: no matching interval entry - run succeeds" "[ $RC_NOMATCH -eq 0 ]"
assert "BORG_VERIFY: no matching interval entry - no borg check is called" \
  "! grep -q '^borg check' '$MOCK_LOG'"

# Scenario F: borg check finds a problem - must warn, NOT abort the run.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_CHECK_RC=1 sh ./borgsnap_ng.sh run "$WORKDIR12/test12-data.conf" > "$WORKDIR12/run_checkfail.log" 2>&1
RC_CHECKFAIL=$?
assert "BORG_VERIFY: a check finding a problem does NOT abort the run" "[ $RC_CHECKFAIL -eq 0 ]"
assert "BORG_VERIFY: a check finding a problem is logged as a clear WARNING" \
  "grep -q 'WARNING.*borg check found a problem' '$WORKDIR12/run_checkfail.log'"

# Scenario G: an invalid depth in BORG_VERIFY is rejected at config load
# time, not silently ignored.
cat > "$WORKDIR12/test12-invalid.conf" << EOF21
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="monthly:thorough"
EOF21
chmod 600 "$WORKDIR12/test12-invalid.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-invalid.conf" > "$WORKDIR12/run_invalid.log" 2>&1
RC_INVALID=$?
assert "BORG_VERIFY: an invalid depth value is rejected, not silently ignored" "[ $RC_INVALID -ne 0 ]"
assert "BORG_VERIFY: the rejection message names the actual problem" \
  "grep -q \"invalid depth 'thorough'\" '$WORKDIR12/run_invalid.log'"

# Scenario H: only a "default:" entry, no exact interval match at all -
# still applies, instead of silently falling back to "off".
cat > "$WORKDIR12/test12-defaultonly.conf" << EOF25
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="default:repo"
EOF25
chmod 600 "$WORKDIR12/test12-defaultonly.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-defaultonly.conf" > "$WORKDIR12/run_defaultonly.log" 2>&1
RC_DEFAULTONLY=$?
assert "BORG_VERIFY: a bare 'default:' entry applies when nothing more specific matches" "[ $RC_DEFAULTONLY -eq 0 ]"
assert "BORG_VERIFY: the default depth was actually used" \
  "grep -q '^borg check --repository-only' '$MOCK_LOG'"

# Scenario I: an exact interval match must win over "default:", not the
# other way around, regardless of which order they appear in the string.
cat > "$WORKDIR12/test12-defaultplusexact.conf" << EOF26
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="default:repo;${ACTUAL_INTERVAL}:data"
EOF26
chmod 600 "$WORKDIR12/test12-defaultplusexact.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-defaultplusexact.conf" > "$WORKDIR12/run_defaultplusexact.log" 2>&1
RC_DEFAULTPLUSEXACT=$?
assert "BORG_VERIFY: exact match plus default - run succeeds" "[ $RC_DEFAULTPLUSEXACT -eq 0 ]"
assert "BORG_VERIFY: the EXACT interval match wins over 'default:', not the other way around" \
  "grep -q '^borg check --verify-data' '$MOCK_LOG' && ! grep -q '^borg check --repository-only' '$MOCK_LOG'"

# Scenario J: an interval with no exact match falls back to "default:",
# even though OTHER intervals ARE listed explicitly - the real-world case
# this was built for: adding a new interval to RETENTIONPERIOD without
# remembering to also add it to BORG_VERIFY must not silently disable
# verification for it.
cat > "$WORKDIR12/test12-fallback.conf" << EOF27
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE12"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR12/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="default:archive;some_interval_that_never_matches:data"
EOF27
chmod 600 "$WORKDIR12/test12-fallback.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR12/test12-fallback.conf" > "$WORKDIR12/run_fallback.log" 2>&1
RC_FALLBACK=$?
assert "BORG_VERIFY: an interval not explicitly listed falls back to 'default:' instead of silently going off" "[ $RC_FALLBACK -eq 0 ]"
assert "BORG_VERIFY: the fallback depth was actually used" \
  "grep -q '^borg check --archives-only' '$MOCK_LOG'"

echo "-------------------------------------"
echo "initBorg resilience across multiple repos (FIX #57)"
echo "-------------------------------------"

# One repo's init fails (transient issue, unreachable remote, etc.) - must
# be reported loudly, but must not abort backups to the other configured
# repo, matching FIX #36's philosophy for createBorg.
WORKDIR13="$(mktemp -d)"
MAILKEYFILE13="$WORKDIR13/test13.key"; echo "testpassphrase" > "$MAILKEYFILE13"; chmod 600 "$MAILKEYFILE13"
cat > "$WORKDIR13/test13-initfail.conf" << EOF22
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE13"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR13/repo_fail, ; $WORKDIR13/repo_ok, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF22
chmod 600 "$WORKDIR13/test13-initfail.conf"

export MOCK_LOG="$WORKDIR13/mock.log"
export MOCK_STATE="$WORKDIR13/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR13/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_FAIL_INIT_REPO="$WORKDIR13/repo_fail" sh ./borgsnap_ng.sh run "$WORKDIR13/test13-initfail.conf" > "$WORKDIR13/run_initfail.log" 2>&1
RC_INITFAIL=$?
assert "FIX57: run still succeeds overall when one repo's init fails" "[ $RC_INITFAIL -eq 0 ]"
assert "FIX57: the init failure is reported loudly" \
  "grep -q 'borg init failed' '$WORKDIR13/run_initfail.log'"
assert "FIX57: the OTHER repo still received a create attempt" \
  "grep -q \"borg create.*$WORKDIR13/repo_ok\" '$MOCK_LOG'"
assert "FIX57: no create was attempted against the failed repo (never initialized)" \
  "! grep -q \"borg create.*$WORKDIR13/repo_fail\" '$MOCK_LOG'"

echo "-------------------------------------"
echo "Remote existence check retry (FIX #58)"
echo "-------------------------------------"

WORKDIR14="$(mktemp -d)"
MAILKEYFILE14="$WORKDIR14/test14.key"; echo "testpassphrase" > "$MAILKEYFILE14"; chmod 600 "$MAILKEYFILE14"
cat > "$WORKDIR14/test14-remote.conf" << EOF23
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE14"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="ssh://mocksshhost/./test_repo, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF23
chmod 600 "$WORKDIR14/test14-remote.conf"

export MOCK_LOG="$WORKDIR14/mock.log"
export MOCK_STATE="$WORKDIR14/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR14/lock"

# Scenario A: succeeds on the very first attempt - no retry, no warning.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
rm -f "$WORKDIR14/ssh_ls_counter"
MOCK_SSH_COUNTER_FILE="$WORKDIR14/ssh_ls_counter" sh ./borgsnap_ng.sh run "$WORKDIR14/test14-remote.conf" > "$WORKDIR14/run_immediate.log" 2>&1
RC_IMMEDIATE=$?
assert "FIX58: immediate success - run succeeds" "[ $RC_IMMEDIATE -eq 0 ]"
assert "FIX58: immediate success - no retry warning logged" \
  "! grep -q 'retrying shortly' '$WORKDIR14/run_immediate.log'"

# Scenario B: fails once, then succeeds on retry - repo correctly detected
# as already existing, init skipped, and the retry is visibly logged.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
echo "BORG_INIT:ssh://mocksshhost/./test_repo" >> "$MOCK_STATE"
rm -f "$WORKDIR14/ssh_ls_counter"
MOCK_SSH_COUNTER_FILE="$WORKDIR14/ssh_ls_counter" MOCK_SSH_FAIL_COUNT=1 sh ./borgsnap_ng.sh run "$WORKDIR14/test14-remote.conf" > "$WORKDIR14/run_retry.log" 2>&1
RC_RETRY=$?
assert "FIX58: fails once then succeeds - run still succeeds" "[ $RC_RETRY -eq 0 ]"
assert "FIX58: fails once then succeeds - the retry is logged" \
  "grep -q 'retrying shortly' '$WORKDIR14/run_retry.log'"
assert "FIX58: fails once then succeeds - repo correctly detected as existing (no init attempted)" \
  "! grep -q '^borg init' '$MOCK_LOG'"

# Scenario C: fails every attempt (more than the retry budget) - correctly
# concludes "doesn't exist" after exhausting retries, proceeds to init a
# fresh repo (not stuck, not a false "doesn't exist" masking a real one -
# this is the genuine "repo really isn't there yet" case).
: > "$MOCK_LOG"; : > "$MOCK_STATE"
rm -f "$WORKDIR14/ssh_ls_counter"
MOCK_SSH_COUNTER_FILE="$WORKDIR14/ssh_ls_counter" MOCK_SSH_FAIL_COUNT=5 sh ./borgsnap_ng.sh run "$WORKDIR14/test14-remote.conf" > "$WORKDIR14/run_exhausted.log" 2>&1
RC_EXHAUSTED=$?
assert "FIX58: exhausts all retries - run still succeeds (falls through to a fresh init)" "[ $RC_EXHAUSTED -eq 0 ]"
assert "FIX58: exhausts all retries - exactly 3 attempts were made, not more, not fewer" \
  "[ \"\$(cat '$WORKDIR14/ssh_ls_counter')\" = 3 ]"
assert "FIX58: exhausts all retries - falls through to a fresh init" \
  "grep -q '^borg init' '$MOCK_LOG'"

echo "-------------------------------------"
echo "zfssend failure resilience across mixed repos (FIX #59)"
echo "-------------------------------------"

# Reproduces a real-world scenario: REPOLIST has a borg repo, then a
# zfssend target that fails, then ANOTHER borg repo after it. Before this
# fix, backendZfsSend called err_hdlr directly on a send/receive failure -
# completely bypassing the FIX #36/#57 carve-out mechanism - so the whole
# run died right there, and the SECOND borg repo (which has nothing to do
# with the failing zfssend target) never got a chance to run at all.
WORKDIR15="$(mktemp -d)"
mkdir -p "$WORKDIR15/repo_before" "$WORKDIR15/repo_after"
MAILKEYFILE15="$WORKDIR15/test15.key"; echo "testpassphrase" > "$MAILKEYFILE15"; chmod 600 "$MAILKEYFILE15"
cat > "$WORKDIR15/test15-mixed.conf" << EOF24
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE15"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR15/repo_before, ; zfssend:tank/mixedtarget, ; $WORKDIR15/repo_after, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF24
chmod 600 "$WORKDIR15/test15-mixed.conf"

export MOCK_LOG="$WORKDIR15/mock.log"
export MOCK_STATE="$WORKDIR15/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR15/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_FAIL_SEND=1 sh ./borgsnap_ng.sh run "$WORKDIR15/test15-mixed.conf" > "$WORKDIR15/run_mixed.log" 2>&1
RC_MIXED59=$?
assert "FIX59: run succeeds overall despite the zfssend target in the middle failing" "[ $RC_MIXED59 -eq 0 ]"
assert "FIX59: the repo BEFORE the failing zfssend target got backed up" \
  "grep -q \"borg create.*$WORKDIR15/repo_before\" '$MOCK_LOG'"
assert "FIX59: the repo AFTER the failing zfssend target ALSO got backed up (the actual bug reported)" \
  "grep -q \"borg create.*$WORKDIR15/repo_after\" '$MOCK_LOG'"
assert "FIX59: the zfssend failure itself is still clearly logged" \
  "grep -q 'zfssend: send failed' '$WORKDIR15/run_mixed.log'"

echo "-------------------------------------"
echo "Restore path verification (RESTORE_VERIFY)"
echo "-------------------------------------"

WORKDIR16="$(mktemp -d)"
mkdir -p "$WORKDIR16/repo1" "$WORKDIR16/mockmounts"
MAILKEYFILE16="$WORKDIR16/test16.key"; echo "testpassphrase" > "$MAILKEYFILE16"; chmod 600 "$MAILKEYFILE16"

export MOCK_LOG="$WORKDIR16/mock.log"
export MOCK_STATE="$WORKDIR16/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR16/lock"
export MOCK_ZFS_MOUNTBASE="$WORKDIR16/mockmounts"

# Scenario A: RESTORE_VERIFY not set at all - no canary write, no
# restore-check attempted, existing behavior unchanged.
cat > "$WORKDIR16/test16-unset.conf" << EOF28
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE16"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR16/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF28
chmod 600 "$WORKDIR16/test16-unset.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR16/test16-unset.conf" > "$WORKDIR16/run_unset.log" 2>&1
RC_RVUNSET=$?
assert "RESTORE_VERIFY: unset - run succeeds normally" "[ $RC_RVUNSET -eq 0 ]"
assert "RESTORE_VERIFY: unset - no canary file is ever written" \
  "[ ! -f '$WORKDIR16/mockmounts/tank/data/.borgsnap_ng_canary' ]"
assert "RESTORE_VERIFY: unset - no borg extract is attempted" \
  "! grep -q '^borg extract' '$MOCK_LOG'"

# Determine today's actual interval word (same technique as BORG_VERIFY's
# own tests) so the remaining scenarios target a depth that genuinely
# gets looked up.
ACTUAL_INTERVAL_RV=$(grep -oE 'borg create.*::[a-z_]+-([a-z]+)-[0-9]+ ' "$MOCK_LOG" | head -1 | sed -E 's/.*-([a-z]+)-[0-9]+ /\1/')
[ -z "$ACTUAL_INTERVAL_RV" ] && ACTUAL_INTERVAL_RV="$ACTUAL_INTERVAL"

cat > "$WORKDIR16/test16-on.conf" << EOF29
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE16"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR16/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
RESTORE_VERIFY="${ACTUAL_INTERVAL_RV}:on"
EOF29
chmod 600 "$WORKDIR16/test16-on.conf"

# Scenario B: enabled, genuine end-to-end match - MOCK_BORG_EXTRACT_FILE
# points at exactly where the canary got written this same run, so
# "extraction" reads back precisely what was really just written.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_EXTRACT_FILE="$WORKDIR16/mockmounts/tank/data/.borgsnap_ng_canary" \
  sh ./borgsnap_ng.sh run "$WORKDIR16/test16-on.conf" > "$WORKDIR16/run_match.log" 2>&1
RC_RVMATCH=$?
assert "RESTORE_VERIFY: enabled - canary file was actually written" \
  "[ -f '$WORKDIR16/mockmounts/tank/data/.borgsnap_ng_canary' ]"
assert "RESTORE_VERIFY: enabled - matching content - run succeeds" "[ $RC_RVMATCH -eq 0 ]"
assert "RESTORE_VERIFY: enabled - matching content - no failure was reported" \
  "! grep -q 'restore verification FAILED' '$WORKDIR16/run_match.log'"

# Scenario C: enabled, but the "extracted" content doesn't match (a
# corrupted/broken restore path) - must be a genuine FAILURE (nonzero
# exit), not just a warning, per the explicit design decision.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_EXTRACT_CONTENT="deliberately wrong content" \
  sh ./borgsnap_ng.sh run "$WORKDIR16/test16-on.conf" > "$WORKDIR16/run_mismatch.log" 2>&1
RC_RVMISMATCH=$?
assert "RESTORE_VERIFY: content mismatch is a genuine FAILURE (nonzero exit), not a warning" "[ $RC_RVMISMATCH -ne 0 ]"
assert "RESTORE_VERIFY: the mismatch is reported clearly" \
  "grep -q 'restore verification FAILED' '$WORKDIR16/run_mismatch.log'"

# Scenario D: extraction itself fails outright (broken restore path at a
# more fundamental level than just wrong content).
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_EXTRACT_RC=1 sh ./borgsnap_ng.sh run "$WORKDIR16/test16-on.conf" > "$WORKDIR16/run_extractfail.log" 2>&1
RC_RVEXTRACTFAIL=$?
assert "RESTORE_VERIFY: an extraction failure is also a genuine FAILURE" "[ $RC_RVEXTRACTFAIL -ne 0 ]"
assert "RESTORE_VERIFY: the extraction failure is reported clearly" \
  "grep -q 'could not extract the canary file' '$WORKDIR16/run_extractfail.log'"

# Scenario E: the canary file can't be written - simulated with a
# structural impossibility (a plain FILE where a directory is expected)
# rather than a permission bit, since these tests run as root, which
# bypasses standard Unix permission checks entirely (DAC_OVERRIDE) - a
# chmod-based simulation wouldn't actually block anything here. Must be a
# graceful skip for this dataset, not a crash of the whole run.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
touch "$WORKDIR16/not_a_directory"
MOCK_ZFS_MOUNTBASE="$WORKDIR16/not_a_directory" sh ./borgsnap_ng.sh run "$WORKDIR16/test16-on.conf" > "$WORKDIR16/run_nowrite.log" 2>&1
RC_RVNOWRITE=$?
assert "RESTORE_VERIFY: a canary write failure gracefully skips verification, run still succeeds" "[ $RC_RVNOWRITE -eq 0 ]"
assert "RESTORE_VERIFY: the write failure is reported clearly" \
  "grep -q 'could not write canary file' '$WORKDIR16/run_nowrite.log'"

echo "-------------------------------------"
echo "Restore path verification - zfssend backend"
echo "-------------------------------------"

cat > "$WORKDIR16/test16-zfssend.conf" << EOF30
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE16"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="zfssend:restoretarget, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
RESTORE_VERIFY="${ACTUAL_INTERVAL_RV}:on"
EOF30
chmod 600 "$WORKDIR16/test16-zfssend.conf"

# Scenario F: zfssend, matching content via the mock mount's own
# configurable canary-write.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_MOUNTBASE="$WORKDIR16/mockmounts2" MOCK_MOUNT_CANARY_CONTENT="whatever-was-really-sent" \
  sh ./borgsnap_ng.sh run "$WORKDIR16/test16-zfssend.conf" > "$WORKDIR16/run_zfs_mount.log" 2>&1
RC_RVZFSMOUNT=$?
# The mock mount always writes MOCK_MOUNT_CANARY_CONTENT, which won't
# match the real canary hash written earlier this run - this scenario
# specifically exercises "the mount succeeded, content read back
# correctly, but it doesn't match" -> must be a genuine failure.
assert "RESTORE_VERIFY (zfssend): the target gets mounted for verification" \
  "grep -q '^mount -t zfs restoretarget' '$MOCK_LOG'"
assert "RESTORE_VERIFY (zfssend): mismatched content is a genuine FAILURE" "[ $RC_RVZFSMOUNT -ne 0 ]"

# Scenario G: zfssend, the target mount itself fails outright.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_MOUNTBASE="$WORKDIR16/mockmounts3" MOCK_MOUNT_FAIL_RC=1 \
  sh ./borgsnap_ng.sh run "$WORKDIR16/test16-zfssend.conf" > "$WORKDIR16/run_zfs_mountfail.log" 2>&1
RC_RVZFSMOUNTFAIL=$?
assert "RESTORE_VERIFY (zfssend): a mount failure is a genuine FAILURE" "[ $RC_RVZFSMOUNTFAIL -ne 0 ]"
assert "RESTORE_VERIFY (zfssend): the mount failure is reported clearly" \
  "grep -q 'could not mount the target snapshot' '$WORKDIR16/run_zfs_mountfail.log'"

echo "-------------------------------------"
echo "MSG_LEVEL configurable via config file"
echo "-------------------------------------"

WORKDIR17="$(mktemp -d)"
mkdir -p "$WORKDIR17/repo1"
MAILKEYFILE17="$WORKDIR17/test17.key"; echo "testpassphrase" > "$MAILKEYFILE17"; chmod 600 "$MAILKEYFILE17"

export MOCK_LOG="$WORKDIR17/mock.log"
export MOCK_STATE="$WORKDIR17/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR17/lock"

# Scenario A: config sets MSG_LEVEL=2 (INFO and above) - INFO-level
# messages (like BORG_VERIFY's "passed" confirmation) must now be visible,
# unlike the hardcoded default of 1 which would suppress them.
cat > "$WORKDIR17/test17-level2.conf" << EOF28
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE17"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR17/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="default:repo"
MSG_LEVEL=2
EOF28
chmod 600 "$WORKDIR17/test17-level2.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR17/test17-level2.conf" > "$WORKDIR17/run_level2.log" 2>&1
RC_LEVEL2=$?
assert "MSG_LEVEL: config-set level 2 - run succeeds" "[ $RC_LEVEL2 -eq 0 ]"
assert "MSG_LEVEL: config-set level 2 - INFO-level borg check confirmation is now visible" \
  "grep -q 'INFO: borg check' '$WORKDIR17/run_level2.log'"

# Scenario B: default level (config doesn't set MSG_LEVEL at all) - the
# same INFO-level confirmation must NOT be visible, matching the
# hardcoded default of 1 (errors+warnings only).
cat > "$WORKDIR17/test17-defaultlevel.conf" << EOF29
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE17"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR17/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
BORG_VERIFY="default:repo"
EOF29
chmod 600 "$WORKDIR17/test17-defaultlevel.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR17/test17-defaultlevel.conf" > "$WORKDIR17/run_defaultlevel.log" 2>&1
RC_DEFAULTLEVEL=$?
assert "MSG_LEVEL: unset in config - run succeeds" "[ $RC_DEFAULTLEVEL -eq 0 ]"
assert "MSG_LEVEL: unset in config - INFO-level confirmation stays hidden at the default level" \
  "! grep -q 'INFO: borg check' '$WORKDIR17/run_defaultlevel.log'"

# Scenario C: an invalid MSG_LEVEL value is rejected at config load time.
cat > "$WORKDIR17/test17-invalidlevel.conf" << EOF30
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE17"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR17/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MSG_LEVEL=verbose
EOF30
chmod 600 "$WORKDIR17/test17-invalidlevel.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR17/test17-invalidlevel.conf" > "$WORKDIR17/run_invalidlevel.log" 2>&1
RC_INVALIDLEVEL=$?
assert "MSG_LEVEL: a non-numeric value is rejected, not silently ignored" "[ $RC_INVALIDLEVEL -ne 0 ]"
assert "MSG_LEVEL: the rejection message names the actual problem" \
  "grep -q \"invalid value 'verbose'\" '$WORKDIR17/run_invalidlevel.log'"

echo "-------------------------------------"
echo "Repo/target capacity reporting"
echo "-------------------------------------"

WORKDIR18="$(mktemp -d)"
mkdir -p "$WORKDIR18/repo1"
MAILKEYFILE18="$WORKDIR18/test18.key"; echo "testpassphrase" > "$MAILKEYFILE18"; chmod 600 "$MAILKEYFILE18"

export MOCK_LOG="$WORKDIR18/mock.log"
export MOCK_STATE="$WORKDIR18/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR18/lock"

# Scenario A: local borg repo - real "df" against the actual sandbox
# filesystem (no mocking needed, df always works locally), no warning
# threshold configured - must report INFO fill level, not a warning.
cat > "$WORKDIR18/test18-capacity.conf" << EOF31
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE18"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR18/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MSG_LEVEL=2
EOF31
chmod 600 "$WORKDIR18/test18-capacity.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR18/test18-capacity.conf" > "$WORKDIR18/run_capacity.log" 2>&1
RC_CAPACITY=$?
assert "Capacity: local repo - run succeeds" "[ $RC_CAPACITY -eq 0 ]"
assert "Capacity: local repo - fill level is reported" \
  "grep -q 'fill level:' '$WORKDIR18/run_capacity.log'"

# Scenario B: same repo, but with an artificially low warning threshold -
# forces a WARNING regardless of actual usage, proving the threshold
# logic itself works.
cat > "$WORKDIR18/test18-capacitywarn.conf" << EOF32
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE18"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR18/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
CAPACITY_WARN_PERCENT=0
EOF32
chmod 600 "$WORKDIR18/test18-capacitywarn.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR18/test18-capacitywarn.conf" > "$WORKDIR18/run_capacitywarn.log" 2>&1
RC_CAPACITYWARN=$?
assert "Capacity: threshold at 0% - still succeeds (a full repo is worth warning about, not aborting over)" "[ $RC_CAPACITYWARN -eq 0 ]"
assert "Capacity: threshold at 0% - escalates to WARNING" \
  "grep -q 'WARNING.*full.*CAPACITY_WARN_PERCENT=0' '$WORKDIR18/run_capacitywarn.log'"

# Scenario C: zfssend target - mocked zpool capacity, below threshold.
cat > "$WORKDIR18/test18-zfscapacity.conf" << EOF33
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE18"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="zfssend:tank/capacitytarget, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MSG_LEVEL=2
CAPACITY_WARN_PERCENT=90
EOF33
chmod 600 "$WORKDIR18/test18-zfscapacity.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZPOOL_CAP=42 MOCK_ZPOOL_FREE=5000000000 sh ./borgsnap_ng.sh run "$WORKDIR18/test18-zfscapacity.conf" > "$WORKDIR18/run_zfscapacity.log" 2>&1
RC_ZFSCAPACITY=$?
assert "Capacity: zfssend target below threshold - run succeeds" "[ $RC_ZFSCAPACITY -eq 0 ]"
assert "Capacity: zfssend target below threshold - reports INFO fill level, not a warning" \
  "grep -q 'INFO.*target pool.*fill level: 42% used' '$WORKDIR18/run_zfscapacity.log'"

# Scenario D: zfssend target - mocked zpool capacity, AT the threshold.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZPOOL_CAP=95 MOCK_ZPOOL_FREE=100000000 sh ./borgsnap_ng.sh run "$WORKDIR18/test18-zfscapacity.conf" > "$WORKDIR18/run_zfscapacitywarn.log" 2>&1
RC_ZFSCAPACITYWARN=$?
assert "Capacity: zfssend target at/above threshold - still succeeds" "[ $RC_ZFSCAPACITYWARN -eq 0 ]"
assert "Capacity: zfssend target at/above threshold - escalates to WARNING" \
  "grep -q 'WARNING.*target pool.*95% full' '$WORKDIR18/run_zfscapacitywarn.log'"

echo "-------------------------------------"
echo "MSG_LEVEL is honored by createBorg (real-world bug)"
echo "-------------------------------------"

# Reproduces a real-world report: MSG_LEVEL=0 in the config was being
# silently ignored specifically during createBorg - it hardcoded
# MSG_LEVEL=5 (full debug) for its own duration and restored the real
# value only afterward, so borg-side DEBUG messages always appeared
# regardless of what the user configured, while every OTHER function
# correctly respected it - a confusing asymmetry.
WORKDIR19="$(mktemp -d)"
mkdir -p "$WORKDIR19/repo1"
MAILKEYFILE19="$WORKDIR19/test19.key"; echo "testpassphrase" > "$MAILKEYFILE19"; chmod 600 "$MAILKEYFILE19"
cat > "$WORKDIR19/test19-level0.conf" << EOF34
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE19"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR19/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MSG_LEVEL=0
EOF34
chmod 600 "$WORKDIR19/test19-level0.conf"
export MOCK_LOG="$WORKDIR19/mock.log"
export MOCK_STATE="$WORKDIR19/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR19/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR19/test19-level0.conf" > "$WORKDIR19/run_level0.log" 2>&1
RC_LEVEL0=$?
assert "MSG_LEVEL=0: run succeeds" "[ $RC_LEVEL0 -eq 0 ]"
assert "MSG_LEVEL=0: createBorg's own DEBUG messages are correctly suppressed, not forced on" \
  "! grep -q 'DEBUG:.*in Function createBorg' '$WORKDIR19/run_level0.log'"

echo "-------------------------------------"
echo "REPOLIST trailing separator (real-world bug)"
echo "-------------------------------------"

# Reproduces a real-world report: a REPOLIST ending in a trailing
# separator ("...;last_repo, ; ") produced a phantom, empty entry after
# trimming, which fell through to the default "borg" case with a blank
# repo path - "Empty directory string was given!" and similar confusing
# errors for something that was never a real, intended repo entry.
WORKDIR20="$(mktemp -d)"
mkdir -p "$WORKDIR20/repo1"
MAILKEYFILE20="$WORKDIR20/test20.key"; echo "testpassphrase" > "$MAILKEYFILE20"; chmod 600 "$MAILKEYFILE20"
cat > "$WORKDIR20/test20-trailingsep.conf" << EOF35
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE20"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR20/repo1, ; "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF35
chmod 600 "$WORKDIR20/test20-trailingsep.conf"
export MOCK_LOG="$WORKDIR20/mock.log"
export MOCK_STATE="$WORKDIR20/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR20/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR20/test20-trailingsep.conf" > "$WORKDIR20/run_trailingsep.log" 2>&1
RC_TRAILINGSEP=$?
assert "REPOLIST trailing separator: run succeeds" "[ $RC_TRAILINGSEP -eq 0 ]"
assert "REPOLIST trailing separator: no phantom empty-repo error" \
  "! grep -q 'Empty directory string was given' '$WORKDIR20/run_trailingsep.log'"
assert "REPOLIST trailing separator: the real repo still got backed up" \
  "grep -q \"borg create.*$WORKDIR20/repo1\" '$MOCK_LOG'"

echo "-------------------------------------"
echo "ensureBorgBaseInit no longer leaks its state-check listing (real-world bug)"
echo "-------------------------------------"

# Reproduces a real-world report: mystery archive-listing lines appearing
# in the log/mail with no explanation. Root cause: ensureBorgBaseInit's
# internal "borg list" state check (only the exit code matters - FIX #50)
# ran with no output redirection at all, so a successful call's own
# archive listing leaked straight through, completely bypassing
# MSG_LEVEL since it's borg's own native stdout, not something routed
# through msg().
WORKDIR21="$(mktemp -d)"
MAILKEYFILE21="$WORKDIR21/test21.key"; echo "testpassphrase" > "$MAILKEYFILE21"; chmod 600 "$MAILKEYFILE21"
cat > "$WORKDIR21/test21-borgbase.conf" << EOF36
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE21"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="borgbase:ssh://borgbase_repo/./repo, borg, repokey-blake2; "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF36
chmod 600 "$WORKDIR21/test21-borgbase.conf"
export MOCK_LOG="$WORKDIR21/mock.log"
export MOCK_STATE="$WORKDIR21/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR21/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR21/test21-borgbase.conf" > "$WORKDIR21/run_borgbase.log" 2>&1
RC_BORGBASELEAK=$?
assert "ensureBorgBaseInit leak fix: run succeeds" "[ $RC_BORGBASELEAK -eq 0 ]"
assert "ensureBorgBaseInit leak fix: the state check's archive listing no longer leaks into the run's own output" \
  "! grep -q 'mockarchive-existing-1' '$WORKDIR21/run_borgbase.log'"

echo "-------------------------------------"
echo "RESTORE_VERIFY skips a repo whose createBorg failed (real-world false positive)"
echo "-------------------------------------"

# Reproduces a real-world report: a same-day rerun hits "archive already
# exists" for one repo (createBorg fails, correctly logged and skipped
# per FIX #36) - but checkRestoreBorg used to run anyway, checking
# TODAY'S label against whatever STALE archive already existed under that
# name from an earlier attempt. Comparing this run's freshly-computed
# canary hash against old content always mismatches, misreporting a
# harmless non-event as "the restore path may be corrupting data".
WORKDIR22="$(mktemp -d)"
mkdir -p "$WORKDIR22/repo1"
MAILKEYFILE22="$WORKDIR22/test22.key"; echo "testpassphrase" > "$MAILKEYFILE22"; chmod 600 "$MAILKEYFILE22"
cat > "$WORKDIR22/test22-createfail.conf" << EOF37
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE22"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR22/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
RESTORE_VERIFY="default:on"
MSG_LEVEL=2
EOF37
chmod 600 "$WORKDIR22/test22-createfail.conf"
export MOCK_LOG="$WORKDIR22/mock.log"
export MOCK_STATE="$WORKDIR22/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR22/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_FAIL_CREATE_REPO="$WORKDIR22/repo1" sh ./borgsnap_ng.sh run "$WORKDIR22/test22-createfail.conf" > "$WORKDIR22/run_createfail.log" 2>&1
RC_CREATEFAIL63=$?
assert "FIX63: run still succeeds when createBorg fails for this repo" "[ $RC_CREATEFAIL63 -eq 0 ]"
assert "FIX63: restore verification is explicitly skipped, not run against a stale archive" \
  "grep -q 'skipping restore verification' '$WORKDIR22/run_createfail.log'"
assert "FIX63: no false-positive 'restore path may be corrupting data' error appears" \
  "! grep -q 'restore verification FAILED' '$WORKDIR22/run_createfail.log'"

echo "-------------------------------------"
echo "RESTORE_VERIFY skips a reused (same-day) snapshot (real-world false positive)"
echo "-------------------------------------"

# Reproduces a real-world report: a same-day rerun finds today's ZFS
# snapshot already exists (a known, deliberate retry-safety behavior -
# snapshotZFS reuses it rather than taking a new one) - but the canary
# file gets freshly rewritten to the LIVE dataset every run, BEFORE
# snapshotZFS runs. If the snapshot is reused rather than fresh, that
# fresh write was never captured anywhere - checking it against the
# reused snapshot's (older) canary content always mismatches, misreporting
# a harmless, well-understood retry scenario as data corruption.
WORKDIR23="$(mktemp -d)"
mkdir -p "$WORKDIR23/repo1"
MAILKEYFILE23="$WORKDIR23/test23.key"; echo "testpassphrase" > "$MAILKEYFILE23"; chmod 600 "$MAILKEYFILE23"
cat > "$WORKDIR23/test23-reused.conf" << EOF38
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE23"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR23/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
RESTORE_VERIFY="default:on"
MSG_LEVEL=2
EOF38
chmod 600 "$WORKDIR23/test23-reused.conf"
export MOCK_LOG="$WORKDIR23/mock.log"
export MOCK_STATE="$WORKDIR23/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR23/lock"
export MOCK_ZFS_MOUNTBASE="$WORKDIR23/mockmounts"

# Seed all three possible interval labels for today's (pinned mock) date
# as already-existing snapshots - guarantees the run's actual active
# interval (decided internally by chkDateStr's own date rules, not
# something this test needs to predict) finds a pre-existing snapshot and
# takes the reuse path, regardless of which specific interval that is.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
echo "tank/data@monthly-20260715" >> "$MOCK_STATE"
echo "tank/data@weekly-20260715" >> "$MOCK_STATE"
echo "tank/data@daily-20260715" >> "$MOCK_STATE"
MOCK_BORG_EXTRACT_FILE="$WORKDIR23/mockmounts/tank/data/.borgsnap_ng_canary" \
  sh ./borgsnap_ng.sh run "$WORKDIR23/test23-reused.conf" > "$WORKDIR23/run_second.log" 2>&1
RC_REUSED_SECOND=$?
assert "FIX64: second run (reused snapshot) still succeeds" "[ $RC_REUSED_SECOND -eq 0 ]"
assert "FIX64: second run explicitly skips restore verification instead of a false mismatch" \
  "grep -q 'skipping restore verification' '$WORKDIR23/run_second.log'"
assert "FIX64: second run reports no false-positive corruption error" \
  "! grep -q 'restore verification FAILED' '$WORKDIR23/run_second.log'"

echo "-------------------------------------"
echo "pruneBorg resilience across repos and ZFS retention (FIX #65)"
echo "-------------------------------------"

# Reproduces the discussed real-world risk: a transient prune failure
# (e.g. a network hiccup with one remote repo) must not abort the whole
# run - and specifically must not prevent pruneZFSSnapshot (source-side
# ZFS retention) from running afterward. Before this fix, pruneBorg had
# no exec_cmd carve-out at all (unlike createBorg/initBorg), so any prune
# failure triggered a full err_hdlr/exit - if this happened repeatedly
# (a chronically flaky remote), source-side snapshots would genuinely
# accumulate since retention never got a chance to run.
WORKDIR24="$(mktemp -d)"
mkdir -p "$WORKDIR24/repo_ok" "$WORKDIR24/repo_bad"
MAILKEYFILE24="$WORKDIR24/test24.key"; echo "testpassphrase" > "$MAILKEYFILE24"; chmod 600 "$MAILKEYFILE24"
cat > "$WORKDIR24/test24-prunefail.conf" << EOF39
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE24"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR24/repo_bad, ; $WORKDIR24/repo_ok, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;weekly,4;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MSG_LEVEL=2
EOF39
chmod 600 "$WORKDIR24/test24-prunefail.conf"
export MOCK_LOG="$WORKDIR24/mock.log"
export MOCK_STATE="$WORKDIR24/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR24/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_FAIL_PRUNE_REPO="$WORKDIR24/repo_bad" sh ./borgsnap_ng.sh run "$WORKDIR24/test24-prunefail.conf" > "$WORKDIR24/run_prunefail.log" 2>&1
RC_PRUNEFAIL=$?
assert "FIX65: run succeeds overall despite one repo's prune failing" "[ $RC_PRUNEFAIL -eq 0 ]"
assert "FIX65: the prune failure is reported clearly" \
  "grep -q 'borg prune failed' '$WORKDIR24/run_prunefail.log'"
assert "FIX65: the OTHER repo's prune still ran (not aborted)" \
  "grep -q \"borg prune.*$WORKDIR24/repo_ok\" '$MOCK_LOG'"
assert "FIX65: source-side ZFS retention (pruneZFSSnapshot) still ran afterward, not skipped" \
  "grep -q 'No old backups to purge\\|Purging old snapshot' '$WORKDIR24/run_prunefail.log'"

echo "-------------------------------------"
echo "SNAPSHOT_TAG (optional collision-avoidance tag)"
echo "-------------------------------------"

WORKDIR26="$(mktemp -d)"
mkdir -p "$WORKDIR26/repo1"
MAILKEYFILE26="$WORKDIR26/test26.key"; echo "testpassphrase" > "$MAILKEYFILE26"; chmod 600 "$MAILKEYFILE26"

# Scenario A: SNAPSHOT_TAG applied to a fresh snapshot's label.
cat > "$WORKDIR26/test26-tagged.conf" << EOF41
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE26"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR26/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="daily,7"
PRE_SCRIPT=
POST_SCRIPT=
SNAPSHOT_TAG="usb"
MSG_LEVEL=2
EOF41
chmod 600 "$WORKDIR26/test26-tagged.conf"
export MOCK_LOG="$WORKDIR26/mock.log"
export MOCK_STATE="$WORKDIR26/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR26/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR26/test26-tagged.conf" > "$WORKDIR26/run_tagged.log" 2>&1
RC_TAGGED=$?
assert "SNAPSHOT_TAG: run succeeds" "[ $RC_TAGGED -eq 0 ]"
assert "SNAPSHOT_TAG: the snapshot label is tag-prefixed (usb-daily-...)" \
  "grep -q 'usb-daily-2026' '$MOCK_LOG'"
assert "FIX67: borg prune itself succeeds - --keep-X uses the bare interval name, not tag-prefixed" \
  "! grep -q 'borg prune failed\\|unrecognized arguments' '$WORKDIR26/run_tagged.log'"

# Scenario A2: pruneZFSSnapshot's own counting/matching must be
# tag-aware too - it derives the bare interval name from the full label
# by stripping both the date suffix AND the tag prefix before querying
# getZFSSnapshot's ALL branch. Seeds several existing tagged snapshots
# plus one UNTAGGED one (simulating the original, untagged tool sharing
# this same dataset) to verify: no chkDateStr rejection, correct
# over-the-keep-count pruning of the TAGGED ones specifically, and the
# untagged snapshot is left completely untouched (never counted,
# never destroyed) - proving real isolation between the two tools'
# snapshots, not just "no error".
WORKDIR26B="$(mktemp -d)"
mkdir -p "$WORKDIR26B/repo1"
MAILKEYFILE26B="$WORKDIR26B/test26b.key"; echo "testpassphrase" > "$MAILKEYFILE26B"; chmod 600 "$MAILKEYFILE26B"
cat > "$WORKDIR26B/test26b-pruning.conf" << EOF44
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE26B"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR26B/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="daily,2"
PRE_SCRIPT=
POST_SCRIPT=
SNAPSHOT_TAG="usb"
MSG_LEVEL=2
EOF44
chmod 600 "$WORKDIR26B/test26b-pruning.conf"
export MOCK_LOG="$WORKDIR26B/mock.log"
export MOCK_STATE="$WORKDIR26B/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR26B/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
echo "tank/data@usb-daily-20260710" >> "$MOCK_STATE"
echo "tank/data@usb-daily-20260711" >> "$MOCK_STATE"
echo "tank/data@usb-daily-20260712" >> "$MOCK_STATE"
echo "tank/data@daily-20260713" >> "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR26B/test26b-pruning.conf" > "$WORKDIR26B/run_pruning.log" 2>&1
RC_TAGPRUNE=$?
assert "SNAPSHOT_TAG pruning: run succeeds" "[ $RC_TAGPRUNE -eq 0 ]"
assert "SNAPSHOT_TAG pruning: no chkDateStr rejection during pruning" \
  "! grep -q 'does not contain a date or valid backup interval name' '$WORKDIR26B/run_pruning.log'"
assert "SNAPSHOT_TAG pruning: the two oldest TAGGED snapshots get pruned" \
  "grep -q 'usb-daily-20260710' '$WORKDIR26B/run_pruning.log' && grep -q 'usb-daily-20260711' '$WORKDIR26B/run_pruning.log'"
assert "SNAPSHOT_TAG pruning: the newest tagged snapshot is kept, not pruned" \
  "! grep -q 'Purging old snapshot tank/data@usb-daily-20260712' '$WORKDIR26B/run_pruning.log'"
assert "SNAPSHOT_TAG pruning: the UNTAGGED snapshot (other tool) is never touched" \
  "! grep -q 'daily-20260713' '$WORKDIR26B/run_pruning.log'"

# Scenario B: an existing TAGGED monthly snapshot must be correctly
# recognized by the LATEST check - on a non-1st-of-month day (the mock
# date is pinned to the 15th), this must mean "don't take a fresh
# monthly snapshot", exactly like the untagged case already does. This
# is the critical correctness check: if getZFSSnapshot's LATEST search
# weren't tag-aware, it would never find this existing tagged snapshot,
# wrongly concluding "no previous monthly snapshot" and taking a fresh
# one on every single run regardless of the date.
: > "$MOCK_LOG"
echo "tank/data@usb-monthly-20260701" >> "$MOCK_STATE"
cat > "$WORKDIR26/test26-monthly.conf" << EOF42
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE26"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR26/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="monthly,1;daily,7"
PRE_SCRIPT=
POST_SCRIPT=
SNAPSHOT_TAG="usb"
MSG_LEVEL=2
EOF42
chmod 600 "$WORKDIR26/test26-monthly.conf"
sh ./borgsnap_ng.sh run "$WORKDIR26/test26-monthly.conf" > "$WORKDIR26/run_monthly.log" 2>&1
RC_MONTHLY=$?
assert "SNAPSHOT_TAG: monthly+daily run with an existing tagged monthly snapshot still succeeds" "[ $RC_MONTHLY -eq 0 ]"
assert "SNAPSHOT_TAG: the existing tagged monthly snapshot was found - falls through to daily, not a fresh monthly" \
  "grep -q 'usb-daily-2026' '$MOCK_LOG'"
assert "SNAPSHOT_TAG: no fresh (untagged or freshly dated) monthly snapshot was taken" \
  "! grep -q 'zfs snapshot tank/data@monthly' '$MOCK_LOG'"

# Scenario C: an invalid SNAPSHOT_TAG is rejected at config load time.
cat > "$WORKDIR26/test26-invalid.conf" << EOF43
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE26"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR26/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="daily,7"
PRE_SCRIPT=
POST_SCRIPT=
SNAPSHOT_TAG="usb-1"
EOF43
chmod 600 "$WORKDIR26/test26-invalid.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR26/test26-invalid.conf" > "$WORKDIR26/run_invalid.log" 2>&1
RC_INVALIDTAG=$?
assert "SNAPSHOT_TAG: a value with a hyphen is rejected, not silently accepted" "[ $RC_INVALIDTAG -ne 0 ]"
assert "SNAPSHOT_TAG: the rejection message names the actual problem" \
  "grep -q \"invalid value 'usb-1'\" '$WORKDIR26/run_invalid.log'"

# Scenario D: RESTORE_VERIFY/BORG_VERIFY's per-interval matching (not
# the "default:" fallback) must also correctly use the bare interval
# name with a tag set - the same bug class as FIX #67's --keep-X issue,
# just in the interval:depth lookup instead of the prune flag name.
# Specifically targets "daily:" (not "default:") in both settings, so
# a regression here would show up as BOTH falling back to their
# defaults (off) instead of actually applying.
WORKDIR26C="$(mktemp -d)"
mkdir -p "$WORKDIR26C/repo1"
MAILKEYFILE26C="$WORKDIR26C/test26c.key"; echo "testpassphrase" > "$MAILKEYFILE26C"; chmod 600 "$MAILKEYFILE26C"
cat > "$WORKDIR26C/test26c-verify.conf" << EOF45
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE26C"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR26C/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="daily,7"
PRE_SCRIPT=
POST_SCRIPT=
SNAPSHOT_TAG="usb"
BORG_VERIFY="daily:archive"
RESTORE_VERIFY="daily:on"
MSG_LEVEL=2
EOF45
chmod 600 "$WORKDIR26C/test26c-verify.conf"
export MOCK_LOG="$WORKDIR26C/mock.log"
export MOCK_STATE="$WORKDIR26C/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR26C/lock"
export MOCK_ZFS_MOUNTBASE="$WORKDIR26C/mockmounts"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_EXTRACT_FILE="$WORKDIR26C/mockmounts/tank/data/.borgsnap_ng_canary" \
  sh ./borgsnap_ng.sh run "$WORKDIR26C/test26c-verify.conf" > "$WORKDIR26C/run_verify.log" 2>&1
RC_TAGVERIFY=$?
assert "FIX67: per-interval BORG_VERIFY/RESTORE_VERIFY run succeeds with a tag set" "[ $RC_TAGVERIFY -eq 0 ]"
assert "FIX67: the per-interval BORG_VERIFY entry ('daily:archive') actually applied, not the off default" \
  "grep -q 'borg check (depth: archive)' '$WORKDIR26C/run_verify.log'"
assert "FIX67: the per-interval RESTORE_VERIFY entry ('daily:on') actually applied, not the off default" \
  "grep -q 'restore verification passed' '$WORKDIR26C/run_verify.log'"

echo "-------------------------------------"
echo "COMPRESS/CACHEMODE actually applied (real-world bug, FIX #68)"
echo "-------------------------------------"

# Reproduces a real-world report: borgsnap_ng.sh's own call to
# startBackupMachine hardcoded empty strings for the borg repo-options
# argument, regardless of what COMPRESS/CACHEMODE were configured to -
# silently triggering bckp_hdlr.sh's internal fallback
# ("auto,zstd,9"/"ctime,size,inode") on every single run instead. Uses
# values distinctly different from both the old hardcoded fallback and
# cfg_file_hdlr.sh's own "if unset" default, so a pass here can't be a
# coincidental match.
WORKDIR27="$(mktemp -d)"
mkdir -p "$WORKDIR27/repo1"
MAILKEYFILE27="$WORKDIR27/test27.key"; echo "testpassphrase" > "$MAILKEYFILE27"; chmod 600 "$MAILKEYFILE27"
cat > "$WORKDIR27/test27-compress.conf" << EOF46
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="lz4"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE27"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR27/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF46
chmod 600 "$WORKDIR27/test27-compress.conf"
export MOCK_LOG="$WORKDIR27/mock.log"
export MOCK_STATE="$WORKDIR27/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR27/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR27/test27-compress.conf" > "$WORKDIR27/run_compress.log" 2>&1
RC_COMPRESS=$?
assert "FIX68: run succeeds" "[ $RC_COMPRESS -eq 0 ]"
assert "FIX68: COMPRESS from the config ('lz4') is actually used, not the old 'auto,zstd,9' fallback" \
  "grep -q -- '--compression=lz4' '$MOCK_LOG'"
assert "FIX68: CACHEMODE from the config ('mtime,size') is actually used, not the old 'ctime,size,inode' fallback" \
  "grep -q -- '--files-cache=mtime,size' '$MOCK_LOG'"
assert "FIX68: the stale hardcoded compression value no longer appears anywhere" \
  "! grep -q 'auto,zstd,9' '$MOCK_LOG'"

echo "-------------------------------------"
echo "Existing-but-never-initialized repo directory (real-world bug, FIX #69)"
echo "-------------------------------------"

# Reproduces a real-world report: a repo directory that already exists
# (e.g. pre-created by setup-backup.sh, which deliberately only creates
# the directory - initialization is this script's own job) but was
# never actually borg-init'd. The old logic used "does the directory
# exist" as a stand-in for "is this already an initialized repo", so
# init was silently skipped and createBorg failed with "not a valid
# repository". Directory is pre-created here WITHOUT any "BORG_INIT:"
# seed in MOCK_STATE, precisely matching that real-world state.
WORKDIR28="$(mktemp -d)"
mkdir -p "$WORKDIR28/repo1"
MAILKEYFILE28="$WORKDIR28/test28.key"; echo "testpassphrase" > "$MAILKEYFILE28"; chmod 600 "$MAILKEYFILE28"
cat > "$WORKDIR28/test28-existingdir.conf" << EOF47
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE28"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR28/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MSG_LEVEL=2
EOF47
chmod 600 "$WORKDIR28/test28-existingdir.conf"
export MOCK_LOG="$WORKDIR28/mock.log"
export MOCK_STATE="$WORKDIR28/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR28/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
sh ./borgsnap_ng.sh run "$WORKDIR28/test28-existingdir.conf" > "$WORKDIR28/run_existingdir.log" 2>&1
RC_EXISTINGDIR=$?
assert "FIX69: run succeeds despite the directory pre-existing without being borg-init'd" "[ $RC_EXISTINGDIR -eq 0 ]"
assert "FIX69: borg init actually ran against the pre-existing (but uninitialized) directory" \
  "grep -q '^borg init' '$MOCK_LOG'"
assert "FIX69: borg create succeeded afterward, not 'not a valid repository'" \
  "grep -q '^borg create' '$MOCK_LOG' && ! grep -q 'not a valid repository' '$WORKDIR28/run_existingdir.log'"

# Second run against the SAME (now genuinely initialized) repo must NOT
# attempt init again.
: > "$MOCK_LOG"
sh ./borgsnap_ng.sh run "$WORKDIR28/test28-existingdir.conf" > "$WORKDIR28/run_second.log" 2>&1
RC_SECOND=$?
assert "FIX69: second run against the now-real repo succeeds" "[ $RC_SECOND -eq 0 ]"
assert "FIX69: second run does not attempt init again" "! grep -q '^borg init' '$MOCK_LOG'"

echo "-------------------------------------"
echo "Wrong-passphrase repo (rc 52) gets a clear, specific message (FIX #70)"
echo "-------------------------------------"

# Reproduces a real-world report: reusing an existing BorgBase repo
# (already initialized in an earlier setup with its own passphrase)
# against a config whose PASS points to a different (e.g. freshly
# generated) passphrase - borg's own "borg list" correctly rejects this
# with rc 52 (PassphraseWrong per borg's Message IDs docs), but this used
# to fall through to a generic "unexpected error... check your client's
# borg version" message that didn't name the actual, common problem.
WORKDIR29="$(mktemp -d)"
mkdir -p "$WORKDIR29/repo1"
MAILKEYFILE29="$WORKDIR29/test29.key"; echo "testpassphrase" > "$MAILKEYFILE29"; chmod 600 "$MAILKEYFILE29"

cat > "$WORKDIR29/test29-borgbase.conf" << EOF48
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE29"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="borgbase:ssh://borgbase_repo/./repo, borg, repokey-blake2"
REPOSKIP="NONE"
RETENTIONPERIOD="daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF48
chmod 600 "$WORKDIR29/test29-borgbase.conf"
export MOCK_LOG="$WORKDIR29/mock.log"
export MOCK_STATE="$WORKDIR29/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR29/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_LIST_RC=52 sh ./borgsnap_ng.sh run "$WORKDIR29/test29-borgbase.conf" > "$WORKDIR29/run_borgbase.log" 2>&1
RC_BORGBASE52=$?
assert "FIX70/FIX71: BorgBase wrong-passphrase run still succeeds overall (this repo is skipped, not fatal)" "[ $RC_BORGBASE52 -eq 0 ]"
assert "FIX70: BorgBase wrong-passphrase message names the actual problem, not 'unexpectedly'" \
  "grep -q 'rejected the configured passphrase' '$WORKDIR29/run_borgbase.log'"
assert "FIX70: BorgBase wrong-passphrase message does not fall back to the generic wording" \
  "! grep -q 'check failed unexpectedly' '$WORKDIR29/run_borgbase.log'"

cat > "$WORKDIR29/test29-generic.conf" << EOF49
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE29"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="$WORKDIR29/repo1, "
REPOSKIP="NONE"
RETENTIONPERIOD="daily,7"
PRE_SCRIPT=
POST_SCRIPT=
EOF49
chmod 600 "$WORKDIR29/test29-generic.conf"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_LIST_RC=52 sh ./borgsnap_ng.sh run "$WORKDIR29/test29-generic.conf" > "$WORKDIR29/run_generic.log" 2>&1
RC_GENERIC52=$?
assert "FIX70/FIX71: generic-repo wrong-passphrase run still succeeds overall (this repo is skipped, not fatal)" "[ $RC_GENERIC52 -eq 0 ]"
assert "FIX70: generic-repo wrong-passphrase message names the actual problem" \
  "grep -q 'rejected the configured passphrase' '$WORKDIR29/run_generic.log'"
assert "FIX70: generic-repo wrong-passphrase does not attempt a pointless init" \
  "! grep -q '^borg init' '$MOCK_LOG'"

echo "-------------------------------------"
echo "A problem BorgBase repo no longer takes down LATER repos too (FIX #71)"
echo "-------------------------------------"

# Reproduces a real-world report: REPOLIST has a problematic BorgBase
# repo (wrong passphrase, rc 52) followed by a working local repo -
# before FIX #71, ensureBorgBaseInit's die() call aborted the ENTIRE
# process the moment it hit the BorgBase repo's problem, so the local
# repo listed AFTER it in REPOLIST never even got attempted, regardless
# of whether IT was configured correctly.
WORKDIR30="$(mktemp -d)"
mkdir -p "$WORKDIR30/repo_after"
MAILKEYFILE30="$WORKDIR30/test30.key"; echo "testpassphrase" > "$MAILKEYFILE30"; chmod 600 "$MAILKEYFILE30"
cat > "$WORKDIR30/test30-order.conf" << EOF50
LOCAL_BORG_USER="$(id -un)"
FS="tank/data,"
COMPRESS="zstd,9"
CACHEMODE="mtime,size"
PASS="$MAILKEYFILE30"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=false
REPOLIST="borgbase:ssh://borgbase_repo/./repo, borg, repokey-blake2; $WORKDIR30/repo_after, "
REPOSKIP="NONE"
RETENTIONPERIOD="daily,7"
PRE_SCRIPT=
POST_SCRIPT=
MSG_LEVEL=2
EOF50
chmod 600 "$WORKDIR30/test30-order.conf"
export MOCK_LOG="$WORKDIR30/mock.log"
export MOCK_STATE="$WORKDIR30/mock.state"
export BORGSNAP_LOCKDIR="$WORKDIR30/lock"
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_BORG_LIST_RC=52 MOCK_BORG_LIST_RC_REPO="ssh://borgbase_repo" sh ./borgsnap_ng.sh run "$WORKDIR30/test30-order.conf" > "$WORKDIR30/run_order.log" 2>&1
RC_ORDER=$?
assert "FIX71: run succeeds despite the earlier BorgBase repo's problem" "[ $RC_ORDER -eq 0 ]"
assert "FIX71: the BorgBase problem is still reported clearly" \
  "grep -q 'rejected the configured passphrase' '$WORKDIR30/run_order.log'"
assert "FIX71: the LATER local repo still gets backed up despite the earlier repo's problem" \
  "grep -q \"borg create.*$WORKDIR30/repo_after\" '$MOCK_LOG'"


echo "-------------------------------------"
echo "Result: $PASS_CNT passed, $FAIL_CNT failed"
echo "Mock log: $MOCK_LOG"
[ "$FAIL_CNT" -eq 0 ]
