# Running borgsnap_ng as a non-root user

Three independent pieces, install in this order:

## 1. `/run/borgsnap` ownership (tmpfiles.d)

```sh
sudo cp borgsnap-ng.tmpfiles.conf /etc/tmpfiles.d/borgsnap-ng.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/borgsnap-ng.conf
ls -ld /run/borgsnap   # expect: drwxr-x--- ... borg borg
```

`/run` is a tmpfs - empty on every boot. This file makes sure
`/run/borgsnap` gets recreated with the right ownership automatically,
every time, without you having to remember to do it manually.

If you're testing this on a system where `/run/borgsnap` already exists
with the wrong owner (e.g. left over from an earlier root-run test),
remove it first - the directory won't get its ownership fixed in place:

```sh
sudo rm -rf /run/borgsnap
sudo systemd-tmpfiles --create /etc/tmpfiles.d/borgsnap-ng.conf
```

## 2. sudo rules (mount/umount, zpool import/export)

```sh
sudo visudo -c -f borgsnap-ng.sudoers   # validate before installing
sudo cp borgsnap-ng.sudoers /etc/sudoers.d/borgsnap-ng
sudo chmod 0440 /etc/sudoers.d/borgsnap-ng
```

These two operation classes can't be delegated via `zfs allow` on Linux at
all (see the comments in the file itself for why) - this is the only
piece that genuinely needs a sudo escalation, not ZFS-level delegation.

## 3. ZFS delegation (snapshot/send/receive/etc.)

```sh
# For every dataset you back up FROM:
sudo ./setup-zfs-allow.sh source borg tank/data

# Only if you use the zfssend backend - for every target prefix you send TO:
sudo ./setup-zfs-allow.sh target borg usbpool/backups
```

Requires OpenZFS >= 2.2 for the `receive:append` permission (rejects
destructive receives - our code never does one anyway, so this is a free
safety net granted *alongside* plain `receive`, not instead of it).
`mount` is also granted on both sides - not because it can functionally
mount anything on Linux (it can't), but because ZFS's own internal
dependency checks for `create`/`receive`/`destroy` require it to be
*present* in the delegation table, or those operations are rejected
outright with "permission denied". See the comments in
`setup-zfs-allow.sh` for the full reasoning and the real-world report that
uncovered this. Check `zfs version` if unsure about the OpenZFS version.

## Verifying it all worked

As the `borg` user (not root):

```sh
sudo -u borg mkdir -p /run/borgsnap/tank/data
sudo -u borg zfs snapshot tank/data@test-$(date +%s)
sudo -u borg zfs list -t snapshot tank/data
```

If all three succeed without "Permission denied", the setup is complete.
Clean up the test snapshot afterward:

```sh
sudo -u borg zfs destroy tank/data@test-<the timestamp you got above>
sudo rm -rf /run/borgsnap/tank
```
