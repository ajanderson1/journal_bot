#!/bin/bash

# Define directories
JOURNAL_DIR="$HOME/Journal"
BOT_DATA_DIR="$HOME/.journal-bot"
BOT_NAME="journal-bot"

# Ensure bot data directory exists for audit logs
mkdir -p "$BOT_DATA_DIR"

# 1. Pre-flight Check: Does Journal Exist?
if [ ! -d "$JOURNAL_DIR" ]; then
    echo "❌ Error: Journal directory not found at $JOURNAL_DIR"
    exit 1
fi

# 2. Cleanup old container
echo "🧹 Cleaning up old container..."
docker stop $BOT_NAME 2>/dev/null
docker rm $BOT_NAME 2>/dev/null

# 3. Build image
echo "🔨 Building image..."
docker build -t journal-bot .

# 4. Run Journal Bot
# Maps:
# - Journal Repo (RW)
# - SSH Keys (RO) for Git Auth
# - Git Config (RO) for Commit Identity
# - Claude credentials (RW) for runtime/debug files
# - Bot data dir for persistent audit logs
# - Claude project settings (RO) for tool permissions
echo "🚀 Launching Journal Bot..."
docker run -d \
  --name $BOT_NAME \
  --restart unless-stopped \
  --env-file .env \
  -v "$JOURNAL_DIR":/Journal \
  -v ~/.ssh:/home/botuser/.ssh:ro \
  -v ~/.gitconfig:/home/botuser/.gitconfig:ro \
  -v ~/.claude:/home/botuser/.claude \
  -v "$BOT_DATA_DIR":/app/data \
  -v "$(pwd)/.claude":/Journal/.claude:ro \
  journal-bot

# 5. Post-Launch Verification
sleep 3
if [ "$(docker inspect -f '{{.State.Running}}' $BOT_NAME)" = "true" ]; then
    echo "✅ Bot is RUNNING."
    echo "📝 Logs:"
    docker logs $BOT_NAME | head -n 10
else
    echo "❌ Bot failed to start. Check logs:"
    docker logs $BOT_NAME
fi