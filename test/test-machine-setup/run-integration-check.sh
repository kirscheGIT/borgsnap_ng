#!/bin/sh
# TESTKIT_VERSION=2026-07-20.40
# run-integration-check.sh
#
# Runs both validation steps discussed after the mock-only fixes:
#   1. Mock test harness (test/run_mock_test.sh) inside docker-dev — a
#      regression check that the fixes still hold in a containerized/Linux
#      environment, not just this Mac's shell.
#   2. A REAL borgsnap_ng.sh run against the actual ZFS test pool in
#      zfs-dev — exercises real zfs/borg behavior the mocks can't cover
#      (recursive snapshots against a real child dataset, real mount/umount,
#      real borg prune glob matching against your actual installed borg
#      version).
#
# This script runs on the Mac host and drives both VMs via `limactl shell`.
# It does not modify the repo's tracked files; all real-run scaffolding
# (config, keyfile, repo dirs, extra test dataset) is created inside
# zfs-dev under a dedicated directory and is removed again at the end
# unless --keep is given.
#
# Usage:
#   ./run-integration-check.sh              # run both steps, clean up after
#   ./run-integration-check.sh --keep       # leave the zfs-dev test artifacts
#                                            # in place for manual inspection
#   ./run-integration-check.sh --skip-mock  # only run the real ZFS step
#   ./run-integration-check.sh --skip-real  # only run the mock harness step

set -eu

# TESTKIT_VERSION=2026-07-20.40
#
# Preflight version check. This script, test/run_mock_test.sh, and
# test/mocks/date are a matched set - a stale copy of any one of them
# (e.g. after re-downloading only one file, or answering a clarifying
# question and losing track of an earlier attachment) has repeatedly
# produced confusing, hard-to-diagnose failures deep into a run rather than
# an obvious error up front. This check reads the companion files directly
# from the local checkout (no VM involved yet) and refuses to proceed on any
# mismatch, so staleness is caught in under a second instead of after a full
# multi-minute run against two VMs.
TESTKIT_VERSION="2026-07-20.40"
echo "run-integration-check.sh - TESTKIT_VERSION=$TESTKIT_VERSION"

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
else
  REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
fi

preflight_fail=0
preflight_check_version() {
  # $1 = file path, $2 = human label
  if [ ! -f "$1" ]; then
    echo "PREFLIGHT: $2 not found at $1" >&2
    preflight_fail=1
    return
  fi
  found="$(sed -n 's/^# TESTKIT_VERSION=//p' "$1" | head -1)"
  if [ "$found" != "$TESTKIT_VERSION" ]; then
    echo "PREFLIGHT: $2 is stale (expected TESTKIT_VERSION=$TESTKIT_VERSION, found '${found:-none}') - $1" >&2
    preflight_fail=1
  fi
}

preflight_check_version "$REPO_ROOT/test/run_mock_test.sh" "test/run_mock_test.sh"
preflight_check_version "$REPO_ROOT/test/mocks/date" "test/mocks/date"
preflight_check_version "$REPO_ROOT/test/mocks/zfs" "test/mocks/zfs"
preflight_check_version "$REPO_ROOT/test/mocks/zpool" "test/mocks/zpool"
preflight_check_version "$REPO_ROOT/test/mocks/borg" "test/mocks/borg"
preflight_check_version "$REPO_ROOT/test/mocks/sendmail" "test/mocks/sendmail"
preflight_check_version "$REPO_ROOT/test/mocks/ssh" "test/mocks/ssh"
preflight_check_version "$REPO_ROOT/test/mocks/mount" "test/mocks/mount"

for mockbin in date zfs zpool borg sendmail ssh mount; do
  if [ ! -x "$REPO_ROOT/test/mocks/$mockbin" ]; then
    echo "PREFLIGHT: test/mocks/$mockbin exists but is not executable (chmod +x test/mocks/$mockbin)" >&2
    preflight_fail=1
  fi
done

# backup/bckp_hdlr.sh, borg/borg_hdlr.sh, filesystem/zfs_hdlr.sh, and
# filesystem/zfs_snap_mount.sh are project source, not part of this testkit,
# so they don't carry a TESTKIT_VERSION line - instead check for specific
# fix markers this integration check exercises.
preflight_check_marker() {
  # $1 = file path (relative to REPO_ROOT), $2 = marker string
  if [ -f "$REPO_ROOT/$1" ] && ! grep -q "$2" "$REPO_ROOT/$1"; then
    echo "PREFLIGHT: $1 is missing the $2 fix" >&2
    preflight_fail=1
  fi
}
if [ ! -f "$REPO_ROOT/filesystem/zfs_send_hdlr.sh" ]; then
  echo "PREFLIGHT: filesystem/zfs_send_hdlr.sh not found - this is a new file introduced by FIX #41, not just an update to an existing one" >&2
  preflight_fail=1
