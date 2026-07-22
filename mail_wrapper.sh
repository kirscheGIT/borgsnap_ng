#!/bin/sh
# mail_wrapper.sh - licensed under GPLv3. See the LICENSE file for additional
# details.
#
# FIX #47 (Phase 6): portable success/failure email notification wrapper
# around borgsnap_ng.sh. Works identically whether triggered by cron or by
# a systemd timer+service - see ops/systemd/ for the systemd units, or the
# crontab example in this file's own usage text below.
#
# Why this exists instead of relying on cron's "mail on any output"
# behavior or systemd's OnFailure=: neither gives control over the
# subject line or message priority, and cron only mails when there's
# output at all - not reliably on every run, and never distinguishing
# success from failure in the subject.
#
# Usage:
#   mail_wrapper.sh /path/to/config.conf
#
# Reads MAILTO="user@example.com" from the SAME config file borgsnap_ng.sh
# itself uses (same convention as every other borgsnap_ng setting) - no
# second config file. If MAILTO isn't set, borgsnap_ng.sh just runs
# without any email step.
#
# Requires a sendmail-compatible command in PATH: Postfix, Sendmail, Exim,
# and OpenSMTPD (FreeBSD's default) all provide this interface, as does
# msmtp when run with --sendmail. This is what keeps the wrapper itself
# portable - it never needs to know which MTA is actually in use.
#
# Crontab example (redirect the wrapper's own stdout/stderr to /dev/null -
# otherwise cron's OWN mail-on-output mechanism fires TOO, and you get a
# duplicate, badly-formatted email on top of this script's own):
#   0 2 * * * /usr/local/bin/borgsnap_ng/mail_wrapper.sh /usr/local/bin/borgsnap_ng/client_images.conf >/dev/null 2>&1

set -u

mailwrap_usage() {
    echo "Usage: $0 /path/to/config.conf" >&2
    exit 1
}

[ "$#" -ge 1 ] || mailwrap_usage
mailwrap_config="$1"

mailwrap_scriptdir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
mailwrap_hostname="$(hostname 2>/dev/null || echo unknown-host)"
mailwrap_configname="$(basename -- "$mailwrap_config")"
mailwrap_starttime="$(date '+%Y-%m-%d %H:%M:%S')"

if [ ! -r "$mailwrap_config" ]; then
    echo "mail_wrapper.sh: cannot read config file: $mailwrap_config" >&2
    exit 1
fi

# Extract MAILTO from the config in a subshell, so sourcing it doesn't
# pollute this script's own environment with the rest of its variables
# (PASS, REPOLIST, etc. - this wrapper has no business seeing those).
mailwrap_mailto=$(
    MAILTO=""
    # shellcheck disable=SC1090
    . "$mailwrap_config"
    echo "$MAILTO"
)

if [ -z "$mailwrap_mailto" ]; then
    echo "mail_wrapper.sh: no MAILTO set in $mailwrap_config - running without email notification" >&2
    exec "$mailwrap_scriptdir/borgsnap_ng.sh" run "$mailwrap_config"
fi

# Find a sendmail-compatible command. Checked in this order because a
# bare `command -v sendmail` can fail under cron/systemd's minimal PATH
# even when the binary is present at one of these standard locations.
mailwrap_sendmail=""
for mailwrap_candidate in sendmail /usr/sbin/sendmail /usr/lib/sendmail /usr/local/sbin/sendmail; do
    if command -v "$mailwrap_candidate" >/dev/null 2>&1; then
        mailwrap_sendmail="$mailwrap_candidate"
        break
    fi
done
if [ -z "$mailwrap_sendmail" ]; then
    echo "mail_wrapper.sh: no sendmail-compatible command found in PATH or standard locations - running without email notification" >&2
    exec "$mailwrap_scriptdir/borgsnap_ng.sh" run "$mailwrap_config"
fi

mailwrap_logfile=$(mktemp)
trap 'rm -f "$mailwrap_logfile"' EXIT INT TERM HUP

# Capture the real exit code via a tempfile, not a pipe - piping into
# `tee` here would lose it (the pipeline's own $? reflects tee, not
# borgsnap_ng.sh - the exact FIX #37 lesson from earlier in this project).
"$mailwrap_scriptdir/borgsnap_ng.sh" run "$mailwrap_config" > "$mailwrap_logfile" 2>&1
mailwrap_rc=$?

# Still surface the log on our own stdout, so it shows up in `journalctl`
# (systemd) or wherever this wrapper's own output is captured.
cat "$mailwrap_logfile"

mailwrap_endtime="$(date '+%Y-%m-%d %H:%M:%S')"

if [ "$mailwrap_rc" -eq 0 ]; then
    mailwrap_status="SUCCESS"
    mailwrap_priority_headers=""
else
    mailwrap_status="FAILURE"
    mailwrap_priority_headers="X-Priority: 1 (Highest)
Importance: High
X-MSMail-Priority: High"
fi

mailwrap_subject="[borgsnap_ng] $mailwrap_status: $mailwrap_hostname / $mailwrap_configname"

{
    echo "To: $mailwrap_mailto"
    echo "Subject: $mailwrap_subject"
    [ -n "$mailwrap_priority_headers" ] && printf '%s\n' "$mailwrap_priority_headers"
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""
    echo "borgsnap_ng run: $mailwrap_status"
    echo "Host:            $mailwrap_hostname"
    echo "Config:          $mailwrap_config"
    echo "Started:         $mailwrap_starttime"
    echo "Finished:        $mailwrap_endtime"
    echo "Exit code:       $mailwrap_rc"
    echo ""
    echo "--- Log output ---"
    cat "$mailwrap_logfile"
} | "$mailwrap_sendmail" -t

exit "$mailwrap_rc"
