"""
Journal Bot - A Telegram bot connecting a Git-backed journal to Claude AI CLI.

This bot enables natural language queries against a personal journal repository
using Claude Code CLI, with automatic Git synchronization and message retention.
"""

__version__ = "1.1.0"
__author__ = "AJ Anderson"

import os
import logging
import subprocess
import asyncio
import time
import json
from datetime import datetime, timedelta
from pathlib import Path
from telegram import Update
from telegram.ext import ApplicationBuilder, ContextTypes, CommandHandler, MessageHandler, filters
import telegramify_markdown
from telegramify_markdown.customize import get_runtime_config

# Configure emoji prefixes for headings in Telegram formatting
_tg_config = get_runtime_config()
_tg_config.markdown_symbol.head_level_1 = "📌"
_tg_config.markdown_symbol.head_level_2 = "📎"
_tg_config.markdown_symbol.head_level_3 = "◾"

# --- CONFIGURATION ---
TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
ALLOWED_USER_ID = int(os.getenv("ALLOWED_USER_ID"))
JOURNAL_PATH = "/Journal"
JOURNAL_SYNC_SCRIPT = "/Journal/_/scripts/commit-and-sync.sh"
MESSAGE_RETENTION_HOURS = 24

# Sync mode: "auto" = sync before/after each query, numeric = sync every N minutes
_sync_mode_raw = os.getenv("JOURNAL_SYNC_MODE", "auto")
if _sync_mode_raw.lower() == "auto":
    JOURNAL_SYNC_MODE = "auto"
    JOURNAL_SYNC_INTERVAL = None
else:
    try:
        JOURNAL_SYNC_MODE = "timer"
        JOURNAL_SYNC_INTERVAL = int(_sync_mode_raw)
    except ValueError:
        JOURNAL_SYNC_MODE = "auto"
        JOURNAL_SYNC_INTERVAL = None
AUDIT_LOG_PATH = Path("/app/data/audit.log")  # Persistent audit log (mounted volume)

# Session feature - enables multi-turn conversations with Claude
MESSAGE_SESSION = os.getenv("MESSAGE_SESSION", "false").lower() == "true"
MESSAGE_SESSION_EXPIRY = float(os.getenv("MESSAGE_SESSION_EXPIRY", "1"))  # Hours

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# --- TELEGRAM FORMATTING ---
def format_for_telegram(text: str) -> tuple[str, str | None]:
    """
    Convert markdown to Telegram MarkdownV2 format.
    Returns (formatted_text, parse_mode) tuple.
    Falls back to plain text if conversion fails.
    """
    try:
        converted = telegramify_markdown.markdownify(text)
        return (converted, "MarkdownV2")
    except Exception as e:
        logger.warning(f"Markdown conversion failed: {e}")
        return (text, None)

