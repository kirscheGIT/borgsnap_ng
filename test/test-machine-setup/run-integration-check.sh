#!/bin/sh
# TESTKIT_VERSION=2026-07-19.5
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

# TESTKIT_VERSION=2026-07-19.5
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
TESTKIT_VERSION="2026-07-19.5"
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
preflight_check_version "$REPO_ROOT/test/mocks/borg" "test/mocks/borg"

for mockbin in date zfs borg; do
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
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #33"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #38"
preflight_check_marker "backup/bckp_hdlr.sh" "FIX #39"
preflight_check_marker "common/msg_and_err_hdlr.sh" "FIX #35"
preflight_check_marker "borg/borg_hdlr.sh" "FIX #36"
preflight_check_marker "filesystem/zfs_hdlr.sh" "FIX #37"

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
        "
        VERIFY_RC=$?
        set -e
        if [ "$VERIFY_RC" -eq 0 ]; then
          REAL_RESULT="PASS"
        else
          REAL_RESULT="FAIL (run succeeded, verification failed - see output above)"
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

case "$MOCK_RESULT$REAL_RESULT" in
  *FAIL*) exit 1 ;;
  *) exit 0 ;;
esac
