#!/usr/bin/env bash
# setup-backup.sh - interactive configuration wizard for borgsnap_ng,
# licensed under GPLv3. See the LICENSE file for additional details.
#
# Walks through creating one backup configuration end to end: the
# dedicated user (if install.sh hasn't already made one), the .conf file
# itself, ZFS delegation for the chosen dataset(s), and a systemd
# timer/service pair to actually run it on a schedule. Assumes
# install.sh has already deployed the application files - this script
# only adds a specific backup JOB on top of that.
#
# Usage:
#   sudo ./setup-backup.sh [options]
#
# Options:
#   --install-dir=PATH   Where borgsnap_ng was installed (default:
#                          /usr/local/bin/borgsnap_ng)
#   --dry-run              Print what would happen, change nothing
#   -h, --help                Show this help and exit
#
# Everything else is asked interactively - there is no non-interactive
# mode, by design: this script exists specifically because the
# configuration has enough moving, interdependent parts that skipping
# straight to flags/env vars defeats the point.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults and flag parsing
# ---------------------------------------------------------------------------
INSTALL_DIR="/usr/local/bin/borgsnap_ng"
DRY_RUN=0

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

for arg in "$@"; do
    case "$arg" in
        --install-dir=*) INSTALL_DIR="${arg#*=}" ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $arg" >&2; usage 1 ;;
    esac
done

run() {
    echo "+ $*"
    if [ "$DRY_RUN" -eq 0 ]; then
        "$@"
    fi
}

ask() {
    # $1 - prompt. $2 - default (used verbatim if the user just hits
    # Enter). Echoes the answer; caller captures it via $(ask ...).
    local prompt="$1"
    local default="$2"
    local reply
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " reply
    else
        read -r -p "$prompt: " reply
    fi
    echo "${reply:-$default}"
}

ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local hint="y/N"
    [ "$default" = "y" ] && hint="Y/n"
    local reply
    read -r -p "$prompt [$hint] " reply || true
    reply="${reply:-$default}"
    case "$reply" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

