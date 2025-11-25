# Implementation-Specific Notes

## Git Sync Strategy

The bot syncs the journal repository using `commit-and-sync.sh` with a configurable schedule.

### Sync Modes

Controlled by `JOURNAL_SYNC_MODE` environment variable:

| Value | Behavior |
|-------|----------|
| `auto` (default) | Sync before and after each Claude query |
| `5`, `10`, etc. | Sync on a timer every N minutes (background task) |

**Timer mode** is faster for queries since it skips per-request sync overhead. Use when you don't need immediate consistency.

**Auto mode** ensures the journal is always current before Claude reads it, and changes are pushed immediately after.

### Primary: `commit-and-sync.sh` Script

Located at `/Journal/_/scripts/commit-and-sync.sh`, this script performs a full git workflow:

1. `git add -A` - Stage all changes
2. `git commit` - Commit with AI-generated message via Claude
3. `git pull --rebase` - Pull remote changes
4. `git push` - Push to remote

### Fallback: Simple `git pull`

If the sync script is unavailable or fails, the bot falls back to a basic `git pull`. This ensures the bot remains functional even without the script.

Fallback triggers:
- Script not found at expected path
- Script not executable
- Script times out (120s limit)
- Script returns non-zero exit code

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `JOURNAL_SYNC_MODE` | `auto` | `auto` or minutes interval |
| `JOURNAL_SYNC_SCRIPT` | `/Journal/_/scripts/commit-and-sync.sh` | Path to sync script |

Internal timeouts:
- Script timeout: 120 seconds (longer due to Claude commit message generation)
- Fallback timeout: 30 seconds

### Diagnostics

The `/start` and `/health` commands show sync script availability and current sync mode.

## Telegram Message Formatting

Claude responses use standard markdown (e.g., `**bold**`) which Telegram doesn't render natively. The bot converts Claude's output to Telegram's MarkdownV2 format.

### Library

Uses [`telegramify-markdown`](https://github.com/sudoskys/telegramify-markdown) for conversion.

### Configuration

Heading symbols are customized via `get_runtime_config()` in `bot.py`:
- `# Heading` → 📌 **Heading**
- `## Heading` → 📎 **Heading**
- `### Heading` → ◾ **Heading**

### Supported Formatting

- **Bold**, *italic*, __underline__, ~~strikethrough~~
- `inline code` and code blocks
- Block quotes
- Links and lists
- ||Spoilers||

### Fallback Behavior

If markdown conversion fails, the bot sends plain text (no `parse_mode`) to ensure delivery. Logged as warning: `"Markdown conversion failed: {error}"`

### Key Function

`format_for_telegram(text)` returns `(formatted_text, parse_mode)` tuple. Used in `handle_message` before `edit_message_text()`.
