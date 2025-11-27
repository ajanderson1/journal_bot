#!/bin/bash
set -e

VOLUME_PATH="/Journal"
BOT_USER="botuser"
BOT_GROUP="botuser"
BOT_HOME="/home/botuser"

# Check read-only mode from environment
READ_ONLY=${READ_ONLY:-false}
READ_ONLY=$(echo "$READ_ONLY" | tr '[:upper:]' '[:lower:]')

echo "=== Journal Bot Entrypoint ==="
if [ "$READ_ONLY" = "true" ]; then
    echo "Mode: READ-ONLY (journal writes disabled)"
else
    echo "Mode: READ-WRITE"
fi

# Detect host UID/GID from mounted volume
if [ -d "$VOLUME_PATH" ]; then
    HOST_UID=$(stat -c '%u' "$VOLUME_PATH")
    HOST_GID=$(stat -c '%g' "$VOLUME_PATH")
    echo "Detected host UID:GID = $HOST_UID:$HOST_GID"
else
    echo "Warning: $VOLUME_PATH not mounted, using defaults"
    HOST_UID=1000
    HOST_GID=1000
fi

# Allow environment variable override
HOST_UID=${PUID:-$HOST_UID}
HOST_GID=${PGID:-$HOST_GID}

# Refuse to run as root
if [ "$HOST_UID" = "0" ]; then
    echo "ERROR: Volume owned by root (UID 0). This is a security risk."
    echo "Fix with: sudo chown -R \$(id -u):\$(id -g) ~/Journal"
    exit 1
fi

# Get current container user UID/GID
CURRENT_UID=$(id -u $BOT_USER 2>/dev/null || echo "1000")
CURRENT_GID=$(id -g $BOT_USER 2>/dev/null || echo "1000")

# Adjust UID/GID if needed
if [ "$HOST_UID" != "$CURRENT_UID" ] || [ "$HOST_GID" != "$CURRENT_GID" ]; then
    echo "Adjusting $BOT_USER from $CURRENT_UID:$CURRENT_GID to $HOST_UID:$HOST_GID"

    # Handle UID collision - reassign existing user with target UID
    EXISTING_USER=$(getent passwd "$HOST_UID" | cut -d: -f1 || true)
    if [ -n "$EXISTING_USER" ] && [ "$EXISTING_USER" != "$BOT_USER" ]; then
        echo "  Reassigning UID $HOST_UID from $EXISTING_USER..."
        usermod -u 65534 "$EXISTING_USER" 2>/dev/null || true
    fi

    # Handle GID collision - reassign existing group with target GID
    EXISTING_GROUP=$(getent group "$HOST_GID" | cut -d: -f1 || true)
    if [ -n "$EXISTING_GROUP" ] && [ "$EXISTING_GROUP" != "$BOT_GROUP" ]; then
        echo "  Reassigning GID $HOST_GID from $EXISTING_GROUP..."
        groupmod -g 65534 "$EXISTING_GROUP" 2>/dev/null || true
    fi

    # Modify group first, then user
    groupmod -g "$HOST_GID" "$BOT_GROUP" 2>/dev/null || true
    usermod -u "$HOST_UID" -g "$HOST_GID" "$BOT_USER" 2>/dev/null || true

    # Fix ownership of bot user's home directory and app files
    chown -R "$HOST_UID:$HOST_GID" "$BOT_HOME" 2>/dev/null || true
    chown -R "$HOST_UID:$HOST_GID" /app 2>/dev/null || true

    echo "UID/GID adjustment complete"
else
    echo "UID/GID already match ($CURRENT_UID:$CURRENT_GID)"
fi

# Configure git safe.directory
echo "Configuring git safe.directory..."
git config --global --add safe.directory "$VOLUME_PATH" 2>/dev/null || true
gosu "$BOT_USER" git config --global --add safe.directory "$VOLUME_PATH" 2>/dev/null || true

# Verify permissions on all volumes
echo "Verifying volume permissions..."
verify_access() {
    local path=$1
    local mode=$2
    local label=$3

    if [ ! -e "$path" ]; then
        echo "  $label: SKIP (not mounted)"
        return
    fi

    if [ "$mode" = "RW" ]; then
        if gosu "$BOT_USER" test -r "$path" && gosu "$BOT_USER" test -w "$path"; then
            echo "  $label: OK (RW)"
        else
            echo "  $label: WARNING - permission issue"
        fi
    else
        if gosu "$BOT_USER" test -r "$path"; then
            echo "  $label: OK (RO)"
        else
            echo "  $label: WARNING - cannot read"
        fi
    fi
}

# Verify journal access based on mode
if [ "$READ_ONLY" = "true" ]; then
    verify_access "/Journal" "RO" "/Journal (read-only mode)"
else
    verify_access "/Journal" "RW" "/Journal"
fi
verify_access "/app/data" "RW" "/app/data (audit logs)"
verify_access "$BOT_HOME/.claude" "RW" "~/.claude"
verify_access "$BOT_HOME/.ssh" "RO" "~/.ssh"
verify_access "$BOT_HOME/.gitconfig" "RO" "~/.gitconfig"

echo "================================"
echo "Starting as $BOT_USER (UID:$(id -u $BOT_USER) GID:$(id -g $BOT_USER))"
echo "================================"

exec gosu "$BOT_USER" "$@"
