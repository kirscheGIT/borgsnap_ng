# borgsnap_ng Mock Test Harness

A self-contained, dependency-free test harness for `borgsnap_ng`. It replaces
the system binaries `zfs`, `borg`, `mount`, `umount`, and `sudo` with POSIX
shell mocks so the full backup lifecycle (`borgsnap_ng.sh run`) can be
exercised and verified **without a real ZFS pool, without borg installed, and
without root side effects**.

## Contents

```
test/
├── mocks/
│   ├── zfs        # stateful mock: snapshot/destroy/list against a state file
│   ├── borg       # logger stub, always exits 0
│   ├── mount      # logger stub, always exits 0
│   ├── umount     # logger stub, always exits 0
│   └── sudo       # pass-through: exec "$@" (so `sudo mount` hits the mock)
└── run_mock_test.sh   # test runner with assertions for fixes #1-#11, #27
```

## Requirements

There is **nothing to build**. The mocks are plain POSIX `sh` scripts. The
only requirements are:

- any POSIX shell (`dash`, `ash`, `busybox sh`, `bash` — all fine)
- standard userland: `grep`, `sed`, `cut`, `tail`, `wc`, `mktemp`, `ln`
- the scripts must be executable: `chmod +x test/mocks/* test/run_mock_test.sh`

Note: Git preserves the executable bit, but after unpacking a zip archive,
re-run `chmod +x` before committing.

## How it works

The mocks communicate through two environment variables, both set by the test
runner (with `/tmp` fallbacks for standalone use):

| Variable     | Purpose                                                        |
|--------------|----------------------------------------------------------------|
| `MOCK_LOG`   | Append-only log of every invocation (`zfs snapshot -r ...`, `borg prune ...`). Test assertions `grep` against this file. |
| `MOCK_STATE` | Simulated pool state: one line per existing snapshot (`tank/data@daily-20260718`). |

### The `zfs` mock

The only mock with real logic. Supported subcommands:

- `snapshot [-r] <ds@label>` — fails like real zfs if the snapshot already
  exists; with `-r` it additionally creates a simulated child dataset
  `<ds>/child@label` so the recursive code path is testable.
- `destroy [-r] <ds@label>` — removes the line from the state file.
- `list [-H|-Hr] [-t snap|snapshot] [-o name] [-d N] [dataset]` — prints the
  state, filtered by dataset (including children); without `-H` it prints a
  `NAME` header line, mimicking real zfs.
- `bookmark`, `hold`, `release` — accepted as no-ops (stubs for the future
  `zfs send` backend).

### The `borg`, `mount`, `umount` mocks

Pure loggers: they append their full command line to `MOCK_LOG` and exit 0.
Assertions verify command *construction* (e.g. that `borg prune` carries
`--glob-archives 'daily-*'`), not borg's behavior itself.

### The `sudo` mock

`exec "$@"` — simply runs the given command, so `sudo mount ...` inside
`zfs_snap_mount.sh` resolves to the mocked `mount`.

## Running the tests

```sh
sh test/run_mock_test.sh
```

The runner:

1. creates a temp workdir with `mktemp -d` (config, key file, repos, logs),
2. symlinks the mocks into `/usr/local/bin` (because `borgsnap_ng.sh`
   hard-exports its own `PATH`, prepending won't work — see caveat below),
3. pre-seeds `MOCK_STATE` with 9 old daily snapshots plus current monthly and
   weekly snapshots, so "today" resolves to a daily run and the prune logic
   has snapshots to delete,
4. executes `borgsnap_ng.sh run` against a generated config with two datasets
   (one recursive, one not) and two local repos,
5. asserts against `MOCK_LOG` and the runtime log, then re-runs to verify
   lock/stale-lock behavior.

Expected output ends with:

```
Result: 13 passed, 0 failed
```

### What the assertions cover

| Assertion            | Verifies fix                                            |
|----------------------|---------------------------------------------------------|
| glob-restricted prune| #1: `borg prune` cannot delete other intervals' archives |
| recursive snapshot   | #2: per-dataset recursive flag parsing                   |
| destroy issued/oldest-first | #3/#27: ZFS snapshot prune works, newline-IFS iteration |
| no duplicate keep flags | #4: prune options no longer accumulate across datasets |
| depth-2 + child umount | #5: mount manifest teardown                            |
| no waiting messages  | #7: pgrep wait loops removed                             |
| lock released / stale lock removed | #9: single-instance locking            |

## Caveat: symlinks into /usr/local/bin

Because `borgsnap_ng.sh` exports a hardcoded `PATH`, the runner currently
installs the mocks by symlinking them into `/usr/local/bin` (first entry of
that hardcoded `PATH`). **Run this in a container, VM, or throwaway
environment**, or remove the symlinks afterwards:

```sh
for b in zfs borg mount umount sudo; do rm -f /usr/local/bin/$b; done
```

The cleaner long-term fix is a `BORGSNAP_PATH_OVERRIDE` environment variable
honored by `borgsnap_ng.sh`, so tests can prepend `test/mocks` to `PATH`
without touching the system. This is on the Phase 2 roadmap.

## Extending the mocks

Ideas for upcoming work:

- **`zfs send` backend (Phase 5):** add `send` (emit a marker/stream to
  stdout), `receive` (consume stdin, record the snapshot in a second state
  file such as `MOCK_STATE_TARGET`), and `get`/`set` (key-value property file)
  to the `zfs` mock. `bookmark`/`hold`/`release` stubs are already in place.
- **Fault injection:** introduce e.g. `MOCK_FAIL_ON="destroy"` to make a
  specific subcommand exit non-zero. This finally makes the `err_hdlr` path
  testable — currently the least-tested part of the project.
- **Borg realism:** let the `borg` mock maintain its own archive state file so
  prune/create interactions can be asserted, not just command construction.

## Housekeeping

Add to `.gitignore`:

```
test/logs/
*.state
*.log
```