fi

preflight_check_marker "borgsnap_ng.sh" "zfs_send_hdlr.sh"
preflight_check_marker "borgsnap_ng.sh" "FIX #49"
preflight_check_marker "borgsnap_ng.sh" "FIX #68"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #33"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #38"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #39"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #41"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #41"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #50"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #50"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #55"
preflight_check_marker "backup/bckp_hdlr.sh" "BORG_VERIFY"
preflight_check_marker "borg/borg_hdlr.sh" "BORG_VERIFY"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #57"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #60"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #62"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #63"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #65"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #69"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #70"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #71"
if [ ! -f "$REPO_ROOT/test/mocks/ssh" ]; then
  echo "PREFLIGHT: test/mocks/ssh not found - this is a new file introduced by FIX #58, not just an update to an existing one" >&2
  preflight_fail=1
fi
preflight_check_marker "cfg_file_hdlr.sh" "BORG_VERIFY"
preflight_check_marker "cfg_file_hdlr.sh" "RESTORE_VERIFY"
preflight_check_marker "cfg_file_hdlr.sh" "MSG_LEVEL"
preflight_check_marker "cfg_file_hdlr.sh" "SNAPSHOT_TAG"
preflight_check_marker "borg/borg_hdlr.sh" "checkRepoCapacity"
preflight_check_marker "backup/bckp_hdlr.sh" "RESTORE_VERIFY"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #64"
preflight_check_marker "backup/bckp_hdlr.sh" "SNAPSHOT_TAG"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #67"
preflight_check_marker "borg/borg_hdlr.sh" "checkRestoreBorg"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "RESTOREVERIFY_ACTIVE"
preflight_check_marker "mail_wrapper.sh" "PARTIAL FAILURE"
if [ ! -f "$REPO_ROOT/test/mocks/borg" ]; then
  echo "PREFLIGHT: test/mocks/borg not found" >&2
  preflight_fail=1
else
  preflight_check_marker "test/mocks/borg" "MOCK_BORG_CHECK_RC"
fi
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #41"
preflight_check_marker "filesystem/zfs_snap_mount.sh" "FIX #52"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #42"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #43"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #44"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #45"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #46"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #51"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #54"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #56"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "FIX #59"
preflight_check_marker "filesystem/zfs_send_hdlr.sh" "CAPACITY_WARN_PERCENT"
if [ ! -f "$REPO_ROOT/test/mocks/zpool" ]; then
  echo "PREFLIGHT: test/mocks/zpool not found - this is a new file introduced by FIX #46, not just an update to an existing one" >&2
  preflight_fail=1
fi
if [ ! -f "$REPO_ROOT/mail_wrapper.sh" ]; then
  echo "PREFLIGHT: mail_wrapper.sh not found - this is a new file introduced by FIX #47, not just an update to an existing one" >&2
  preflight_fail=1
else
  preflight_check_marker "mail_wrapper.sh" "FIX #47"
  preflight_check_marker "mail_wrapper.sh" "FIX #48"
fi
if [ ! -f "$REPO_ROOT/test/mocks/sendmail" ]; then
  echo "PREFLIGHT: test/mocks/sendmail not found - this is a new file introduced by FIX #47, not just an update to an existing one" >&2
  preflight_fail=1
fi
preflight_check_marker "cfg_file_hdlr.sh" "FIX #40"
preflight_check_marker "common/msg_and_err_hdlr.sh" "FIX #35"
preflight_check_marker "common/msg_and_err_hdlr.sh" "FIX #53"
preflight_check_marker "common/msg_and_err_hdlr.sh" "initBorg"
preflight_check_marker "common/msg_and_err_hdlr.sh" "pruneBorg"
preflight_check_marker "common/dir_functions.sh" "FIX #58"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #36"
preflight_check_marker "filesystem/zfs_hdlr.sh" "FIX #37"
preflight_check_marker "filesystem/zfs_hdlr.sh" "FIX #64"
preflight_check_marker "filesystem/zfs_hdlr.sh" "SNAPSHOT_TAG"

if [ "$preflight_fail" -eq 1 ]; then
  echo "" >&2
  echo "Aborting before touching any VM - one or more files are out of sync." >&2
  echo "Re-copy the latest delivered files into the repo, then re-run." >&2
  echo "(Pass --skip-version-check to bypass this, not recommended.)" >&2
  case " $* " in
    *" --skip-version-check "*) echo "--skip-version-check given: continuing anyway." >&2 ;;
    *) exit 1 ;;
  esac
fi

