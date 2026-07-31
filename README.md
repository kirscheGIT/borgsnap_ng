# borgsnap_ng

A POSIX-shell fork of [borgsnap](https://github.com/jortan/borgsnap) for
automated ZFS + [Borg](https://www.borgbackup.org/) backups: ZFS snapshots
feed local borg repositories, remote borg repositories (including
[BorgBase](https://www.borgbase.com/)), and/or plain `zfs send` targets,
all driven by one interval-based retention scheme, with restore-path
verification built in rather than assumed.

## Key features over the original borgsnap

* **Multiple destination types per dataset** - local borg, remote borg
  over SSH, BorgBase, and/or `zfssend` (plain ZFS send/receive), all in
  one `REPOLIST`, each with independent success/failure handling.
* **`BORG_VERIFY`** - periodic `borg check` at a configurable depth
  (`repo`/`archive`/`data`) per retention interval, so a corrupted
  archive is caught proactively instead of during an actual restore.
* **`RESTORE_VERIFY`** - writes a canary file before each snapshot and
  confirms it survives a real extract from the freshly created archive,
  so "the backup completed" and "the backup is actually restorable" are
  no longer assumed to be the same thing.
* **`SNAPSHOT_TAG`** - an optional prefix on every ZFS snapshot label,
  so borgsnap_ng can run on the same dataset as another backup tool
  (including the original borgsnap) without a snapshot-name collision.
* **Resilience by design** - one repo failing (network hiccup, wrong
  passphrase, not yet initialized) is logged clearly and skipped; it
  does not abort backups to every other configured repo, and does not
  prevent source-side ZFS retention from running.
* **`MSG_LEVEL`** - configurable log verbosity (errors only, up through
  full debug), instead of an all-or-nothing firehose.
* **Capacity reporting** - logs remaining free space on local repo
  filesystems and zfssend target pools after each run.
* **systemd integration** - per-dataset timer/service units and a mail
  wrapper that reports SUCCESS / SUCCESS (with warnings) / PARTIAL
  FAILURE / FAILURE, instead of relying on cron's mail-on-any-output.
* **Interactive setup** - `install.sh` + `setup-backup.sh` walk through
  installing the tool and configuring each backup job, instead of
  hand-editing a config file from scratch.

**The configuration file must include every option `sample.conf`
documents**, even ones left empty - `sample.conf` is the authoritative,
inline-documented reference for every option; this README only
summarizes the ones most relevant to getting started.

*If `RECURSIVE=true` (the second field of `FS=`), borgsnap_ng creates
recursive ZFS snapshots for that filesystem. Each child filesystem's
snapshot is mounted underneath the parent's snapshot mount, so borg
backs up the parent and all children in a single archive. Note: ZFS
snapshot deletion/retention only ever matches the exact configured
dataset, never its children, even when that dataset was snapshotted
recursively - see the warning next to `FS=` in `sample.conf` for a
gotcha this creates if you also back up one of those children
separately, as its own config entry.*

This assumes borg 1.4 or later (for `BORG_EXIT_CODES=modern` support,
which several resilience features rely on to distinguish "not yet
initialized" from "genuinely broken" without guessing).

Finally, these things are probably obvious, but: make sure your local
backups are on a different physical drive than the data you're backing
up, and don't skip remote/offsite backups - a local-only backup isn't
disaster-proofing your data.

## Installation

### Quick install (recommended)

```
git clone <this repo>
cd borgsnap_ng
sudo ./install.sh
sudo ./setup-backup.sh
```

`install.sh` copies borgsnap_ng to `/usr/local/bin/borgsnap_ng` (override
with `--install-dir=PATH`), and on request creates the dedicated `borg`
system user with its least-privilege sudo/tmpfiles setup, plus the
systemd unit templates. Run `./install.sh --help` for all options, or
`--dry-run` to preview without changing anything. Safe to re-run on an
existing install (e.g. for a version update) - it only touches the
application files themselves, never any `.conf`/`.key` files already
sitting in the same directory.

`setup-backup.sh` then walks through configuring one actual backup job:
the user (if you skipped that in install.sh), the destination(s) - local
borg, remote borg (including SSH key setup if needed), zfssend, or a mix
- the source ZFS dataset, retention, verification, encryption
passphrase, ZFS delegation for that dataset, and finally registers and
enables a systemd timer for it. Run it again for each additional backup
job/dataset you want. It's fully interactive by design - `--dry-run`
previews without changing anything, but there's no non-interactive mode,
since the whole point is walking through the interdependent choices
rather than skipping straight to flags.

## Usage

```
usage: borgsnap_ng.sh <command> <config_file> [<args>]

commands:
    run             Run backup lifecycle.
                    usage: borgsnap_ng.sh run <config_file>

    snap            Run backup for a specific snapshot.
                    usage: borgsnap_ng.sh snap <config_file> <snapshot-name>

    tidy            Unmount and remove today's snapshots/local backups.
                    usage: borgsnap_ng.sh tidy <config_file>

                    Added for test/dev purposes, may not work as intended!
                    Note: this unmounts every snapshot mounted by
                    borgsnap_ng, including other running instances.
```

If you used `setup-backup.sh`, a systemd timer already calls `run` for
you on schedule - `mail_wrapper.sh` (see `ops/systemd/`) wraps that call
to send a status email. Manual/ad-hoc runs use `borgsnap_ng.sh` directly.

## How it works

For each configured filesystem, per run:

1. Read the config file and encryption key file; validate the basics
   (output directory exists, the executing user matches
   `LOCAL_BORG_USER`, etc.).
2. Work out which retention interval (monthly/weekly/daily) qualifies
   today, and take a ZFS snapshot for it (recursively, if configured) -
   reusing an existing snapshot for today's label instead of failing if
   one's already there.
3. For each configured repo/target in `REPOLIST`:
   * Local or remote borg: initialize the repo if needed, `borg create`,
     `borg prune`, and (if `BORG_VERIFY` says so) `borg check` at the
     configured depth.
   * BorgBase: same, but repo existence/init state is detected via
     `borg list`'s own exit code, since BorgBase's restricted SSH access
     doesn't allow arbitrary shell commands.
   * zfssend: incremental `zfs send`/`zfs receive` to a local or bookmark-
     tracked target dataset instead of a borg archive.
   * If `RESTORE_VERIFY` is enabled for today's interval, extract the
     freshly created archive (or check the zfssend target) and confirm
     the canary file written before the snapshot survived intact.
   * One repo's failure (unreachable, wrong passphrase, transient error)
     is logged clearly and that repo is skipped - it does not abort the
     other configured repos.
4. Unmount the snapshot, then prune old ZFS snapshots for this dataset's
   interval according to `RETENTIONPERIOD` - independent of any single
   repo's prune outcome above.

That's it, once per configured filesystem.

If a run is interrupted or fails partway through, it's re-entrant: a
snapshot that already exists for today's label is reused, not treated as
a fatal error (though see `BACKLOG.md` for one known edge case around
`zfssend` bookmarks on a same-day retry). The `tidy` command exists as a
best-effort manual cleanup for test/dev use, unmounting and removing
today's snapshots/archives so a run can be repeated - it predates the
re-entrancy above and isn't normally needed anymore.

## Restoring files

borgsnap_ng doesn't help with restoring files, it just backs them up.
Restoration is done directly with borg (or straight from the ZFS
snapshot, for a simple accidental deletion). A backup that can't be
restored from is useless - `RESTORE_VERIFY` catches the most common way
that happens automatically, but you should still test a real restore
periodically.

Depending on why you need to restore:

* **Local ZFS snapshot** (the dataset's `.zfs/snapshot/` directory) -
  the way to go for a simple accidental deletion with no hardware
  failure involved.
* **Local borg repository** - if there's data loss on the source
  filesystem but the local backup drive is still good, use
  `borg mount` to browse and copy files out.
* **Remote borg repository** (including BorgBase) - same idea as local,
  just a remote repo path.
* **zfssend target** - it's a normal ZFS dataset; browse it directly, or
  `zfs send`/`zfs receive` it back.

`borgwrapper` (in this repository) sets `BORG_PASSPHRASE` from a
borgsnap_ng config file's `PASS`, so you don't need to do that by hand
for ad-hoc borg commands:

```
$ sudo -u borg borgwrapper /path/to/myconfig.conf list /path/to/local/repo
monthly-20260701                     Wed, 2026-07-01 03:00:12
weekly-20260706                      Mon, 2026-07-06 03:00:08
daily-20260730                       Thu, 2026-07-30 03:00:05

$ sudo -u borg borgwrapper /path/to/myconfig.conf mount /path/to/local/repo::daily-20260730 /mnt

$ ls /mnt/.zfs/snapshot/daily-20260730/
(the dataset's contents as of that snapshot)

$ sudo -u borg borgwrapper /path/to/myconfig.conf umount /mnt
```

Note that borgsnap_ng backs up directly from the ZFS snapshot via its
`.zfs` mount point, so the archive preserves that directory structure -
borg still deduplicates normally even though the leading path changes
with each snapshot name.

Without `borgwrapper`, the same thing works with a plain `borg` command
and `BORG_PASSPHRASE` exported by hand:

```
$ export BORG_PASSPHRASE=$(cat /path/to/myconfig.key)
$ borg list /path/to/local/repo
```

For a remote repo, add `--remote-path=borg` (or whatever `REPOLIST`
configured for that entry) and use the `ssh://...` path instead. See the
borg manpages for other restoration approaches, such as `borg extract`.

## Known limitations

See [BACKLOG.md](BACKLOG.md) for understood, deliberately deferred edge
cases and possible future improvements.
