# Scheduling and notifications

`mail_wrapper.sh` (repo root) is the single, portable piece that matters:
it runs `borgsnap_ng.sh run <config>`, then always sends exactly one email
- SUCCESS or FAILURE - with a correct subject line and priority, instead
of relying on cron's own "mail on any output" behavior (which can't
distinguish success from failure, and only fires when there's output at
all) or systemd's `OnFailure=` (which has no equivalent for success).

Because that logic lives in one POSIX `sh` script with no systemd or cron
dependency, the actual scheduler around it is interchangeable - pick
whichever fits your platform. Both call the exact same wrapper; there is
no separate implementation to keep in sync.

## Prerequisites (either path)

- A `sendmail`-compatible command in `PATH` or one of `/usr/sbin/sendmail`,
  `/usr/lib/sendmail`, `/usr/local/sbin/sendmail`. Postfix, Sendmail, Exim,
  and OpenSMTPD (FreeBSD's default) all provide this. For `msmtp`, run it
  with `--sendmail` or symlink it as `sendmail` somewhere in `PATH`.
- `MAILTO="you@example.com"` set in the same `.conf` file `borgsnap_ng.sh`
  already uses for that job. If it's not set, the backup still runs
  normally - `mail_wrapper.sh` just skips the email step and says so on
  stderr.

## systemd (Debian/Proxmox, or anywhere systemd is your init)

If you installed via `install.sh` (see the main README), the steps below
already happened - it copies both unit files, sets `ExecStart=` to your
actual install path, and adds `User=`/`Group=` for the dedicated backup
user, none of which the manual steps below do automatically. Skip ahead
to the `systemctl enable --now` step.

```
cp ops/systemd/borgsnap-ng@.service /etc/systemd/system/
cp ops/systemd/borgsnap-ng@.timer   /etc/systemd/system/
# edit the ExecStart= path in the .service file to match where you
# actually installed borgsnap_ng and your config files
systemctl daemon-reload
systemctl enable --now borgsnap-ng@client_images.timer
```

`%i` in both unit files is the config's base name (without `.conf`) - so
`borgsnap-ng@client_images.timer` runs against `client_images.conf`. Each
config gets its own independent timer+service pair; enable as many as you
need.

Check status and logs with:
```
systemctl status borgsnap-ng@client_images.service
journalctl -u borgsnap-ng@client_images.service
```

## cron (FreeBSD, or anywhere you'd rather not depend on systemd)

No unit files needed - `mail_wrapper.sh` is the whole implementation.
Add a line like this to root's crontab (`crontab -e`):

```
0 2 * * * /usr/local/bin/borgsnap_ng/mail_wrapper.sh /usr/local/bin/borgsnap_ng/client_images.conf >/dev/null 2>&1
```

The `>/dev/null 2>&1` at the end matters: without it, cron's own
mail-on-output mechanism fires *in addition to* the wrapper's own email,
and you get a second, badly-formatted message on top of the real one.