section() {
    echo ""
    echo "=================================================================="
    echo "$1"
    echo "=================================================================="
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "setup-backup.sh: must be run as root (user/systemd/sudoers changes" >&2
    echo "  need it). Re-run with sudo." >&2
    exit 1
fi

if [ ! -f "$INSTALL_DIR/borgsnap_ng.sh" ]; then
    echo "setup-backup.sh: no borgsnap_ng.sh found under '$INSTALL_DIR'." >&2
    echo "  Run install.sh first, or pass --install-dir=PATH if you" >&2
    echo "  installed somewhere other than the default." >&2
    exit 1
fi

echo "=================================================================="
echo "borgsnap_ng backup configuration wizard"
[ "$DRY_RUN" -eq 1 ] && echo "  Mode: DRY RUN - nothing will actually change"
echo "=================================================================="

# ===========================================================================
# Step 1: the backup user
# ===========================================================================
section "Step 1/13: backup user"
echo "borgsnap_ng should run as a dedicated, non-root user, not root -"
echo "see ops/least-privilege/README.md for why."
BACKUP_USER=$(ask "User to run backups as" "borg")

if id "$BACKUP_USER" >/dev/null 2>&1; then
    echo "User '$BACKUP_USER' already exists - using it."
    USER_HOME=$(getent passwd "$BACKUP_USER" | cut -d: -f6)
else
    echo "User '$BACKUP_USER' doesn't exist yet."
    if ask_yes_no "Create it now (system account, real home directory, bash shell)?" "y"; then
        run useradd --system --create-home --home-dir "/home/$BACKUP_USER" --shell /bin/bash "$BACKUP_USER"
        USER_HOME="/home/$BACKUP_USER"
    else
        echo "setup-backup.sh: can't continue without a user that exists - aborting." >&2
        exit 1
    fi
fi
[ -z "${USER_HOME:-}" ] && USER_HOME="/home/$BACKUP_USER"
echo "Using user '$BACKUP_USER' (home: $USER_HOME)."

# ===========================================================================
# Step 2: zfssend?
# ===========================================================================
section "Step 2/13: native ZFS send/receive target"
echo "In addition to (or instead of) borg, backups can go to another ZFS"
echo "pool via native 'zfs send/receive' - see filesystem/zfs_send_hdlr.sh."
USE_ZFSSEND=0
ZFSSEND_TARGET=""
if ask_yes_no "Use a zfssend target?" "n"; then
    USE_ZFSSEND=1
    while :; do
        ZFSSEND_TARGET=$(ask "Target dataset (pool/dataset/path - no leading slash)" "")
        case "$ZFSSEND_TARGET" in
            /*)
                echo "That starts with '/' - ZFS dataset paths look like 'pool/dataset/path', not a filesystem path. Try again." ;;
            "")
                echo "Can't be empty." ;;
            *) break ;;
        esac
    done
fi

# ===========================================================================
# Step 3: local borg, remote borg, or both?
# ===========================================================================
section "Step 3/13: borg destinations"
echo "Besides zfssend (if enabled above), you can back up with borg to a"
echo "local repo, a remote (ssh://) repo, or both."
USE_LOCAL_BORG=0
USE_REMOTE_BORG=0
BORG_CHOICE=$(ask "Use local borg, remote borg, both, or none? [local/remote/both/none]" "local")
case "$BORG_CHOICE" in
    local) USE_LOCAL_BORG=1 ;;
    remote) USE_REMOTE_BORG=1 ;;
    both) USE_LOCAL_BORG=1; USE_REMOTE_BORG=1 ;;
    none) : ;;
    *) echo "Unrecognized answer '$BORG_CHOICE' - treating as 'none'." ;;
esac

if [ "$USE_ZFSSEND" -eq 0 ] && [ "$USE_LOCAL_BORG" -eq 0 ] && [ "$USE_REMOTE_BORG" -eq 0 ]; then
    echo "setup-backup.sh: no destination configured at all (no zfssend, no borg) - nothing to back up to, aborting." >&2
    exit 1
fi

REPOLIST_ENTRIES=""

# ===========================================================================
# Step 4/5/6: remote borg specifics (SSH alias, repo path, reachability)
# ===========================================================================
if [ "$USE_REMOTE_BORG" -eq 1 ]; then
    section "Step 4/13: SSH target for the remote repo"
    SSH_CONFIG="$USER_HOME/.ssh/config"
    SSH_ALIAS=""
    if [ -f "$SSH_CONFIG" ]; then
        EXISTING_HOSTS=$(grep -i '^Host ' "$SSH_CONFIG" 2>/dev/null | awk '{print $2}')
    else
        EXISTING_HOSTS=""
    fi
    if [ -n "$EXISTING_HOSTS" ]; then
        echo "Existing SSH Host aliases found in $SSH_CONFIG:"
        echo "$EXISTING_HOSTS" | sed 's/^/  - /'
        if ask_yes_no "Use one of these?" "y"; then
            SSH_ALIAS=$(ask "Which alias" "")
        fi
    else
        echo "No existing SSH config found for '$BACKUP_USER' at $SSH_CONFIG."
    fi

    if [ -z "$SSH_ALIAS" ]; then
        echo "Setting up a new SSH target."
        SSH_ALIAS=$(ask "Alias name for this target (e.g. 'myrepo')" "")
        SSH_HOSTNAME=$(ask "Actual hostname (e.g. u1234.your-storagebox.de)" "")
        SSH_PORT=$(ask "SSH port" "22")
        SSH_KEYFILE="$USER_HOME/.ssh/${SSH_ALIAS}_borg"
        if [ -f "$SSH_KEYFILE" ]; then
            echo "Key file $SSH_KEYFILE already exists - reusing it."
        elif command -v ssh-keygen >/dev/null 2>&1; then
            run sudo -u "$BACKUP_USER" mkdir -p "$USER_HOME/.ssh"
            run chmod 700 "$USER_HOME/.ssh"
            run sudo -u "$BACKUP_USER" ssh-keygen -t ed25519 -N "" -C "borgsnap_ng-${SSH_ALIAS}" -f "$SSH_KEYFILE"
        else
            echo "setup-backup.sh: 'ssh-keygen' not found - can't generate a key automatically." >&2
            echo "  Generate one yourself (as '$BACKUP_USER'): ssh-keygen -t ed25519 -f '$SSH_KEYFILE'" >&2
            echo "  Re-run this wizard once that key exists." >&2
            exit 1
        fi
        if [ "$DRY_RUN" -eq 0 ]; then
            {
                echo ""
                echo "Host $SSH_ALIAS"
                echo "    HostName $SSH_HOSTNAME"
                echo "    Port $SSH_PORT"
                echo "    IdentityFile $SSH_KEYFILE"
                echo "    User $(ask "Remote login username" "root")"
            } >> "$SSH_CONFIG"
            chown "$BACKUP_USER" "$SSH_CONFIG"
            chmod 600 "$SSH_CONFIG"
        fi
        echo ""
        echo "Public key to authorize on the remote side:"
        if [ -f "${SSH_KEYFILE}.pub" ]; then
            cat "${SSH_KEYFILE}.pub"
        else
            echo "  (will be at ${SSH_KEYFILE}.pub once the key is generated)"
        fi
        echo ""
        echo "Add that key on the remote server/provider before continuing -"
        echo "the reachability check next will fail otherwise."
        ask "Press Enter once that's done" "" >/dev/null
    fi

    section "Step 5/13: remote repo details"
    IS_BORGBASE=0
    if ask_yes_no "Is this a BorgBase repo (forced-command SSH, web-UI-created repo)?" "n"; then
        IS_BORGBASE=1
    fi
    REMOTE_REPO_PATH=$(ask "Repo path on the remote (e.g. './repo' or './myhost/data')" "./repo")
    REMOTE_BORG_CMD=$(ask "Remote borg binary name (leave empty for default 'borg')" "")

    section "Step 6/13: reachability check"
    echo "Checking SSH connectivity to '$SSH_ALIAS'..."
    if [ "$DRY_RUN" -eq 0 ]; then
        if ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_ALIAS" true 2>/dev/null; then
            echo "SSH connection to '$SSH_ALIAS' succeeded."
        else
            echo "WARNING: could not reach '$SSH_ALIAS' over SSH." >&2
            if ! ask_yes_no "Continue anyway?" "n"; then
                exit 1
            fi
        fi
    else
        echo "+ (dry run) would check: ssh -o BatchMode=yes $SSH_ALIAS true"
    fi

    if [ "$IS_BORGBASE" -eq 1 ]; then
        REPOLIST_ENTRIES="${REPOLIST_ENTRIES}borgbase:ssh://${SSH_ALIAS}/${REMOTE_REPO_PATH}, ${REMOTE_BORG_CMD}; "
    else
        REPOLIST_ENTRIES="${REPOLIST_ENTRIES}ssh://${SSH_ALIAS}/${REMOTE_REPO_PATH}, ${REMOTE_BORG_CMD}; "
    fi
fi

# ===========================================================================
# Local borg repo path
# ===========================================================================
if [ "$USE_LOCAL_BORG" -eq 1 ]; then
    section "Local repo path"
    LOCAL_REPO_PATH=$(ask "Local repo directory" "/home/$BACKUP_USER/borg-repo")
    if [ -d "$LOCAL_REPO_PATH" ]; then
        echo "Directory already exists."
    else
        if ask_yes_no "Directory doesn't exist yet - create it now?" "y"; then
            run mkdir -p "$LOCAL_REPO_PATH"
            run chown "$BACKUP_USER" "$LOCAL_REPO_PATH"
        fi
    fi
    REPOLIST_ENTRIES="${REPOLIST_ENTRIES}${LOCAL_REPO_PATH}, ; "
fi

# ===========================================================================
# Step 7: source dataset, recursion, ZFS check
# ===========================================================================
section "Step 7/13: source ZFS dataset"
while :; do
    SOURCE_DATASET=$(ask "ZFS dataset to back up (e.g. tank/data)" "")
    if [ -z "$SOURCE_DATASET" ]; then
        echo "Can't be empty."
        continue
    fi
    if ! command -v zfs >/dev/null 2>&1; then
        echo "setup-backup.sh: 'zfs' command not found on this system - can't verify '$SOURCE_DATASET' is a real ZFS dataset." >&2
        exit 1
    fi
    if zfs list "$SOURCE_DATASET" >/dev/null 2>&1; then
        echo "'$SOURCE_DATASET' is a valid ZFS dataset."
        break
    else
        echo "setup-backup.sh: '$SOURCE_DATASET' is not a ZFS dataset (zfs list failed)." >&2
        if ! ask_yes_no "Try a different dataset name?" "y"; then
            exit 1
        fi
    fi
done
RECURSIVE_FLAG=""
if ask_yes_no "Back up '$SOURCE_DATASET' recursively (include child datasets)?" "n"; then
    RECURSIVE_FLAG="r"
fi

# ===========================================================================
# Step 8: compression
# ===========================================================================
section "Step 8/13: compression"
echo "auto,zstd,3 is a good default: skips compression entirely for"
echo "already-compressed data, zstd level 3 is a solid speed/ratio"
echo "compromise for the rest."
COMPRESS=$(ask "COMPRESS setting" "auto,zstd,3")

# ===========================================================================
# Step 9: email
# ===========================================================================
section "Step 9/13: email notifications"
MAILTO=$(ask "Email address for SUCCESS/FAILURE notifications (leave empty to skip)" "")

# ===========================================================================
# Step 10: LOCAL_READABLE_BY_OTHERS
# ===========================================================================
section "Step 10/13: local repo readability"
LOCAL_READABLE=false
if [ "$USE_LOCAL_BORG" -eq 1 ] && ask_yes_no "Make the local repo readable by other local users (not just $BACKUP_USER)?" "n"; then
    LOCAL_READABLE=true
fi

# ===========================================================================
# Step 11: intervals and retention
# ===========================================================================
section "Step 11/13: retention"
RETENTIONPERIOD=$(ask "RETENTIONPERIOD (interval,keep pairs)" "monthly,1;weekly,4;daily,7")

# ===========================================================================
# Step 12: verification
# ===========================================================================
section "Step 12/13: verification"
echo "BORG_VERIFY checks stored-byte integrity (borg check). Depths:"
echo "  off / repo (cheap) / archive / data (most thorough, most expensive)"
BORG_VERIFY_DEPTH=$(ask "Default BORG_VERIFY depth for every interval" "repo")
case "$BORG_VERIFY_DEPTH" in
    off|repo|archive|data) : ;;
    *) echo "Unrecognized depth '$BORG_VERIFY_DEPTH' - using 'repo'."; BORG_VERIFY_DEPTH="repo" ;;
esac
BORG_VERIFY="default:${BORG_VERIFY_DEPTH}"

RESTORE_VERIFY=""
echo ""
echo "RESTORE_VERIFY proves the actual restore path works (not just that"
echo "borg check's bytes are intact) - but it needs WRITE access to the"
echo "live dataset's own mountpoint, the one exception to this project's"
echo "usual read-only approach."
if ask_yes_no "Enable RESTORE_VERIFY?" "n"; then
    RESTORE_VERIFY="default:on"
fi

# ===========================================================================
# Step 13: passphrase / key file
# ===========================================================================
section "Step 13/13: encryption passphrase"
KEY_FILE="$INSTALL_DIR/$(ask "Config name (used for the .conf and .key filenames)" "backup").key"
CONFIG_NAME=$(basename "$KEY_FILE" .key)
CONFIG_FILE="$INSTALL_DIR/${CONFIG_NAME}.conf"

if [ -f "$KEY_FILE" ]; then
    echo "Key file $KEY_FILE already exists - reusing it, not overwriting."
else
    if ask_yes_no "Generate a random passphrase automatically (recommended)?" "y"; then
        PASSPHRASE=$(openssl rand -base64 32)
    else
        while :; do
            read -r -s -p "Enter passphrase: " PASSPHRASE; echo
            read -r -s -p "Confirm passphrase: " PASSPHRASE_CONFIRM; echo
            [ "$PASSPHRASE" = "$PASSPHRASE_CONFIRM" ] && break
            echo "Passphrases didn't match - try again."
        done
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
        printf '%s\n' "$PASSPHRASE" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        chown "$BACKUP_USER" "$KEY_FILE"
    fi
    unset PASSPHRASE PASSPHRASE_CONFIRM
    echo "Key file written to $KEY_FILE (mode 600, owned by $BACKUP_USER)."
    echo "IMPORTANT: back this passphrase up somewhere safe, separately from"
    echo "the backups themselves - without it, the backups are unreadable."
fi

# ===========================================================================
# Write the config file
# ===========================================================================
section "Writing configuration"

if [ "$USE_ZFSSEND" -eq 1 ]; then
    REPOLIST_ENTRIES="zfssend:${ZFSSEND_TARGET}, ; ${REPOLIST_ENTRIES}"
fi

if [ "$DRY_RUN" -eq 0 ]; then
    cat > "$CONFIG_FILE" << CONFEOF
LOCAL_BORG_USER="$BACKUP_USER"
FS="${SOURCE_DATASET},${RECURSIVE_FLAG}"
COMPRESS="$COMPRESS"
CACHEMODE="mtime,size"
PASS="$KEY_FILE"
BASEDIR=""
LOCAL_READABLE_BY_OTHERS=$LOCAL_READABLE
REPOLIST="$REPOLIST_ENTRIES"
REPOSKIP="NONE"
RETENTIONPERIOD="$RETENTIONPERIOD"
BORG_VERIFY="$BORG_VERIFY"
RESTORE_VERIFY="$RESTORE_VERIFY"
PRE_SCRIPT=
POST_SCRIPT=
MAILTO="$MAILTO"
CONFEOF
    chmod 600 "$CONFIG_FILE"
    chown "$BACKUP_USER" "$CONFIG_FILE"
    echo "Wrote $CONFIG_FILE"
else
    echo "+ (dry run) would write $CONFIG_FILE with:"
    echo "    FS=\"${SOURCE_DATASET},${RECURSIVE_FLAG}\""
    echo "    REPOLIST=\"$REPOLIST_ENTRIES\""
fi

# ===========================================================================
# ZFS delegation
# ===========================================================================
section "ZFS delegation"
ZFS_ALLOW_SCRIPT="$INSTALL_DIR/ops/least-privilege/setup-zfs-allow.sh"
if [ -x "$ZFS_ALLOW_SCRIPT" ]; then
    if ask_yes_no "Delegate ZFS access on '$SOURCE_DATASET' to '$BACKUP_USER' now?" "y"; then
        run "$ZFS_ALLOW_SCRIPT" source "$BACKUP_USER" "$SOURCE_DATASET"
    fi
    if [ "$USE_ZFSSEND" -eq 1 ]; then
        if ask_yes_no "Delegate ZFS access on the zfssend target ('$ZFSSEND_TARGET') to '$BACKUP_USER' now?" "y"; then
            run "$ZFS_ALLOW_SCRIPT" target "$BACKUP_USER" "$ZFSSEND_TARGET"
        fi
    fi
else
    echo "setup-backup.sh: $ZFS_ALLOW_SCRIPT not found or not executable - skipping." >&2
    echo "  Run it by hand: sudo $ZFS_ALLOW_SCRIPT source $BACKUP_USER $SOURCE_DATASET" >&2
fi

# ===========================================================================
# systemd registration
# ===========================================================================
section "systemd timer"
if command -v systemctl >/dev/null 2>&1; then
    SERVICE_FILE="/etc/systemd/system/borgsnap-ng@.service"
    TIMER_FILE="/etc/systemd/system/borgsnap-ng@.timer"
    if [ ! -f "$SERVICE_FILE" ] || [ ! -f "$TIMER_FILE" ]; then
        echo "setup-backup.sh: the borgsnap-ng@.service/.timer templates aren't" >&2
        echo "  installed yet - run install.sh first (it installs these)." >&2
    else
        SCHEDULE=$(ask "OnCalendar schedule for this config" "*-*-* 02:00:00")
        DROPIN_DIR="/etc/systemd/system/borgsnap-ng@${CONFIG_NAME}.timer.d"
        if [ "$SCHEDULE" != "*-*-* 02:00:00" ]; then
            run mkdir -p "$DROPIN_DIR"
            if [ "$DRY_RUN" -eq 0 ]; then
                cat > "$DROPIN_DIR/override.conf" << TIMEREOF
[Timer]
OnCalendar=
OnCalendar=$SCHEDULE
TIMEREOF
            else
                echo "+ (dry run) would write $DROPIN_DIR/override.conf with OnCalendar=$SCHEDULE"
            fi
        fi
        run systemctl daemon-reload || true
        if ask_yes_no "Enable and start the timer now (borgsnap-ng@${CONFIG_NAME}.timer)?" "y"; then
            run systemctl enable --now "borgsnap-ng@${CONFIG_NAME}.timer" || \
                echo "setup-backup.sh: enabling the timer failed - if this is a container without a running systemd, that's expected; run it on the real target system." >&2
        fi
    fi
else
    echo "setup-backup.sh: systemctl not found - see ops/README.md for the cron alternative." >&2
fi

# ===========================================================================
# Summary
# ===========================================================================
section "Done"
echo "Config:        $CONFIG_FILE"
echo "Key file:      $KEY_FILE"
echo "Runs as:       $BACKUP_USER"
echo "systemd timer: borgsnap-ng@${CONFIG_NAME}.timer"
echo ""
echo "Before trusting the timer, test it directly once:"
echo "  sudo -u $BACKUP_USER $INSTALL_DIR/mail_wrapper.sh $CONFIG_FILE"
echo ""
[ "$DRY_RUN" -eq 1 ] && echo "This was a DRY RUN - nothing was actually changed."
exit 0
