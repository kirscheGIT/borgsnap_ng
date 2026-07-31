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
