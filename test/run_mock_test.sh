#!/bin/sh
# TESTKIT_VERSION=2026-07-19.5
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
  for b in zfs borg mount umount sudo date; do
    if [ -e "$BACKUP_DIR/$b" ] || [ -L "$BACKUP_DIR/$b" ]; then
      mv "$BACKUP_DIR/$b" "/usr/local/bin/$b"
    else
      rm -f "/usr/local/bin/$b"
    fi
  done
}
trap cleanup_mocks EXIT INT TERM HUP

for b in zfs borg mount umount sudo date; do
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
echo "Result: $PASS_CNT passed, $FAIL_CNT failed"
echo "Mock log: $MOCK_LOG"
[ "$FAIL_CNT" -eq 0 ]