# --- AUDIT LOGGING ---
def audit_log(event_type: str, user_id: int, username: str = None, **kwargs):
    """
    Write a structured audit log entry. Each line is a JSON object.

    Event types:
    - QUERY: User sent a query to Claude
    - UNAUTHORIZED: Someone tried to access the bot
    - COMMAND: User executed a bot command (/start, /health, /audit)
    - ERROR: An error occurred during processing
    """
    entry = {
        "timestamp": datetime.now().isoformat(),
        "event": event_type,
        "user_id": user_id,
        "username": username,
        **kwargs
    }

    try:
        with open(AUDIT_LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        logger.error(f"Failed to write audit log: {e}")

    # Also log to standard logger for container logs
    logger.info(f"AUDIT: {event_type} | user={user_id} | {kwargs}")

def get_recent_audit_entries(count: int = 20) -> list:
    """Read the last N audit log entries."""
    if not AUDIT_LOG_PATH.exists():
        return []

    try:
        with open(AUDIT_LOG_PATH, "r") as f:
            lines = f.readlines()

        # Get last N entries
        recent = lines[-count:] if len(lines) >= count else lines
        return [json.loads(line) for line in recent]
    except Exception as e:
        logger.error(f"Failed to read audit log: {e}")
        return []

# --- MESSAGE TRACKING FOR AUTO-DELETION ---
tracked_messages = {}  # {(chat_id, message_id): timestamp}

# --- SESSION TRACKING FOR MULTI-TURN CONVERSATIONS ---
# {user_id: {"session_id": str, "last_active": datetime}}
user_sessions = {}

def get_active_session(user_id: int) -> str | None:
    """Get active session ID if exists and not expired, otherwise None."""
    logger.info(f"get_active_session called: user_id={user_id}, MESSAGE_SESSION={MESSAGE_SESSION}, sessions={list(user_sessions.keys())}")

    if not MESSAGE_SESSION:
        logger.info("Sessions disabled, returning None")
        return None

    session = user_sessions.get(user_id)
    if not session:
        logger.info(f"No session found for user {user_id}")
        return None

    # Check if session has expired
    expiry_time = session["last_active"] + timedelta(hours=MESSAGE_SESSION_EXPIRY)
    if datetime.now() > expiry_time:
        logger.info(f"Session expired for user {user_id}")
        del user_sessions[user_id]
        return None

    logger.info(f"Returning active session {session['session_id'][:8]}... for user {user_id}")
    return session["session_id"]

def update_session(user_id: int, session_id: str):
    """Store or update session for user."""
    user_sessions[user_id] = {
        "session_id": session_id,
        "last_active": datetime.now()
    }
    logger.info(f"Session STORED for user {user_id}: {session_id} (full ID)")
    logger.info(f"Current user_sessions: {user_sessions}")

def track_message(chat_id, message_id):
    """Track a message for automatic deletion."""
    tracked_messages[(chat_id, message_id)] = datetime.now()
    logger.debug(f"Tracking message {message_id} in chat {chat_id}")

async def delete_old_messages(application):
    """Background task to delete messages older than 24 hours and clean expired sessions."""
    while True:
        try:
            current_time = datetime.now()
            cutoff_time = current_time - timedelta(hours=MESSAGE_RETENTION_HOURS)

            messages_to_delete = []
            for (chat_id, message_id), timestamp in tracked_messages.items():
                if timestamp < cutoff_time:
                    messages_to_delete.append((chat_id, message_id))

            for chat_id, message_id in messages_to_delete:
                try:
                    await application.bot.delete_message(chat_id=chat_id, message_id=message_id)
                    del tracked_messages[(chat_id, message_id)]
                    logger.info(f"Deleted old message {message_id} from chat {chat_id}")
                except Exception as e:
                    # Message might already be deleted or not exist
                    logger.debug(f"Could not delete message {message_id}: {e}")
                    # Remove from tracking even if deletion failed
                    if (chat_id, message_id) in tracked_messages:
                        del tracked_messages[(chat_id, message_id)]

            # Clean up expired sessions (if session feature is enabled)
            if MESSAGE_SESSION:
                session_cutoff = current_time - timedelta(hours=MESSAGE_SESSION_EXPIRY)
                expired_users = [
                    user_id for user_id, session in user_sessions.items()
                    if session["last_active"] < session_cutoff
                ]
                for user_id in expired_users:
                    del user_sessions[user_id]
                    logger.info(f"Cleaned up expired session for user {user_id}")

            # Clean up every 10 minutes
            await asyncio.sleep(600)

        except Exception as e:
            logger.error(f"Error in delete_old_messages: {e}")
            await asyncio.sleep(600)  # Continue trying

async def background_sync():
    """Background task to sync journal on a timer (when JOURNAL_SYNC_MODE is numeric)."""
    if JOURNAL_SYNC_MODE != "timer" or JOURNAL_SYNC_INTERVAL is None:
        return  # Timer mode not enabled

    interval_seconds = JOURNAL_SYNC_INTERVAL * 60
    logger.info(f"🔄 Background sync started: every {JOURNAL_SYNC_INTERVAL} minutes")

    while True:
        try:
            await asyncio.sleep(interval_seconds)
            logger.info("Background sync triggered...")
            await sync_repo(silent=True)
        except Exception as e:
            logger.error(f"Error in background_sync: {e}")
            await asyncio.sleep(60)  # Wait a minute before retrying

# --- SELF-TESTING UTILITIES ---

def run_diagnostic():
    """Checks system health on startup and on demand."""
    results = []

    # Test 1: Journal Access
    if os.path.exists(JOURNAL_PATH) and os.access(JOURNAL_PATH, os.R_OK):
        results.append("✅ Journal mounted and readable")
    else:
        results.append("❌ Journal NOT accessible")

    # Test 2: Claude CLI
    try:
        # Check version to ensure it runs
        subprocess.run(["claude", "--version"], capture_output=True, check=True)
        results.append("✅ Claude CLI installed")
    except Exception:
        results.append("❌ Claude CLI missing or failing")

    # Test 3: Git Config
    try:
        subprocess.run(["git", "status"], cwd=JOURNAL_PATH, capture_output=True, check=True)
        results.append("✅ Git repo active")
    except Exception:
        results.append("❌ Not a valid git repo")

    # Test 4: Sync Script
    if os.path.exists(JOURNAL_SYNC_SCRIPT) and os.access(JOURNAL_SYNC_SCRIPT, os.X_OK):
        results.append("✅ Sync script available")
    else:
        results.append("⚠️ Sync script not found (using git pull fallback)")

    # Test 5: Sync Mode
    if JOURNAL_SYNC_MODE == "auto":
        results.append("🔄 Sync: before/after each query")
    else:
        results.append(f"🔄 Sync: every {JOURNAL_SYNC_INTERVAL} minutes")

    return "\n".join(results)

async def sync_repo(context=None, chat_id=None, silent=False):
    """
    Sync journal repo using commit-and-sync.sh script, with git pull fallback.

    Args:
        context: Telegram context for sending messages (optional)
        chat_id: Chat ID for sending messages (optional)
        silent: If True, don't send warning messages to chat

    Returns:
        bool: True if sync succeeded, False otherwise
    """
    async def send_warning(msg):
        """Send warning message if context available and not silent."""
        if context and chat_id and not silent:
            warning_msg = await context.bot.send_message(chat_id=chat_id, text=msg)
            track_message(chat_id, warning_msg.message_id)

    # Try the commit-and-sync script first
    if os.path.exists(JOURNAL_SYNC_SCRIPT) and os.access(JOURNAL_SYNC_SCRIPT, os.X_OK):
        try:
            logger.info("Running journal sync script...")
            result = subprocess.run(
                ["bash", JOURNAL_SYNC_SCRIPT],
                cwd=JOURNAL_PATH,
                capture_output=True,
                text=True,
                timeout=120  # Script may take longer due to Claude commit message generation
            )

            logger.info(f"Sync script: returncode={result.returncode}, stdout={result.stdout.strip()[:200]}")

            if result.returncode == 0:
                logger.info("Journal sync script completed successfully")
                return True
            else:
                logger.warning(f"Sync script failed: {result.stderr.strip()}")
                await send_warning(f"⚠️ Sync script warning: {result.stderr.strip()[:200]}")
                # Fall through to git pull fallback

        except subprocess.TimeoutExpired:
            logger.error("Sync script timed out after 120s")
            await send_warning("⚠️ Sync script timed out, falling back to git pull")
        except Exception as e:
            logger.error(f"Sync script failed: {e}")
            await send_warning(f"⚠️ Sync script error: {str(e)}, falling back to git pull")
    else:
        logger.info("Sync script not found or not executable, using git pull fallback")

    # Fallback: simple git pull
    try:
        result = subprocess.run(
            ["git", "pull"],
            cwd=JOURNAL_PATH,
            capture_output=True,
            text=True,
            timeout=30
        )
        logger.info(f"Git pull fallback: returncode={result.returncode}, stdout={result.stdout.strip()}")

        if result.returncode != 0 and "Already up to date" not in result.stdout:
            await send_warning(f"⚠️ Git Pull Warning:\n{result.stderr}")
        return True
    except Exception as e:
        logger.error(f"Git pull fallback failed: {e}")
        await send_warning(f"⚠️ Git Error: {str(e)}")
        return False

# --- HANDLERS ---

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id != ALLOWED_USER_ID:
        audit_log("UNAUTHORIZED", user.id, user.username, command="/start")
        return

    audit_log("COMMAND", user.id, user.username, command="/start")

    # Track user's message for deletion
    track_message(update.effective_chat.id, update.message.message_id)

    # Run diagnostics on start
    diag = run_diagnostic()
    session_status = f"💬 Conversations: {'Enabled (' + str(MESSAGE_SESSION_EXPIRY) + 'h context)' if MESSAGE_SESSION else 'Single-shot mode'}"
    sent_message = await context.bot.send_message(
        chat_id=update.effective_chat.id,
        text=f"🤖 Journal Bot Online.\n\n{diag}\n{session_status}\n\nReady for queries.\n\n⏰ All messages will be automatically deleted after 24 hours."
    )

    # Track bot's response for deletion
    track_message(update.effective_chat.id, sent_message.message_id)

async def health_check(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Manual trigger for self-test."""
    user = update.effective_user
    if user.id != ALLOWED_USER_ID:
        audit_log("UNAUTHORIZED", user.id, user.username, command="/health")
        return

    audit_log("COMMAND", user.id, user.username, command="/health")

    # Track user's message for deletion
    track_message(update.effective_chat.id, update.message.message_id)

    diag = run_diagnostic()
    sent_message = await context.bot.send_message(chat_id=update.effective_chat.id, text=diag)

    # Track bot's response for deletion
    track_message(update.effective_chat.id, sent_message.message_id)

async def audit_view(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """View recent audit log entries."""
    user = update.effective_user
    if user.id != ALLOWED_USER_ID:
        audit_log("UNAUTHORIZED", user.id, user.username, command="/audit")
        return

    audit_log("COMMAND", user.id, user.username, command="/audit")

    # Track user's message for deletion
    track_message(update.effective_chat.id, update.message.message_id)

    # Get count from args (default 10)
    try:
        count = int(context.args[0]) if context.args else 10
        count = min(count, 50)  # Cap at 50 entries
    except ValueError:
        count = 10

    entries = get_recent_audit_entries(count)

    if not entries:
        text = "📋 No audit entries found."
    else:
        lines = ["📋 **Recent Audit Log**\n"]
        for entry in entries:
            ts = entry.get("timestamp", "?")[:19]  # Trim to seconds
            event = entry.get("event", "?")
            uid = entry.get("user_id", "?")
            uname = entry.get("username") or "unknown"

            # Format based on event type
            if event == "QUERY":
                query_preview = entry.get("query", "")[:40]
                exec_time = entry.get("execution_time_sec", "?")
                lines.append(f"`{ts}` **QUERY** @{uname}\n  └ \"{query_preview}...\" ({exec_time}s)")
            elif event == "UNAUTHORIZED":
                action = entry.get("command") or entry.get("action", "?")
                lines.append(f"`{ts}` ⚠️ **UNAUTHORIZED** id={uid} @{uname}\n  └ Attempted: {action}")
            elif event == "COMMAND":
                cmd = entry.get("command", "?")
                lines.append(f"`{ts}` **CMD** @{uname} {cmd}")
            elif event == "ERROR":
                err = entry.get("error", "?")[:50]
                lines.append(f"`{ts}` ❌ **ERROR** @{uname}\n  └ {err}")
            else:
                lines.append(f"`{ts}` {event} | {uid}")

        text = "\n".join(lines)

    # Truncate if too long
    if len(text) > 3900:
        text = text[:3900] + "\n...(truncated)"

    sent_message = await context.bot.send_message(
        chat_id=update.effective_chat.id,
        text=text,
        parse_mode="Markdown"
    )
    track_message(update.effective_chat.id, sent_message.message_id)

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Main logic: Git Pull -> Claude Code -> Reply"""
    user = update.effective_user
    if user.id != ALLOWED_USER_ID:
        audit_log("UNAUTHORIZED", user.id, user.username,
                  action="message",
                  query_preview=update.message.text[:100] if update.message.text else None)
        return

    # Track user's message for deletion
    track_message(update.effective_chat.id, update.message.message_id)

    # User feedback
    status_text = "🔄 Syncing & Thinking..." if JOURNAL_SYNC_MODE == "auto" else "🤔 Thinking..."
    status_msg = await context.bot.send_message(chat_id=update.effective_chat.id, text=status_text)

    # Track status message for deletion
    track_message(update.effective_chat.id, status_msg.message_id)

    # 1. Pre-query sync (only in auto mode)
    if JOURNAL_SYNC_MODE == "auto":
        await sync_repo(context, update.effective_chat.id)

    # 2. Run Claude
    user_query = update.message.text
    start_time = time.perf_counter()  # Add timing start

    try:
        # Check for active session (if sessions enabled)
        active_session = get_active_session(user.id)

        # Build command based on session state
        if MESSAGE_SESSION:
            if active_session:
                # Resume existing session (no -p flag - query passed as positional arg)
                cmd = ["claude", "--resume", active_session, user_query, "--output-format", "json", "--dangerously-skip-permissions"]
                logger.info(f"Resuming session {active_session[:8]}... for user {user.id}")
            else:
                # Start new session
                cmd = ["claude", "-p", user_query, "--output-format", "json", "--dangerously-skip-permissions"]
                logger.info(f"Starting new session for user {user.id}")
        else:
            # Sessions disabled - original behavior
            cmd = ["claude", "-p", user_query, "--dangerously-skip-permissions"]

        logger.info(f"Starting Claude query: length={len(user_query)} chars")  # Log query start

        # Run blocking subprocess in a thread to prevent freezing the bot
        process = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=JOURNAL_PATH,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )

        stdout, stderr = await process.communicate()

        # Calculate and log execution metrics
        execution_time = time.perf_counter() - start_time
        raw_output = stdout.decode().strip()

        # Log Claude debug info (thinking process)
        if stderr:
            debug_output = stderr.decode().strip()
            logger.info(f"Claude debug info: {debug_output[:500]}...")  # Log first 500 chars of debug

        logger.info(f"Claude completed: {execution_time:.2f}s, output_size={len(raw_output)} chars, exit_code={process.returncode}")

        # Parse output based on session mode
        if MESSAGE_SESSION:
            # Parse JSON output to extract session_id and result
            output = raw_output  # Default fallback
            logger.info(f"Parsing JSON response, raw_output length: {len(raw_output)}")
            try:
                result_data = json.loads(raw_output)
                session_id = result_data.get("session_id")
                output = result_data.get("result", raw_output)
                logger.info(f"Parsed JSON: session_id={session_id}, result_length={len(output) if output else 0}")

                if session_id:
                    update_session(user.id, session_id)
                else:
                    logger.warning("No session_id in Claude JSON response")
            except json.JSONDecodeError as e:
                logger.warning(f"Failed to parse Claude JSON output: {e}")
                logger.warning(f"Raw output was: {raw_output[:500]}")
                output = raw_output  # Use raw output as fallback
        else:
            output = raw_output

        if not output:
            output = stderr.decode().strip() or "Empty response from Claude."

        # Truncate for Telegram limit (4096 chars)
        if len(output) > 3900:
            output = output[:3900] + "\n...(truncated)"
        # else:
        #     output += f"\n\n⏱️ {execution_time:.2f}s"

        formatted_output, parse_mode = format_for_telegram(output)
        await context.bot.edit_message_text(
            chat_id=update.effective_chat.id,
            message_id=status_msg.message_id,
            text=formatted_output,
            parse_mode=parse_mode
        )

        # Audit log the successful query
        audit_log("QUERY", user.id, user.username,
                  query=user_query,
                  query_length=len(user_query),
                  response_length=len(output),
                  execution_time_sec=round(execution_time, 2),
                  status="success",
                  exit_code=process.returncode)

        # Post-query sync: commit and push any changes Claude may have made (only in auto mode)
        if JOURNAL_SYNC_MODE == "auto":
            await sync_repo(context, update.effective_chat.id, silent=True)

    except Exception as e:
        execution_time = time.perf_counter() - start_time
        logger.error(f"Claude failed after {execution_time:.2f}s: {str(e)}")
        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=f"🔥 Error: {str(e)}")

        # Audit log the failed query
        audit_log("ERROR", user.id, user.username,
                  query=user_query,
                  query_length=len(user_query),
                  execution_time_sec=round(execution_time, 2),
                  status="error",
                  error=str(e))

