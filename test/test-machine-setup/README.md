# borgsnap_ng — Lima Dev/Test Environment

This directory sets up two disposable Linux VMs on macOS (Intel or Apple
Silicon) for developing and testing `borgsnap_ng` without touching the host
system:

| Instance     | Base          | Purpose                                                        |
|--------------|---------------|------------------------------------------------------------------|
| `docker-dev` | Debian 13 + Docker CE | Run the mock test harness (`test/run_mock_test.sh`) and any other container-based work, in an isolated, throwaway environment. |
| `zfs-dev`    | Debian 13 + zfsutils-linux | Real ZFS testing — actual snapshots, `zfs send`/`receive`, bookmarks, pool behavior — that the mock harness can't cover. Includes a pre-created 8G loopback test pool. |

Both VMs mount this repo checkout read-write at `/home/<you>/borgsnap_ng`,
so you edit files on macOS with your normal tools and run/test them inside
the VM.

## Why VMs at all?

`borgsnap_ng`'s test harness (`test/run_mock_test.sh`) is pure POSIX shell
and runs fine directly on macOS. But anything involving **real** `zfs`
commands needs an actual Linux kernel with the ZFS module loaded — macOS has
no reliable native ZFS support, and Docker Desktop/OrbStack containers on
macOS run inside a minimal Linux VM that doesn't ship the ZFS kernel module
either. A real Debian VM is the only reliable way to test the ZFS code paths
end-to-end on a Mac.

## Contents

```
test/test-machine-setup/
├── README.md                  (this file)
├── create-clean-instance.sh   wrapper script (see below — start here)
├── docker-debian.yaml         Lima template: docker-dev instance
└── zfs-debian.yaml            Lima template: zfs-dev instance
```

## Prerequisites

```sh
brew install lima yq
```

That's it — no Docker Desktop, no OrbStack, no VirtualBox. `lima` provides
the VM layer (`limactl`), `yq` is used once per instance by the wrapper
script to patch the resolved Lima config (see "The `~` mount problem"
below).

## Quick start

```sh
cd test/test-machine-setup
./create-clean-instance.sh docker-dev docker-debian.yaml
./create-clean-instance.sh zfs-dev zfs-debian.yaml
```

That's the whole setup. Read on for what each part does and why it's
necessary — useful if something doesn't work as expected, or if you want to
adapt this for another project.

## Why not just `limactl start docker-debian.yaml`?

Because of two Lima quirks that aren't obvious from the template files
alone. `create-clean-instance.sh` exists specifically to work around them.
Using `limactl start` directly will technically work, but will also mount
your **entire macOS home directory** into the VM and will fail to resolve
the repo path portably. Details:

### 1. The unavoidable `~` mount

Every Lima template, no matter which distro or how minimal, ultimately
chains back to Lima's own `templates/default.yaml`. That root template
unconditionally adds:

```yaml
mounts:
  - location: "~"
```

Lima **combines** mount lists across the whole template chain rather than
replacing them — so no matter what `mounts:` you declare in your own
template, this entry from the base chain gets merged in alongside yours.
Since it has no `mountPoint` override, Lima mirrors the *host's absolute
path* 1:1 into the guest — meaning your whole macOS home directory
(`/Users/<you>`) shows up inside the VM, verbatim, with none of your data
excluded.

This can't be suppressed declaratively from a template file — we tried
several approaches (different base templates, `_images/*` variants) and none
of them prevented it. The only reliable fix is to edit the config **after**
Lima has resolved it:

- `limactl create` resolves the full template chain once and writes the
  result to `~/.lima/<instance-name>/lima.yaml`.
- That resolved file is the sole source of truth from then on — subsequent
  `limactl stop`/`start` cycles do **not** re-merge the base templates.
- So: create the instance *without* starting it, delete the one unwanted
  `location: "~"` entry from the resolved YAML with `yq`, *then* start it.
  This is a one-time fix per instance.

`create-clean-instance.sh` automates exactly this sequence:

```sh
limactl create --tty=false --name="$NAME" "$RESOLVED_TEMPLATE"
yq -i 'del(.mounts[] | select(.location == "~"))' ~/.lima/$NAME/lima.yaml
limactl start "$NAME"
```

### 2. Portable repo path resolution

The Lima templates (`docker-debian.yaml`, `zfs-debian.yaml`) don't hardcode
a path to this repo — that would break the moment anyone clones the repo to
a different location. Instead, the `mounts:` section in both templates uses
a placeholder:

```yaml
mounts:
  - location: "__BORGSNAP_REPO_PATH__"
    mountPoint: "/home/{{.User}}/borgsnap_ng"
    writable: true
```

