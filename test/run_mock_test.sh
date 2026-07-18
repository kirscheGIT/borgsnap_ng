#!/bin/sh
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
for b in zfs borg mount umount sudo; do
  ln -sf "$TESTROOT/mocks/$b" /usr/local/bin/$b
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
  "grep 'borg prune' '$MOCK_LOG' | grep -q 'glob-archives daily-'"
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
echo "Result: $PASS_CNT passed, $FAIL_CNT failed"
echo "Mock log: $MOCK_LOG"
[ "$FAIL_CNT" -eq 0 ]