if __name__ == '__main__':
    # Startup check
    print("--- STARTUP DIAGNOSTICS ---")
    print(run_diagnostic())
    print("---------------------------")

    # Log startup event
    audit_log("STARTUP", 0, None, message="Bot started")

    application = ApplicationBuilder().token(TELEGRAM_TOKEN).build()

    application.add_handler(CommandHandler('start', start))
    application.add_handler(CommandHandler('health', health_check))
    application.add_handler(CommandHandler('audit', audit_view))
    application.add_handler(MessageHandler(filters.TEXT & (~filters.COMMAND), handle_message))

    # Start the background tasks
    async def post_init(application):
        """Initialize background tasks after bot startup."""
        asyncio.create_task(delete_old_messages(application))
        if JOURNAL_SYNC_MODE == "timer":
            asyncio.create_task(background_sync())

    application.post_init = post_init

    logger.info(f"🗑️ Message auto-deletion enabled: {MESSAGE_RETENTION_HOURS} hours retention")
    if JOURNAL_SYNC_MODE == "auto":
        logger.info("🔄 Sync mode: auto (before/after each query)")
    else:
        logger.info(f"🔄 Sync mode: timer (every {JOURNAL_SYNC_INTERVAL} minutes)")
    if MESSAGE_SESSION:
        logger.info(f"💬 Session mode enabled: {MESSAGE_SESSION_EXPIRY}h expiry")
    else:
        logger.info("💬 Session mode disabled (single-shot queries)")
    application.run_polling()