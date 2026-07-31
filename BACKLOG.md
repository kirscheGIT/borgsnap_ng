# Known limitations / possible future improvements

Things that are understood, discussed, and deliberately deferred - not
bugs waiting to be noticed, but trade-offs someone made a call on. Each
entry says what the problem is, why it's not (yet) fixed, and what a fix
would look like if it becomes worth doing.

## zfssend bookmark self-reference after a same-day retry

**What happens:** If a run's `zfssend` step succeeds, but something later
in that same run causes a hard failure requiring a full rerun (same day,
same interval), `snapshotZFS` correctly reuses the existing source
snapshot rather than taking a new one (this is deliberate, existing
retry-safety behavior - see the "ZFS Snapshot ... exists! Assuming last
Borg run didn't finish" warning). But the `zfssend` bookmark from the
*earlier, successful* attempt already points at that same, reused
snapshot. The retry's own `zfssend` then tries an incremental send
"from this snapshot to this same snapshot", which ZFS correctly rejects:

```
warning: cannot send 'dataset@label': not an earlier snapshot from the same fs
cannot receive: failed to read from stream
```

Since FIX #59, this is caught and logged as an `ERROR`, not a hard abort
- the run continues with the remaining repos. So this is not silent, and
it does not corrupt anything.

**Why this isn't a snapshot-accumulation problem:** reusing an existing
snapshot never creates a second ZFS object under the same name - source-
side retention (`pruneZFSSnapshot`) counts and prunes normally regardless
of how many times a given day's label was retried.

**What it actually costs:** that one day's data change never reaches the
`zfssend` target at all - every retry for that day fails the same way,
until the next day's genuinely new label allows a normal incremental
send again (bookmark points at day N, sending day N+1 - a real
"later" snapshot). A single day's zfssend backup is silently skipped,
recovered automatically the next day, not accumulated as an unresolved
error.

**Possible fix, not yet built:** detect "the bookmark already points at
exactly the snapshot I'm about to send" as its own, distinguishable case
- e.g. treat it as "already done, nothing to do" (matching the FIX
#63/#64 philosophy for the equivalent Borg-side case: "nothing new was
written this run, don't report a false failure") rather than attempting
the incremental send and letting ZFS reject it.

**Why deferred:** this only manifests when a run is retried multiple
times on the same day for the same interval - normal, once-daily
production operation via the timer never hits it. Revisit if it turns
out to matter more in practice than expected.

## LOCAL_READABLE_BY_OTHERS is logged, not enforced

**What happens:** the config option exists, gets read and logged, but
nothing actually changes local repo directory permissions based on it
(see `TODO #28` in `sample.conf`).

**Why deferred:** deliberate - enforcing this correctly (recursively,
without loosening anything the user didn't ask for, without racing
against borg's own file creation) needs more care than a quick `chmod`.
Revisit when there's a concrete need.

## PRE_SCRIPT / POST_SCRIPT are validated, not executed

**What happens:** both config options are checked at load time (must
exist, must be executable) but are never actually invoked anywhere in
the backup flow.

**Why deferred:** the design questions haven't been settled yet - should
PRE_SCRIPT run once globally or per dataset, right before that dataset's
own snapshot (the "as early as possible" design discussed but not
finalized)? What should happen if a hook itself fails - abort the whole
run, skip just that dataset, or just warn and continue? Revisit once
there's a concrete use case (e.g. flushing an application before the
snapshot) driving the actual requirements.

## A single-interval RETENTIONPERIOD can produce a malformed label

**What happens:** if RETENTIONPERIOD configures only ONE interval (e.g.
`RETENTIONPERIOD="monthly,1"` alone, with no "daily" or other always-
qualifying fallback), and that interval doesn't qualify for a fresh
snapshot today (not the 1st of the month, an existing snapshot for this
month is already found), the interval-selection loop's `continue`
statement has nothing left to try - it exits the loop with the snapshot
label still at its initial, bare value ("monthly", with no date
appended), rather than reusing the existing snapshot's actual name or
producing some other well-defined result.

**Why this normally doesn't matter:** every realistic RETENTIONPERIOD
includes "daily" (or some other interval whose bare name isn't
"monthly"/"weekly", so it always takes the generic, always-qualifying
branch) as the last-resort entry, so the loop always terminates with a
freshly, correctly labeled snapshot in practice. This was only found
while testing the SNAPSHOT_TAG feature with a deliberately minimal,
single-interval test config - not from any real-world report.

**Why deferred:** genuinely low real-world likelihood, and the right
fix (well-defined behavior for "no interval qualified this run" - skip
the dataset entirely with a clear message? fall back to some default
interval?) needs its own design discussion, not a quick patch.

## zfssend only supports local targets

**What happens:** `zfssend:` REPOLIST entries only work for a local ZFS
pool/dataset target - there's no support for sending to a remote pool
over SSH (`zfs send | ssh host zfs receive`, or similar).

**Why deferred:** the initial implementation focused on the local-target
case (e.g. a USB-attached receive pool). A remote target adds real
complexity - SSH connectivity/reachability checks matching the borg-side
ones, remote-side `zpool`/`zfs` command availability and permissions,
and bookmark/resume handling across a network link that can drop
mid-transfer. Revisit if a concrete need for remote zfssend targets
comes up.

## No raw send (zfs send -w) for encrypted source datasets

**What happens:** `zfssend` always does a normal (decrypting) send. If
the SOURCE dataset itself is ZFS-native-encrypted, there's currently no
option to send it raw (`zfs send -w`, keeping the data encrypted in
transit and at the target, without needing the receiving side to have
the encryption key at all).

**Why deferred:** most setups back up unencrypted source datasets (borg
itself provides encryption for the borg-side repos), so this hasn't been
a blocker in practice. Revisit if someone's actual source datasets are
ZFS-encrypted and they want that property preserved through zfssend
specifically, rather than relying on borg's own encryption for the
borg-side destinations.

## No formal OS/filesystem/Borg-version test matrix

**What happens:** the tool has been tested extensively in practice on
one specific combination (Debian, ZFS, current borg via the mock test
suite plus real-world sandbox runs), but there's no formal matrix
covering other Linux distributions, ZFS versions, or older/newer borg
releases.

**Why deferred:** low practical urgency without a concrete report of a
problem on a different combination - the mock test suite (230+
assertions) covers the tool's own logic thoroughly regardless of the
underlying OS, and the real commands it shells out to (`zfs`, `borg`,
`ssh`) are the actual compatibility surface. Revisit if a specific
combination turns out to behave differently.

## Local variable names in cfg_file_hdlr.sh aren't fully unique-prefixed

**What happens:** unlike most of the other script files (which
consistently prefix every local variable with the owning function's
name, e.g. `strtBckpMchn_*`, `ensureBorgInit_*`), `cfg_file_hdlr.sh`'s
own local variables are less consistently named, a holdover from before
that convention was established project-wide.

**Why deferred:** purely cosmetic/consistency - doesn't cause any actual
bug (the unset-checker and `set -u` both pass cleanly), just makes this
one file a little more error-prone to extend than the others. Worth
doing as a dedicated pass rather than incidentally while touching
unrelated logic in this file.

## BASEDIR logic needs a rework

**What happens:** `BASEDIR` (sets `BORG_BASE_DIR`, moving borg's
cache/config directory) is handled with a simple "if set and exists, use
it; if set and missing, die" check - functional, but never revisited
since it was first added.

**Why deferred:** works fine for its current, narrow use case (e.g.
unRAID setups where the home directory isn't persistent). No concrete
report of a problem with it - revisit if one comes up, or alongside any
broader config-handling cleanup.

## A few nested if-statements in pruneBorg could be simplified

**What happens:** `pruneBorg`'s per-repo/per-interval branching has a
few nested `if` statements that could likely be flattened or
consolidated - noted while writing it, never revisited.

**Why deferred:** purely cosmetic/readability - the logic is correct and
covered by the mock test suite, just not as clean as it could be.

## REPOSKIP is a global variable, not scoped per-repo

**What happens:** `REPOSKIP` ("LOCAL"/"REMOTE"/"NONE") applies uniformly
to every repo in `REPOLIST` for a given config - there's no way to skip
just one specific repo while still processing the others of the same
type (local vs. remote).

**Why deferred:** the common case (skip all local, or all remote, e.g.
while a drive is being replaced) is already covered. Per-repo skipping
would need its own syntax extension to `REPOLIST` - revisit if a
concrete case needs finer granularity than "all local" / "all remote".

## Recursive snapshot mounting hasn't been specifically test-verified

**What happens:** `RECURSIVE=true` mounts each child filesystem's
snapshot underneath the parent's snapshot mount point - the mock test
suite covers the ZFS snapshot/prune side of recursion, but the actual
recursive *mount* behavior (verifying every child ends up correctly
nested and later unmounted) hasn't had a dedicated, explicit test pass.

**Why deferred:** no concrete report of a problem with it in practice -
revisit with a dedicated real-world (non-mocked) test pass, since mount
nesting is exactly the kind of thing a shell-command mock can't fully
stand in for.

**Related, unnumbered idea:** it might be worth supporting a "don't
mount this child" list for a recursively-snapshotted dataset - useful if
you want the retention/consistency benefits of a recursive ZFS snapshot
without every child's data actually being included in the borg archive.
Not designed or committed to yet.

## Parameter sanity checking across functions is uneven

**What happens:** most functions validate their own inputs somewhat -
`set -u` catches genuinely unset variables, and several config-facing
values (`PASS`, `BASEDIR`, `FS`, `LOCAL_BORG_USER`, etc.) have explicit
checks - but there's no single, consistent standard for how thoroughly
every function validates every parameter it receives.

**Why deferred:** this was flagged early on as an ongoing concern rather
than a specific, fixable gap - genuinely inconsistent validation depth
is normal across a codebase that grew incrementally, and tightening it
further is best done incrementally too (e.g. as part of whatever FIX
touches a given function next) rather than as one large, high-risk pass
across everything at once.