`create-clean-instance.sh` substitutes this placeholder into a throwaway
temp copy of the template before calling `limactl create` — **the template
file on disk is never modified**, so it stays portable and git-friendly. The
substitution value is resolved in this order (first match wins):

1. `--repo-path=PATH` or `-p PATH` command-line flag
2. `BORGSNAP_NG_REPO_PATH` environment variable
3. Auto-detected via `git rev-parse --show-toplevel`, run from the script's
   own directory — this is what makes the zero-argument case
   (`./create-clean-instance.sh docker-dev docker-debian.yaml`) work
   automatically as long as this script stays inside the repo checkout,
   regardless of where that checkout lives on disk.
4. Fallback: two directories above the script (works even without git, as
   long as the directory layout `<repo>/test/test-machine-setup/` is
   preserved).
5. If the resolved path doesn't contain a `borgsnap_ng.sh` marker file (i.e.
   it doesn't look like the actual repo), and options 3/4 were used, an
   interactive prompt asks for confirmation/correction. Explicit overrides
   (options 1/2) are trusted as given, without this sanity check — the whole
   point of an explicit override is to support non-standard layouts.
   Non-interactive sessions (e.g. CI) abort with an error instead of
   guessing.

The script also symlinks the template it used into `~/lima/` (creating that
directory if needed), purely for convenience — so you have a stable,
predictable location to find the templates from, independent of where the
repo checkout lives.

## Working with `docker-dev`

```sh
limactl shell docker-dev
docker run --rm hello-world
```

To use the Docker CLI directly from macOS instead of `limactl shell`, you
need the CLI installed on the host (the daemon runs inside the VM, this only
gets you the client binary):

```sh
brew install docker   # CLI only, no daemon, no Docker Desktop
export DOCKER_HOST="unix://$(limactl list docker-dev --format '{{.Dir}}')/sock/docker.sock"
docker run --rm hello-world
```

Running the mock test harness inside a container:

```sh
limactl shell docker-dev -- \
  docker run --rm -v /home/$(whoami)/borgsnap_ng:/repo -w /repo debian:trixie-slim \
  sh -c "sh test/run_mock_test.sh"
```

## Working with `zfs-dev`

A test pool is created automatically during provisioning: an 8G loopback
file at `/var/lib/zfs-testdisk/disk0.img`, imported as `testpool` with two
datasets, `testpool/data` and `testpool/home`. `zfs-dkms`/`zfsutils-linux`
live in Debian's `contrib` component (not `main`, for CDDL/GPL licensing
reasons) — the provisioning script enables `contrib` and builds the DKMS
module against the running kernel, which takes a minute or two on first
boot.

```sh
limactl shell zfs-dev
sudo zfs snapshot testpool/data@daily-$(date +%Y%m%d)
sudo zfs list -t snapshot
cd ~/borgsnap_ng
sudo sh borgsnap_ng.sh run /path/to/your/test.conf
```

Reset the test pool from scratch:

```sh
limactl shell zfs-dev sudo zpool destroy testpool
limactl shell zfs-dev sudo rm /var/lib/zfs-testdisk/disk0.img
limactl stop zfs-dev
limactl delete zfs-dev
./create-clean-instance.sh zfs-dev zfs-debian.yaml   # re-provisions from scratch
```

## Common commands

```sh
limactl list                      # show all instances and their status
limactl stop <name>                # stop (state preserved)
limactl start <name>                # resume a stopped instance (no re-provisioning)
limactl delete <name>                # remove entirely
limactl shell <name>                  # open a shell inside the VM
limactl shell <name> <command>          # run a single command inside the VM
limactl edit <name>                       # edit the resolved config, restarts automatically on save
```

Note: `limactl start <name>` (no template argument) on an *existing*
instance just resumes it with its already-resolved config — it does **not**
re-read the `.yaml` template file. To pick up template changes (e.g. an
edited provisioning script), you need to `stop` + `delete` + recreate via
`create-clean-instance.sh`.

## Troubleshooting

**`docker run --rm hello-world` inside `docker-dev` says permission denied /
requires `sudo`, and setting `DOCKER_HOST` on the host still fails with
`error during connect: ... EOF`.**
Provisioning adds the guest user to the `docker` group
(`usermod -aG docker`), but group membership only takes effect for
processes started *after* the change. `limactl shell` uses a multiplexed
(ControlMaster) SSH connection that gets established early during boot —
before provisioning finishes — so a session opened right after instance
creation can be stuck with the pre-`docker`-group membership indefinitely,
even across multiple `limactl shell` invocations, because they reuse the
same multiplexed connection. The Lima guest agent that forwards the Docker
socket to the host (`DOCKER_HOST`) can be affected the same way, which is
why both symptoms tend to show up together.

