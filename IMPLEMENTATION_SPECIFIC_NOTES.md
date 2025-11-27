# Implementation-Specific Notes

## Git Sync Strategy

The bot syncs the journal repository using `commit-and-sync.sh` (v1.1.0) with a configurable schedule.

### Sync Modes

Controlled by `JOURNAL_SYNC_MODE` environment variable:

| Value | Behavior |
|-------|----------|
| `auto` (default) | Sync before and after each Claude query |
| `5`, `10`, etc. | Sync on a timer every N minutes (background task) |

**Timer mode** is faster for queries since it skips per-request sync overhead. Use when you don't need immediate consistency.

**Auto mode** ensures the journal is always current before Claude reads it, and changes are pushed immediately after.

### Primary: `commit-and-sync.sh` Script (v1.1.0)

Located at `/Journal/_/scripts/commit-and-sync.sh`, this script performs a full git workflow:

**Phase 0: Initialization**
- Parse CLI arguments (`--dry-run`, `--help`, `--version`)
- Rotate log file if >1000 lines (keeps last 500)
- Detect and clean up stale rebase state from crashed syncs
- Configure git for optimal auto-resolution (rerere, autostash, etc.)
- Verify on a branch (not detached HEAD)

**Phase 1: Stage**
- `git add -A` - Stage all changes

**Phase 2: Commit**
- Generate commit message via Claude CLI (30s timeout)
- Fallback message: `vault backup: YYYY-MM-DD HH:MM:SS`

**Phase 3: Pull + Rebase + Auto-Resolution**
- `git pull --rebase` with network retry (3 attempts, exponential backoff)
- Auto-resolve conflicts by file type:
  - `*.md` files → Union merge (preserve both sides)
  - `.obsidian/*` → Keep LOCAL (ours)
  - All other files → Keep REMOTE (theirs)
- Continue rebase after resolution (up to 3 conflict rounds)

**Phase 4: Push**
- `git push` with network retry

### Script Options

```bash
./_/scripts/commit-and-sync.sh [OPTIONS]

Options:
  -n, --dry-run    Show what would be executed without making changes
  -h, --help       Display help message
  -v, --version    Display version (1.1.0)
```

### Fallback: Simple `git pull`

If the sync script is unavailable or fails, the bot falls back to a basic `git pull`. This ensures the bot remains functional even without the script.

Fallback triggers:
- Script not found at expected path
- Script not executable
- Script times out (120s limit)
- Script returns non-zero exit code
- Unresolvable conflicts (script exits with code 1)

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `JOURNAL_SYNC_MODE` | `auto` | `auto` or minutes interval |
| `JOURNAL_SYNC_SCRIPT` | `/Journal/_/scripts/commit-and-sync.sh` | Path to sync script |

**Script internal settings:**
| Setting | Value | Description |
|---------|-------|-------------|
| Claude timeout | 30s | Max wait for AI commit message |
| Network retries | 3 | Attempts with exponential backoff |
| Log rotation | 1000 lines | Rotates when exceeded, keeps 500 |
| Conflict rounds | 3 | Max rebase conflict resolution attempts |

**Bot-side timeouts:**
- Script timeout: 120 seconds
- Fallback timeout: 30 seconds

### Diagnostics

The `/start` and `/health` commands show sync script availability and current sync mode.

The script writes to `/_/scripts/sync.log` with timestamped entries for each operation.

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
