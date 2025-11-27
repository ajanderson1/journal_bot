#!/bin/bash

# Define directories
JOURNAL_DIR="$HOME/Journal"
BOT_DATA_DIR="$HOME/.journal-bot"
BOT_NAME="journal-bot"

# Ensure bot data directory exists for audit logs
mkdir -p "$BOT_DATA_DIR"

# 1. Pre-flight Check: Does Journal Exist?
if [ ! -d "$JOURNAL_DIR" ]; then
    echo "Error: Journal directory not found at $JOURNAL_DIR"
    exit 1
fi

# 2. Display host UID/GID for debugging
HOST_UID=$(id -u)
HOST_GID=$(id -g)
echo "Host user: $(whoami) (UID:$HOST_UID GID:$HOST_GID)"

# 3. Check for READ_ONLY mode from .env file
READ_ONLY=$(grep -E "^READ_ONLY=" .env 2>/dev/null | cut -d '=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
if [ "$READ_ONLY" = "true" ]; then
    JOURNAL_MOUNT_MODE=":ro"
    echo "📖 Read-only mode: Journal will be mounted as READ-ONLY"
else
    JOURNAL_MOUNT_MODE=""
    echo "📝 Read-write mode: Journal will be mounted with write access"
fi

# 4. Cleanup old container
echo "Cleaning up old container..."
docker stop $BOT_NAME 2>/dev/null
docker rm $BOT_NAME 2>/dev/null

# 5. Build image
echo "Building image..."
docker build -t journal-bot .

# 6. Run Journal Bot
# The entrypoint.sh will automatically detect and match host UID/GID
# PUID/PGID env vars are passed as explicit override (optional but recommended)
# Maps:
# - Journal Repo (RW or RO based on READ_ONLY env var)
# - SSH Keys (RO) for Git Auth
# - Git Config (RO) for Commit Identity
# - Claude credentials (RW) for runtime/debug files
# - Bot data dir for persistent audit logs
echo "Launching Journal Bot..."
docker run -d \
  --name $BOT_NAME \
  --restart unless-stopped \
  --env-file .env \
  -e PUID="$HOST_UID" \
  -e PGID="$HOST_GID" \
  -v "$JOURNAL_DIR":/Journal$JOURNAL_MOUNT_MODE \
  -v ~/.ssh:/home/botuser/.ssh:ro \
  -v ~/.gitconfig:/home/botuser/.gitconfig:ro \
  -v ~/.claude:/home/botuser/.claude \
  -v "$BOT_DATA_DIR":/app/data \
  journal-bot

# 7. Post-Launch Verification
sleep 3
if [ "$(docker inspect -f '{{.State.Running}}' $BOT_NAME)" = "true" ]; then
    echo "Bot is RUNNING."
    echo ""
    echo "Container user info:"
    docker exec $BOT_NAME id
    echo ""
    echo "Startup logs:"
    docker logs $BOT_NAME 2>&1 | head -n 25
else
    echo "Bot failed to start. Check logs:"
    docker logs $BOT_NAME
fi