Diagnose first, don't just restart blindly:

```sh
limactl shell docker-dev getent group docker
```

If this shows `docker:x:<gid>:<you>`, provisioning succeeded and it's just
the stale session — restart the whole instance (not just the shell) so a
fresh ControlMaster connection and guest agent get established against the
already-provisioned state:

```sh
limactl stop docker-dev
limactl start docker-dev
limactl shell docker-dev id                      # "docker" should now be listed
limactl shell docker-dev docker run --rm hello-world
```

If `getent group docker` shows nothing, provisioning itself failed —
check `limactl shell docker-dev sudo journalctl -u docker --no-pager | tail -50`
and consider recreating the instance.

This restart is normally only needed once, right after the instance is
first created — `zfs-dev` doesn't need it at all, since its provisioning
never changes group membership (all `zfs`/`zpool` commands there use `sudo`
directly instead of relying on group membership).

**`sudo docker run --rm hello-world` fails with
`dial unix /var/run/docker.sock: connect: no such file or directory`, even
though `DOCKER_HOST` is exported.**
`sudo` resets environment variables by default (`env_reset` in the sudoers
policy), so your exported `DOCKER_HOST` doesn't survive the `sudo` call —
`docker` then falls back to the default host socket path
(`/var/run/docker.sock`), which doesn't exist on macOS since there's no
local daemon. Either use `sudo -E docker ...` to preserve the environment,
or — usually simpler — just don't use `sudo` at all once you're in the
`docker` group (see the entry above); that's the whole point of the group
membership.

**`limactl shell docker-dev id` (or any command) prints
`bash: line 1: cd: /Users/you/... No such file or directory` before the
actual output, twice.**
Cosmetic, not an error. `limactl shell` tries to mirror your current host
working directory into the guest by `cd`-ing to the identical path, which
only works with Lima's default 1:1 home-directory mount. Since we
deliberately replaced that with a remapped mount
(`/Users/you/.../borgsnap_ng` → `/home/you/borgsnap_ng`, not a straight
mirror — see "The `~` mount problem" above), `limactl shell` can't resolve
that translation and falls back to trying your raw host path, then `$HOME`,
both of which don't exist in the guest. The command you actually ran still
executes correctly afterwards. To land directly in the repo instead of
seeing this every time:

```sh
limactl shell docker-dev -- sh -c 'cd /home/$(whoami)/borgsnap_ng && exec bash'
```

**`ls -la` on the guest home directory doesn't show the mounted repo, but
`cd` into it works fine.**
This is a virtiofs display/cache artifact on first access after boot, not a
real problem — a fresh shell session (`limactl shell <name>` again) usually
shows it correctly. `find /home/<you> -maxdepth 1` or `stat` will confirm
the mount is actually there even when `ls` looks stale.

**Provisioning warning: `provisioning scripts should not reference the
LIMA_CIDATA variables`**
Use the `{{.User}}` template variable (resolved at template-render time)
instead of `$LIMA_CIDATA_USER` or similar internal environment variables in
provisioning scripts — the latter are an implementation detail Lima
explicitly warns against depending on.

**Your whole macOS home directory (`/Users/you/...`) is visible inside the
VM.**
You created the instance with plain `limactl start` instead of
`create-clean-instance.sh`, so the `~` mount (see above) was never stripped.
Stop, delete, and recreate via the wrapper script.

## Design notes / rationale (for future maintainers)

- **Why Debian, not Ubuntu?** No particular reason beyond matching the
  target deployment distro for `borgsnap_ng`. The same `~`-mount and
  placeholder-substitution approach applies to any Lima distro template.
- **Why not just edit the source `.yaml` files with the real path?** That
  would work for one person on one machine, but breaks the moment the repo
  is cloned elsewhere or shared with someone else — exactly the portability
  problem this setup is designed to avoid.
- **Why `yq` and not `sed`/manual editing for the mount fix?** The resolved
  `lima.yaml` is a nontrivial nested YAML structure; `yq` lets us target the
  exact list entry (`location == "~"`) precisely, without risking a
  regex-based edit accidentally matching something else in the file.
- **Why strip the mount after `create` instead of preventing it in the
  first place?** We could not find a template-level way to suppress the
  inherited mount — Lima's base-template composition always combines mount
  lists rather than allowing one to fully override/replace another. If a
  future Lima version adds a supported way to disable inherited mounts,
  this workaround should be revisited and likely simplified.