KEEP=0
RUN_MOCK=1
RUN_REAL=1

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --skip-mock) RUN_MOCK=0 ;;
    --skip-real) RUN_REAL=0 ;;
    --skip-version-check) ;; # already handled by the preflight check above
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

command -v limactl >/dev/null 2>&1 || { echo "limactl not found - brew install lima" >&2; exit 1; }

MOCK_RESULT="skipped"
REAL_RESULT="skipped"
REAL_ZFSSEND_RESULT="skipped"
REAL_RESUME_RESULT="skipped"
REAL_POOL_RESULT="skipped"
REAL_FIX49_RESULT="skipped"
REAL_TESTDIR="/home/__USER__/borgsnap-integration-test"  # __USER__ resolved below

# =========================================================================
# Step 1: mock harness regression check in docker-dev
# =========================================================================
if [ "$RUN_MOCK" -eq 1 ]; then
  echo "=================================================================="
  echo "Step 1/2: mock test harness in docker-dev"
  echo "=================================================================="

  if ! limactl list --quiet 2>/dev/null | grep -qx docker-dev; then
    echo "Instance 'docker-dev' does not exist - skipping this step." >&2
    MOCK_RESULT="skipped (no instance)"
  else
    DOCKER_USER="$(limactl shell docker-dev whoami 2>/dev/null | tr -d '\r\n')"
    if [ -z "$DOCKER_USER" ]; then
      echo "Could not determine guest username in docker-dev - skipping." >&2
      MOCK_RESULT="skipped (no username)"
    else
      REPO_IN_VM="/home/$DOCKER_USER/borgsnap_ng"
      echo "==> Repo in docker-dev: $REPO_IN_VM"
      set +e
      # sudo is required: run_mock_test.sh symlinks its mocks into
      # /usr/local/bin (see test/README.md's "Caveat" section), which the
      # non-root Lima guest user can't write to. docker-dev is a disposable
      # VM anyway, so polluting its /usr/local/bin is harmless here.
      limactl shell docker-dev sudo sh -c "
        set -e
        cd '$REPO_IN_VM'
        chmod +x test/mocks/* test/run_mock_test.sh
        sh test/run_mock_test.sh
      "
      MOCK_RC=$?
      set -e
      if [ "$MOCK_RC" -eq 0 ]; then
        MOCK_RESULT="PASS"
      else
        MOCK_RESULT="FAIL (exit $MOCK_RC)"
      fi
    fi
  fi
  echo ""
fi

# =========================================================================
# Step 2: real ZFS integration run in zfs-dev
# =========================================================================
if [ "$RUN_REAL" -eq 1 ]; then
  echo "=================================================================="
  echo "Step 2/2: real borgsnap_ng.sh run against the zfs-dev test pool"
  echo "=================================================================="

  if ! limactl list --quiet 2>/dev/null | grep -qx zfs-dev; then
    echo "Instance 'zfs-dev' does not exist - skipping this step." >&2
    REAL_RESULT="skipped (no instance)"
  else
    ZFS_USER="$(limactl shell zfs-dev whoami 2>/dev/null | tr -d '\r\n')"
    if [ -z "$ZFS_USER" ]; then
      echo "Could not determine guest username in zfs-dev - skipping." >&2
      REAL_RESULT="skipped (no username)"
    else
      REPO_IN_VM="/home/$ZFS_USER/borgsnap_ng"
      REAL_TESTDIR="/home/$ZFS_USER/borgsnap-integration-test"
      echo "==> Repo in zfs-dev: $REPO_IN_VM"
      echo "==> Scratch dir in zfs-dev: $REAL_TESTDIR"

      set +e
      limactl shell zfs-dev sudo sh -c "
        set -e

        # --- 1. borgbackup, only if not already present ---------------
        command -v borg >/dev/null 2>&1 || {
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq
          apt-get install -y -qq borgbackup
        }

        # --- 2. a real child dataset, to exercise the recursive path ---
        zfs list testpool/data/sub >/dev/null 2>&1 || zfs create testpool/data/sub

        # FIX #52: a marker file directly in the PARENT dataset (not the
        # child) - the bug this guards against silently mounted only
        # child datasets in the recursive branch, never the top-level
        # dataset itself, so its own files never made it into the borg
        # archive at all. A marker in the child alone wouldn't catch that
        # regression; it has to live in testpool/data directly.
        echo fix52-parent-marker-content > /testpool/data/fix52-parent-marker.txt

        # --- 3. scratch dir: keyfile, two local repos ------------------
        # NOTE: do NOT pre-create repo1/repo2 here. borgsnap_ng.sh only
        # calls initBorg() when the repo directory does not already exist
        # (see the direxists check in backup/bckp_hdlr.sh) - it creates the
        # directory itself and inits the repo as part of that. Pre-creating
        # the directories would skip initBorg entirely and createBorg would
        # then fail against an empty, uninitialized repo.
        mkdir -p '$REAL_TESTDIR'
        echo 'integration-test-passphrase' > '$REAL_TESTDIR/test.key'
        chmod 600 '$REAL_TESTDIR/test.key'

        # FIX #49: every other real test in this script does 'cd \$REPO_IN_VM'
        # before invoking borgsnap_ng.sh - which would silently mask a real
        # bug (its relative '. ./...' sourcing only worked when CWD already
        # happened to be its own directory). This check deliberately does
        # NOT cd there, using its own isolated dataset/config so it can't
        # interfere with the main test's snapshot-label expectations below.
        zfs create testpool/fix49test 2>/dev/null || true
        cat > '$REAL_TESTDIR/fix49.conf' << CONF
LOCAL_BORG_USER=\"root\"
FS=\"testpool/fix49test,\"
COMPRESS=\"zstd,9\"
CACHEMODE=\"mtime,size\"
PASS=\"$REAL_TESTDIR/test.key\"
BASEDIR=\"\"
LOCAL_READABLE_BY_OTHERS=false
REPOLIST=\"$REAL_TESTDIR/fix49repo, \"
REPOSKIP=\"NONE\"
RETENTIONPERIOD=\"monthly,1;weekly,4;daily,7\"
PRE_SCRIPT=
POST_SCRIPT=
CONF
        cd /root 2>/dev/null || cd /
        sh '$REPO_IN_VM/borgsnap_ng.sh' run '$REAL_TESTDIR/fix49.conf'
      "
      REAL_FIX49_RC=$?
      set -e
      if [ "$REAL_FIX49_RC" -eq 0 ]; then
        REAL_FIX49_RESULT="PASS"
      else
        REAL_FIX49_RESULT="FAIL (exit $REAL_FIX49_RC)"
      fi
      if [ "$KEEP" -eq 0 ]; then
        limactl shell zfs-dev sudo sh -c "zfs destroy -r testpool/fix49test 2>/dev/null || true"
      fi
      set +e

      limactl shell zfs-dev sudo sh -c "
        mkdir -p '$REAL_TESTDIR'

        # NOTE: LOCAL_BORG_USER is intentionally root, not the invoking Mac
        # users guest-VM name. cfg_file_hdlr.sh has a hard gate requiring
        # id -un to exactly match LOCAL_BORG_USER (see the TODO #20 comment
        # right above that check in the source). Since this whole block
        # runs under sudo (borgsnap_ng.sh's zfs commands aren't individually
        # sudo-prefixed, only mount/umount are - see the earlier code
        # review), the executing user is root, so the config must say so.
        cat > '$REAL_TESTDIR/test.conf' << CONF
LOCAL_BORG_USER=\"root\"
FS=\"testpool/data,r; testpool/home,\"
COMPRESS=\"zstd,9\"
CACHEMODE=\"mtime,size\"
PASS=\"$REAL_TESTDIR/test.key\"
BASEDIR=\"\"
LOCAL_READABLE_BY_OTHERS=false
REPOLIST=\"$REAL_TESTDIR/repo1, ; $REAL_TESTDIR/repo2, \"
REPOSKIP=\"NONE\"
RETENTIONPERIOD=\"monthly,1;weekly,4;daily,7\"
PRE_SCRIPT=
POST_SCRIPT=
CONF

        # --- 4. the actual run ------------------------------------------
        cd '$REPO_IN_VM'
        sh borgsnap_ng.sh run '$REAL_TESTDIR/test.conf'
      "
      REAL_RC=$?
      set -e

      if [ "$REAL_RC" -eq 0 ]; then
        echo ""
        echo "==> Run finished with exit 0. Verifying artifacts..."
        set +e
        limactl shell zfs-dev sudo sh -c "
          echo '--- zfs snapshots ---'
          zfs list -t snapshot | grep testpool
          echo '--- recursive child dataset snapshot present? ---'
          zfs list -t snapshot | grep 'testpool/data/sub@' && echo 'YES' || echo 'NO (recursive fix did not propagate!)'
          echo '--- borg archives, repo1 ---'
          BORG_PASSPHRASE=\$(cat '$REAL_TESTDIR/test.key') borg list '$REAL_TESTDIR/repo1' 2>&1
          echo '--- FIX #52: does the archive actually contain the PARENT dataset file, not just the child? ---'
          REAL_ARCHIVE=\$(BORG_PASSPHRASE=\$(cat '$REAL_TESTDIR/test.key') borg list --short '$REAL_TESTDIR/repo1' 2>/dev/null | grep testpool_data- | tail -1)
          if BORG_PASSPHRASE=\$(cat '$REAL_TESTDIR/test.key') borg list \"$REAL_TESTDIR/repo1::\$REAL_ARCHIVE\" 2>&1 | grep -q fix52-parent-marker.txt; then
            echo 'YES - parent file present'
          else
            echo 'NO - parent dataset content missing from archive!'
            exit 1
          fi
        "
        VERIFY_RC=$?
        set -e
        if [ "$VERIFY_RC" -eq 0 ]; then
          REAL_RESULT="PASS"
        else
          REAL_RESULT="FAIL (run succeeded, verification failed - see output above)"
        fi

        # FIX #42/#43: real zfs-send backend test. Step 1 (full send) plus
        # step 3 (bookmark-based incremental). Only runs if the borg-based
        # real test above already passed, since it reuses the same
        # testpool/data dataset. This exercises real zfs send/receive/
        # bookmark semantics the mock harness can't - the mock fakes the
        # data stream with plain echo/cat and doesn't enforce real
        # bookmark/snapshot relationships.
        if [ "$REAL_RESULT" = "PASS" ]; then
          echo ""
          echo "==> Testing the real zfs-send backend (FIX #42, step 1: full send)..."
          set +e
          limactl shell zfs-dev sudo sh -c "
            cd '$REPO_IN_VM'
            cat > '$REAL_TESTDIR/test-zfssend.conf' << CONF
LOCAL_BORG_USER=\"root\"
FS=\"testpool/data,\"
COMPRESS=\"zstd,9\"
CACHEMODE=\"mtime,size\"
PASS=\"$REAL_TESTDIR/test.key\"
BASEDIR=\"\"
LOCAL_READABLE_BY_OTHERS=false
REPOLIST=\"zfssend:testpool/zfssendtarget, \"
REPOSKIP=\"NONE\"
RETENTIONPERIOD=\"monthly,1;weekly,4;daily,7\"
PRE_SCRIPT=
POST_SCRIPT=
CONF
            sh borgsnap_ng.sh run '$REAL_TESTDIR/test-zfssend.conf'
          "
          REAL_ZFSSEND_RC=$?
          set -e
          if [ "$REAL_ZFSSEND_RC" -eq 0 ]; then
            set +e
            limactl shell zfs-dev sudo sh -c "
              echo '--- zfs-send target dataset after first (full) send ---'
              zfs list -o name,used,creation -r testpool/zfssendtarget 2>&1
              echo '--- snapshots on the target dataset (should be exactly 1 after the first send) ---'
              zfs list -t snapshot -r testpool/zfssendtarget/testpool/data 2>&1
              echo '--- tracking bookmark ---'
              zfs list -t bookmark -r testpool/data 2>&1
            "
            REAL_ZFSSEND_VERIFY_RC=$?
            set -e
            if [ "$REAL_ZFSSEND_VERIFY_RC" -eq 0 ]; then
              echo ""
              echo "==> Testing incremental send via bookmark (FIX #43, step 3)..."
              set +e
              limactl shell zfs-dev sudo sh -c "
                cd '$REPO_IN_VM'
                sh borgsnap_ng.sh run '$REAL_TESTDIR/test-zfssend.conf'
              "
              REAL_ZFSSEND_INCR_RC=$?
              set -e
              if [ "$REAL_ZFSSEND_INCR_RC" -eq 0 ]; then
                set +e
                limactl shell zfs-dev sudo sh -c "
                  echo '--- zfs-send target dataset after second (incremental) send ---'
                  zfs list -o name,used,creation -r testpool/zfssendtarget 2>&1
                  echo '--- snapshots on the target dataset (must now be 2+ - proves the incremental added a genuinely new point-in-time, not a no-op) ---'
                  zfs list -t snapshot -r testpool/zfssendtarget/testpool/data 2>&1
                  SNAPCOUNT=\$(zfs list -H -t snapshot -o name -r testpool/zfssendtarget/testpool/data 2>/dev/null | wc -l)
                  echo \"snapshot count on target: \$SNAPCOUNT\"
                  if [ \"\$SNAPCOUNT\" -lt 2 ]; then
                    echo \"ERROR: expected at least 2 snapshots on target after incremental send, found \$SNAPCOUNT\" >&2
                    exit 1
                  fi
                  echo '--- tracking bookmark after incremental (should still exist, now pointing at the newer snapshot) ---'
                  zfs list -t bookmark -r testpool/data 2>&1
                  echo '--- readonly property on target (FIX #45, must be on) ---'
                  RO=\$(zfs get -H -o value readonly testpool/zfssendtarget/testpool/data)
                  echo \"readonly=\$RO\"
                  if [ \"\$RO\" != \"on\" ]; then
                    echo \"ERROR: expected readonly=on, got '\$RO'\" >&2
                    exit 1
                  fi
                "
                REAL_ZFSSEND_INCR_VERIFY_RC=$?
                set -e
                if [ "$REAL_ZFSSEND_INCR_VERIFY_RC" -eq 0 ]; then
                  REAL_ZFSSEND_RESULT="PASS"
                else
                  REAL_ZFSSEND_RESULT="FAIL (incremental run succeeded, verification failed)"
                fi
              else
                REAL_ZFSSEND_RESULT="FAIL (incremental send exit $REAL_ZFSSEND_INCR_RC)"
              fi
            else
              REAL_ZFSSEND_RESULT="FAIL (first run succeeded, target dataset/bookmark not found)"
            fi
          else
            REAL_ZFSSEND_RESULT="FAIL (exit $REAL_ZFSSEND_RC)"
          fi
          if [ "$KEEP" -eq 0 ]; then
            limactl shell zfs-dev sudo sh -c "
              zfs destroy -r testpool/zfssendtarget 2>/dev/null || true
              zfs destroy 'testpool/data#zfssend-testpool_zfssendtarget' 2>/dev/null || true
            "
          fi

          # FIX #44: real resumable-receive test. Uses process-kill to
          # interrupt a real transfer - from ZFS's perspective this is
          # indistinguishable from a network loss (a receive that just
          # stops getting bytes), and needs no second network interface to
          # simulate. A real, sizable (incompressible) dataset is used so
          # the transfer has an actual time window to interrupt - too small
          # and the kill might land after it already finished.
          if [ "$REAL_ZFSSEND_RESULT" = "PASS" ]; then
            echo ""
            echo "==> Testing real resumable receive via process-kill (FIX #44)..."
            set +e
            limactl shell zfs-dev sudo sh -c "
              set -e
              echo 'STEP: cleaning up any stale state from a previous attempt'
              zfs destroy -r testpool/zfsresumetarget 2>/dev/null || true
              zfs destroy -r testpool/bigdata 2>/dev/null || true
              zfs destroy 'testpool/bigdata#zfssend-testpool_zfsresumetarget' 2>/dev/null || true

              echo 'STEP: zfs create testpool/bigdata'
              zfs create testpool/bigdata
              echo 'STEP: dd 500MiB of random data'
              dd if=/dev/urandom of=/testpool/bigdata/bigfile bs=1M count=500 2>&1 | tail -3
              echo 'STEP: zfs snapshot testpool/bigdata@daily-20250101'
              zfs snapshot testpool/bigdata@daily-20250101
              echo 'STEP: zfs create -p testpool/zfsresumetarget/testpool'
              zfs create -p testpool/zfsresumetarget/testpool 2>/dev/null || true

              echo 'STEP: starting interrupted transfer via mkfifo + timeout'
              rm -f /tmp/zfssendpipe
              mkfifo /tmp/zfssendpipe
              zfs send testpool/bigdata@daily-20250101 > /tmp/zfssendpipe 2>/tmp/zfssend.err &
              SENDPID=\$!
              echo \"send backgrounded, PID=\$SENDPID\"
              set +e
              timeout --signal=KILL 0.5 zfs receive -s testpool/zfsresumetarget/testpool/bigdata < /tmp/zfssendpipe
              TIMEOUTRC=\$?
              set -e
              echo \"timeout/receive rc=\$TIMEOUTRC (124 or 137 means it was killed as expected; 0 would mean it finished before the timeout - data set may need to be bigger)\"
              rm -f /tmp/zfssendpipe
              cat /tmp/zfssend.err 2>/dev/null || true
              rm -f /tmp/zfssend.err
              echo 'STEP: interruption sequence complete'
              sleep 0.5

              echo '--- resume token after interruption ---'
              zfs get -H -o value receive_resume_token testpool/zfsresumetarget/testpool/bigdata
            "
            REAL_RESUME_SETUP_RC=$?
            set -e
            if [ "$REAL_RESUME_SETUP_RC" -eq 0 ]; then
              echo ""
              echo "==> Running borgsnap_ng.sh so it detects and completes the resume itself..."
              limactl shell zfs-dev sudo sh -c "
                cd '$REPO_IN_VM'
                cat > '$REAL_TESTDIR/test-zfsresume.conf' << CONF
LOCAL_BORG_USER=\"root\"
FS=\"testpool/bigdata,\"
COMPRESS=\"zstd,9\"
CACHEMODE=\"mtime,size\"
PASS=\"$REAL_TESTDIR/test.key\"
BASEDIR=\"\"
LOCAL_READABLE_BY_OTHERS=false
REPOLIST=\"zfssend:testpool/zfsresumetarget, \"
REPOSKIP=\"NONE\"
RETENTIONPERIOD=\"monthly,1;weekly,4;daily,7\"
PRE_SCRIPT=
POST_SCRIPT=
CONF
                sh borgsnap_ng.sh run '$REAL_TESTDIR/test-zfsresume.conf'
              "
              set +e
              REAL_RESUME_RC=$?
              set -e
              if [ "$REAL_RESUME_RC" -eq 0 ]; then
                set +e
                limactl shell zfs-dev sudo sh -c "
                  echo '--- resume token after our own resume (should be cleared) ---'
                  zfs get -H -o value receive_resume_token testpool/zfsresumetarget/testpool/bigdata
                  echo '--- checksum comparison ---'
                  SRC_SUM=\$(sha256sum /testpool/bigdata/bigfile | awk '{print \$1}')
                  TGT_MOUNTPOINT=\$(zfs get -H -o value mountpoint testpool/zfsresumetarget/testpool/bigdata)
                  TGT_SUM=\$(sha256sum \"\$TGT_MOUNTPOINT/bigfile\" | awk '{print \$1}')
                  echo \"source: \$SRC_SUM\"
                  echo \"target: \$TGT_SUM\"
                  if [ \"\$SRC_SUM\" != \"\$TGT_SUM\" ]; then
                    echo 'CHECKSUM MISMATCH' >&2
                    exit 1
                  fi
                  echo 'CHECKSUM MATCH'
                "
                REAL_RESUME_VERIFY_RC=$?
                set -e
                if [ "$REAL_RESUME_VERIFY_RC" -eq 0 ]; then
                  REAL_RESUME_RESULT="PASS"
                else
                  REAL_RESUME_RESULT="FAIL (resume run succeeded, checksum/token verification failed)"
                fi
              else
                REAL_RESUME_RESULT="FAIL (resume run exit $REAL_RESUME_RC)"
              fi
            else
              REAL_RESUME_RESULT="FAIL (could not set up interrupted transfer)"
            fi
            if [ "$KEEP" -eq 0 ]; then
              limactl shell zfs-dev sudo sh -c "
                zfs destroy -r testpool/zfsresumetarget 2>/dev/null || true
                zfs destroy -r testpool/bigdata 2>/dev/null || true
                zfs destroy 'testpool/bigdata#zfssend-testpool_zfsresumetarget' 2>/dev/null || true
              "
            fi
          fi

          # FIX #46: real pool-lifecycle test. Uses a loop-device-backed
          # pool rather than a plain backing file - loop devices under
          # /dev are part of zpool's normal import search path, matching
          # how a real USB drive (/dev/sdX) would be found by a bare
          # `zpool import poolname` with no -d flag (which is what the
          # code actually calls).
          if [ "$REAL_RESUME_RESULT" = "PASS" ]; then
            echo ""
            echo "==> Testing real pool lifecycle for removable targets (FIX #46)..."
            set +e
            limactl shell zfs-dev sudo sh -c "
              set -e
              echo 'STEP: cleaning up any stale state from a previous attempt'
              zpool export usbpool 2>/dev/null || true
              LOOPDEV_OLD=\$(losetup -j /root/usbpool.img 2>/dev/null | cut -d: -f1)
              [ -n \"\$LOOPDEV_OLD\" ] && losetup -d \"\$LOOPDEV_OLD\" 2>/dev/null || true
              rm -f /root/usbpool.img

              echo 'STEP: creating a loop-device-backed pool (simulates a USB drive)'
              truncate -s 150M /root/usbpool.img
              LOOPDEV=\$(losetup -f)
              losetup \"\$LOOPDEV\" /root/usbpool.img
              zpool create usbpool \"\$LOOPDEV\"
              echo 'STEP: exporting it (simulates the drive not being attached yet)'
              zpool export usbpool
            "
            REAL_POOL_SETUP_RC=$?
            set -e
            if [ "$REAL_POOL_SETUP_RC" -eq 0 ]; then
              echo ""
              echo "==> Running borgsnap_ng.sh - it should import the pool, back up, then export it again..."
              limactl shell zfs-dev sudo sh -c "
                cd '$REPO_IN_VM'
                cat > '$REAL_TESTDIR/test-zfspool.conf' << CONF
LOCAL_BORG_USER=\"root\"
FS=\"testpool/data,\"
COMPRESS=\"zstd,9\"
CACHEMODE=\"mtime,size\"
PASS=\"$REAL_TESTDIR/test.key\"
BASEDIR=\"\"
LOCAL_READABLE_BY_OTHERS=false
REPOLIST=\"zfssend:usbpool/backups, \"
REPOSKIP=\"NONE\"
RETENTIONPERIOD=\"monthly,1;weekly,4;daily,7\"
PRE_SCRIPT=
POST_SCRIPT=
CONF
                sh borgsnap_ng.sh run '$REAL_TESTDIR/test-zfspool.conf'
              "
              set +e
              REAL_POOL_RC=$?
              set -e
              if [ "$REAL_POOL_RC" -eq 0 ]; then
                set +e
                limactl shell zfs-dev sudo sh -c "
                  echo '--- is usbpool imported right now? (should be NO - we imported it ourselves, so we exported it again afterward) ---'
                  if zpool list usbpool >/dev/null 2>&1; then
                    echo 'ERROR: usbpool is still imported - it should have been exported after the backup' >&2
                    exit 1
                  fi
                  echo 'usbpool correctly not imported (safe to detach)'
                  echo 'STEP: re-importing briefly to verify the backup actually landed'
                  zpool import usbpool
                  zfs list -r usbpool/backups 2>&1
                  zpool export usbpool
                "
                REAL_POOL_VERIFY_RC=$?
                set -e
              else
                REAL_POOL_VERIFY_RC=1
              fi

              if [ "$REAL_POOL_RC" -eq 0 ] && [ "$REAL_POOL_VERIFY_RC" -eq 0 ]; then
                echo ""
                echo "==> Testing the drive-not-attached case (loop device fully detached)..."
                set +e
                limactl shell zfs-dev sudo sh -c "
                  LOOPDEV=\$(losetup -j /root/usbpool.img 2>/dev/null | cut -d: -f1)
                  [ -n \"\$LOOPDEV\" ] && losetup -d \"\$LOOPDEV\"
                  echo 'loop device detached - usbpool is now genuinely unreachable, like an unplugged USB drive'
                "
                set -e
                limactl shell zfs-dev sudo sh -c "
                  cd '$REPO_IN_VM'
                  sh borgsnap_ng.sh run '$REAL_TESTDIR/test-zfspool.conf'
                "
                set +e
                REAL_POOL_NOTATTACHED_RC=$?
                set -e
                if [ "$REAL_POOL_NOTATTACHED_RC" -eq 0 ]; then
                  REAL_POOL_RESULT="PASS"
                else
                  REAL_POOL_RESULT="FAIL (run should still succeed when the pool truly can't be found, got exit $REAL_POOL_NOTATTACHED_RC)"
                fi
              else
                REAL_POOL_RESULT="FAIL (import/backup/export cycle did not complete correctly)"
              fi
            else
              REAL_POOL_RESULT="FAIL (could not set up the loop-device-backed pool)"
            fi
            if [ "$KEEP" -eq 0 ]; then
              limactl shell zfs-dev sudo sh -c "
                zfs destroy 'testpool/data#zfssend-usbpool_backups' 2>/dev/null || true
                LOOPDEV=\$(losetup -j /root/usbpool.img 2>/dev/null | cut -d: -f1)
                [ -n \"\$LOOPDEV\" ] && losetup -d \"\$LOOPDEV\" 2>/dev/null || true
                rm -f /root/usbpool.img
              "
            fi
          fi
        fi
      else
        REAL_RESULT="FAIL (exit $REAL_RC)"
      fi

      if [ "$KEEP" -eq 0 ]; then
        echo "==> Cleaning up scratch dir and test dataset in zfs-dev"
        limactl shell zfs-dev sudo sh -c "
          rm -rf '$REAL_TESTDIR'
          zfs destroy -r testpool/data/sub 2>/dev/null || true
          zfs list -t snapshot -H -o name | grep '^testpool/' | xargs -r -n1 zfs destroy 2>/dev/null || true
        "
      else
        echo "==> --keep given: leaving $REAL_TESTDIR and testpool/data/sub in place for inspection"
      fi
    fi
  fi
  echo ""
fi

# =========================================================================
# Summary
# =========================================================================
echo "=================================================================="
echo "Summary"
echo "=================================================================="
printf '%-45s %s\n' "1. Mock harness (docker-dev)"  "$MOCK_RESULT"
printf '%-45s %s\n' "2. Real ZFS run (zfs-dev)"      "$REAL_RESULT"
printf '%-45s %s\n' "3. Real zfssend backend (zfs-dev)" "$REAL_ZFSSEND_RESULT"
printf '%-45s %s\n' "4. Real resumable receive (zfs-dev)" "$REAL_RESUME_RESULT"
printf '%-45s %s\n' "5. Real pool lifecycle (zfs-dev)" "$REAL_POOL_RESULT"
printf '%-45s %s\n' "6. Real absolute-path invocation (zfs-dev)" "$REAL_FIX49_RESULT"

case "$MOCK_RESULT$REAL_RESULT$REAL_ZFSSEND_RESULT$REAL_RESUME_RESULT$REAL_POOL_RESULT$REAL_FIX49_RESULT" in
  *FAIL*) exit 1 ;;
  *) exit 0 ;;
esac
