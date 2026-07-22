#!/bin/sh
# TESTKIT_VERSION=2026-07-20.12
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
  for b in zfs zpool borg mount umount sudo date sendmail; do
    if [ -e "$BACKUP_DIR/$b" ] || [ -L "$BACKUP_DIR/$b" ]; then
      mv "$BACKUP_DIR/$b" "/usr/local/bin/$b"
    else
      rm -f "/usr/local/bin/$b"
    fi
  done
}
trap cleanup_mocks EXIT INT TERM HUP

for b in zfs zpool borg mount umount sudo date sendmail; do
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
assert "FIX5: umount called for real mountpoints (depth 2)" \
  "grep -q 'umount .*/tank/data' '$MOCK_LOG'"
assert "FIX5: recursive child mount also unmounted" \
  "grep -q 'umount .*/tank/data/child' '$MOCK_LOG'"
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
  "grep -q 'zfs receive -s tank/zfssendtarget/tank/data' '$MOCK_LOG'"
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
sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend3.log" 2>&1
RC_ZFSSEND3=$?
assert "FIX43: target exists but bookmark missing -> run fails" "[ $RC_ZFSSEND3 -ne 0 ]"
assert "FIX43: missing-bookmark run gives the specific actionable message" \
  "grep -q 'tracking bookmark' '$WORKDIR3/run_zfssend3.log' && grep -q 'is missing' '$WORKDIR3/run_zfssend3.log'"

# Fault injection on both sides of the send|receive pipe - this is the
# whole point of the dual-tempfile exit-code pattern (see the comment in
# backendZfsSend): each side's real exit code must be caught
# independently, not just whichever happens to be the pipeline's last
# command.
: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_FAIL_SEND=1 sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_sendfail.log" 2>&1
RC_SENDFAIL=$?
assert "FIX42: a failing zfs send aborts the run" "[ $RC_SENDFAIL -ne 0 ]"

: > "$MOCK_LOG"; : > "$MOCK_STATE"
MOCK_ZFS_FAIL_RECEIVE=1 sh ./borgsnap_ng.sh run "$WORKDIR3/test3-zfssend.conf" > "$WORKDIR3/run_zfssend_recvfail.log" 2>&1
RC_RECVFAIL=$?
assert "FIX42: a failing zfs receive aborts the run" "[ $RC_RECVFAIL -ne 0 ]"

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
assert "FIX44: an interrupted send fails the run" "[ $RC_INTERRUPT1 -ne 0 ]"
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
assert "FIX44: a second interruption during resume also fails the run" "[ $RC_DOUBLEINTERRUPT -ne 0 ]"
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
assert "FIX46: the actual backup still happened" "grep -q 'zfs receive -s usbpool/backups/tank/data' '$MOCK_LOG'"

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
echo "Result: $PASS_CNT passed, $FAIL_CNT failed"
echo "Mock log: $MOCK_LOG"
[ "$FAIL_CNT" -eq 0 ]
