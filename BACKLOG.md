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
