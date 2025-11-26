# Secure Journal Bot

A secure, Dockerized Telegram bot that connects your Git-backed journal to Claude AI CLI for intelligent analysis and queries.

## Quick Start

```bash
# 1. Configure your .env file with TELEGRAM_TOKEN and ALLOWED_USER_ID
# 2. Start the container
./run.sh

# 3. First-time only: authenticate Claude inside the container
docker exec -it journal-bot claude /login

# 4. Send /start to your bot on Telegram
```

## Features

### Core
- **Claude AI Analysis**: Query your journal through natural language using Claude Code CLI
- **Git Integration**: Automatically syncs with your journal repository before and after queries
- **Secure Access**: User ID whitelist prevents unauthorized access

### Privacy & Security
- **Auto-Deletion**: All messages automatically deleted after 24 hours (configurable via `MESSAGE_RETENTION_HOURS`)
- **Audit Logging**: Tracks all queries, commands, and unauthorized access attempts
- **Non-root Execution**: Bot runs as unprivileged user inside container
- **Container Isolation**: All operations happen within Docker with read-only mounts for sensitive files

### Conversation Modes
- **Single-shot Mode** (default): Each query is independent
- **Session Mode**: Enable multi-turn conversations with persistent context (set `MESSAGE_SESSION=true`, configurable expiry via `MESSAGE_SESSION_EXPIRY`)

### Sync Options
- **Auto Sync** (default): Commits and syncs before/after each query
- **Timer Sync**: Background sync at configurable intervals (set `JOURNAL_SYNC_MODE` to minutes)

### Operations
- **Health Monitoring**: Built-in diagnostics via `/health` command
- **Markdown Support**: Responses properly formatted for Telegram with emoji headings
- **Dockerized**: Isolated execution environment with proper permissions

## Prerequisites

- Raspberry Pi with Docker installed
- Git repository containing your journal at `~/Journal`
- Telegram account
- Anthropic subscription (Pro/Team/Max) OR API key

## Setup Instructions

### 1. Telegram Bot Creation

1. **Create the bot**:
   - Open Telegram and search for `@BotFather`
   - Send `/newbot` command
   - Follow prompts to name your bot (e.g., "My Journal Bot")
   - Copy the API token (format: `123456:ABC-DEF...`)

2. **Get your User ID**:
   - Search for `@userinfobot` on Telegram
   - Start the chat and copy your "Id" number (e.g., `123456789`)

### 2. Journal Repository

Ensure your journal repository exists at `~/Journal`:

```bash
cd ~
# If your journal isn't already here, clone it:
# git clone git@github.com:YOUR_USERNAME/JOURNAL_REPO.git ~/Journal
```

### 3. Configuration

1. **Configure environment variables**:
   Edit `.env` file with your actual values:
   ```bash
   # Telegram Secrets
   TELEGRAM_TOKEN=your_actual_bot_token_here
   ALLOWED_USER_ID=your_telegram_user_id_here

   # Anthropic Authentication (choose one method)
   # OPTION 1: Use subscription (recommended) - leave API key commented out
   # OPTION 2: Use API key - uncomment and add your API key
   # ANTHROPIC_API_KEY=sk-ant-api03-your_actual_key_here
   ```

2. **Authenticate with Claude Code CLI** (subscription users):
   ```bash
   # After starting the container, login inside it:
   docker exec -it journal-bot claude /login
   # Complete the browser authentication process
   # Credentials persist in ~/.claude/ (mounted volume)
   ```

### 4. Deployment

Run the deployment script:
```bash
./run.sh
```

The script will:
- ✅ Check journal directory exists
- 🧹 Clean up any old containers
- 🔨 Build the Docker image
- 🚀 Launch the bot with proper volume mounts
- ✅ Verify successful startup

## Usage

### Basic Commands

- `/start` - Initialize bot and run diagnostics
- `/health` - Run health check diagnostics
- **Any text message** - Query your journal through Claude AI

### Example Interactions

```
You: /start
Bot: 🤖 Journal Bot Online.
     ✅ Journal mounted and readable
     ✅ Claude CLI installed
     ✅ Git repo active
     Ready for queries.

You: What did I write about yesterday?
Bot: 🔄 Syncing & Thinking...
     [Claude AI analyzes your journal and provides insights]

You: Create a summary of my recent thoughts
Bot: 🔄 Syncing & Thinking...
     [Claude AI creates a summary based on recent entries]
```

## Verification Protocol

### Startup Test
After running `./run.sh`, verify you see:
- ✅ Journal mounted and readable
- ✅ Claude CLI installed
- ✅ Git repo active

### Telegram Test
1. Send `/start` to your bot
2. Expect "🤖 Journal Bot Online" with passing diagnostics

### Permissions Test
1. Ask bot: "Create a test file named hello.txt"
2. Check: `ls -l ~/Journal/hello.txt`
3. File should exist and be owned by your user (not root)

### Git Test
1. Ask bot: "What is the status of the repo?"
2. Claude should run `git status` and report back

## Troubleshooting

### Bot won't start
```bash
# Check logs
docker logs -f journal-bot

# Verify environment variables
cat .env
```

### Permission issues
- Ensure journal directory exists and is readable
- Check Docker volume mounts in run.sh

### Claude CLI issues
```bash
# Test Claude CLI manually
docker exec -it journal-bot claude --version
```

### Health monitoring
Send `/health` command to re-run diagnostics anytime.

## Security Features

- **User Whitelist**: Only your Telegram user ID can access the bot
- **Non-root Execution**: Bot runs as unprivileged user
- **Read-only Mounts**: SSH keys and git config are mounted read-only
- **Container Isolation**: All operations happen within Docker container

## File Structure

```
├── bot.py              # Main application logic
├── Dockerfile          # Container definition
├── requirements.txt    # Python dependencies
├── run.sh              # Deployment script
├── .env                # Configuration (DO NOT COMMIT)
└── .claude/            # Claude CLI credentials
```

## Maintenance

- **Update dependencies**: Modify `requirements.txt` and rebuild
- **Monitor logs**: `docker logs journal-bot`
- **Restart bot**: Re-run `./run.sh`
- **Update Claude CLI**: Rebuild Docker image to get latest version