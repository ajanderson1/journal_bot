#!/bin/bash
#
# commit-and-sync.sh - Automated Git Sync for Journal Vault
# Version: 1.1.0
#
# ============================================================================
# DESCRIPTION
# ============================================================================
# Automates the complete git synchronization workflow for an Obsidian journal
# vault. Designed for unattended operation - only fails for truly catastrophic
# issues that require human intervention.
#
# ============================================================================
# WORKFLOW
# ============================================================================
#
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │ PHASE 0: INITIALIZATION                                              │
#   │   • Parse command-line arguments (--dry-run, --help, --version)      │
#   │   • Rotate log file if exceeds 1000 lines                            │
#   │   • Detect and clean up stale rebase state from crashed syncs        │
#   │   • Configure git for optimal auto-resolution                        │
#   │   • Verify we're on a branch (not detached HEAD)                     │
#   └──────────────────────────────────────────────────────────────────────┘
#                                      │
#                                      ▼
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │ PHASE 1: STAGE                                                       │
#   │   • git add -A (stage all changes: new, modified, deleted)           │
#   └──────────────────────────────────────────────────────────────────────┘
#                                      │
#                                      ▼
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │ PHASE 2: COMMIT                                                      │
#   │   • If staged changes exist:                                         │
#   │     - Generate commit message via Claude CLI (30s timeout)           │
#   │     - Fallback: "vault backup: YYYY-MM-DD HH:MM:SS"                  │
#   │     - Execute commit                                                 │
#   │   • If no changes: skip                                              │
#   └──────────────────────────────────────────────────────────────────────┘
#                                      │
#                                      ▼
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │ PHASE 3: PULL + REBASE + AUTO-RESOLUTION                             │
#   │   • Attempt: git pull --rebase (with network retry)                  │
#   │   • On conflict, apply resolution strategy:                          │
#   │       *.md files      → Union merge (preserve both sides)            │
#   │       .obsidian/*     → Keep LOCAL (ours)                            │
#   │       All other files → Keep REMOTE (theirs)                         │
#   │   • Continue rebase after resolution (up to 3 conflict rounds)       │
#   │   • On unresolvable conflict: abort rebase, exit with error          │
#   └──────────────────────────────────────────────────────────────────────┘
#                                      │
#                                      ▼
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │ PHASE 4: PUSH                                                        │
#   │   • git push (with network retry: 3 attempts, exponential backoff)   │
#   │   • Log success/failure                                              │
#   └──────────────────────────────────────────────────────────────────────┘
#
# ============================================================================
# USAGE
# ============================================================================
#   ./_/scripts/commit-and-sync.sh [OPTIONS]
#
#   Options:
#     -n, --dry-run    Show what would be executed without making changes
#     -h, --help       Display this help message
#     -v, --version    Display version information
#
# ============================================================================
# DEPENDENCIES
# ============================================================================
#   • git          - Version control
#   • claude       - Claude CLI for AI commit messages (optional, has fallback)
#   • timeout/gtimeout - For Claude CLI timeout (optional, has fallback)
#
# ============================================================================
# EXIT CODES
# ============================================================================
#   0  - Success
#   1  - Error (detached HEAD, unresolvable conflicts, network failure)
#
# ============================================================================
# CONFIGURATION
# ============================================================================
# The script automatically configures these git settings locally:
#   • rerere.enabled=true        - Remember conflict resolutions
#   • rerere.autoupdate=true     - Auto-stage rerere resolutions
#   • merge.conflictstyle=diff3  - Show base in conflict markers
#   • pull.rebase=true           - Always rebase on pull
#   • rebase.autostash=true      - Auto-stash dirty working directory
#   • merge.ours.driver=true     - Enable "ours" merge driver
#
# For optimal markdown handling, add to .gitattributes:
#   *.md merge=union
#
# ============================================================================
# CHANGELOG
# ============================================================================
# v1.1.0 (2025-11-27)
#   • Added --dry-run mode for testing without making changes
#   • Added 30-second timeout for Claude CLI to prevent hangs
#   • Added log rotation (keeps last 500 lines when exceeding 1000)
#   • Added stale rebase detection and auto-cleanup at startup
#   • Added --help and --version flags
#   • Improved documentation
#
# v1.0.0 (2025-11-26)
#   • Initial release with auto-conflict resolution
#   • AI-generated commit messages via Claude CLI
#   • Network retry with exponential backoff
#
# ============================================================================

set -e

# =============================================================================
# CONSTANTS & CONFIGURATION
# =============================================================================

VERSION="1.1.0"
SCRIPT_NAME="commit-and-sync.sh"

# Timeouts and limits
CLAUDE_TIMEOUT=30           # Seconds to wait for Claude CLI
MAX_LOG_LINES=1000          # Rotate log when exceeding this
KEEP_LOG_LINES=500          # Lines to keep after rotation
MAX_RETRY_ATTEMPTS=3        # Network retry attempts
INITIAL_RETRY_DELAY=2       # Initial retry delay in seconds

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GREY='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Paths
JOURNAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_FILE="$JOURNAL_DIR/_/scripts/sync.log"

# Runtime flags
DRY_RUN=false

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Display help message
show_help() {
    cat << EOF
${BOLD}$SCRIPT_NAME${NC} v$VERSION - Automated Git Sync for Journal Vault

${BOLD}USAGE${NC}
    ./_/scripts/$SCRIPT_NAME [OPTIONS]

${BOLD}OPTIONS${NC}
    -n, --dry-run    Show what would be executed without making changes
    -h, --help       Display this help message
    -v, --version    Display version information

${BOLD}DESCRIPTION${NC}
    Automates the complete git sync workflow:
    1. Stage all changes (git add -A)
    2. Commit with AI-generated message (Claude CLI with fallback)
    3. Pull with rebase (auto-resolving conflicts)
    4. Push to remote

${BOLD}CONFLICT RESOLUTION${NC}
    *.md files      → Union merge (keep both sides' content)
    .obsidian/*     → Keep local version
    Other files     → Keep remote version

${BOLD}EXAMPLES${NC}
    # Normal sync
    ./_/scripts/$SCRIPT_NAME

    # Preview what would happen
    ./_/scripts/$SCRIPT_NAME --dry-run

EOF
}

# Display version
show_version() {
    echo "$SCRIPT_NAME v$VERSION"
}

# Logging function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$DRY_RUN" = true ]; then
        echo "[$timestamp] [DRY-RUN] $1" >> "$LOG_FILE"
    else
        echo "[$timestamp] $1" >> "$LOG_FILE"
    fi
}

# Rotate log file if it exceeds maximum lines
rotate_log() {
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi

    local line_count=$(wc -l < "$LOG_FILE" | tr -d ' ')

    if [ "$line_count" -gt "$MAX_LOG_LINES" ]; then
        echo -e "${GREY}Rotating log file (${line_count} lines > ${MAX_LOG_LINES})...${NC}"
        tail -n "$KEEP_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "LOG ROTATED: Kept last $KEEP_LOG_LINES entries (was $line_count)"
    fi
}

# Check for and clean up stale rebase state
check_stale_rebase() {
    local rebase_merge="$JOURNAL_DIR/.git/rebase-merge"
    local rebase_apply="$JOURNAL_DIR/.git/rebase-apply"

    if [ -d "$rebase_merge" ] || [ -d "$rebase_apply" ]; then
        echo -e "${YELLOW}Warning: Stale rebase state detected from previous run${NC}"
        log "WARNING: Stale rebase state found"

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY-RUN] Would abort stale rebase${NC}"
            return 0
        fi

        echo -e "${GREY}Cleaning up stale rebase...${NC}"
        git rebase --abort 2>/dev/null || true

        # Verify cleanup succeeded
        if [ -d "$rebase_merge" ] || [ -d "$rebase_apply" ]; then
            echo -e "${RED}Could not clear stale rebase state${NC}"
            echo "Manual intervention required. Try:"
            echo "  rm -rf $rebase_merge $rebase_apply"
            log "FAILED: Could not clear stale rebase state"
            exit 1
        fi

        echo -e "${GREEN}Stale rebase state cleared${NC}"
        log "Cleared stale rebase state"
    fi
}

# Run git commands with grey output
git_grey() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] git $*${NC}"
        return 0
    fi

    echo -ne "${GREY}"
    git "$@" 2>&1
    local exit_code=$?
    echo -ne "${NC}"
    return $exit_code
}

# Execute command (or show in dry-run mode)
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] $*${NC}"
        return 0
    fi
    "$@"
}

# Retry function for network operations with exponential backoff
retry() {
    local max_attempts=$MAX_RETRY_ATTEMPTS
    local attempt=1
    local delay=$INITIAL_RETRY_DELAY

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo -e "${YELLOW}Attempt $attempt failed, retrying in ${delay}s...${NC}"
            sleep $delay
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

# Generate commit message with timeout protection
# Falls back to timestamp-based message if Claude CLI fails or times out
generate_commit_message() {
    local diff="$1"
    local fallback="vault backup: $(date '+%Y-%m-%d %H:%M:%S')"
    local prompt="Generate a concise git commit message for these changes. Output only the message, no other text. Example: 'Add test content and notes to Inbox'"
    local result=""

    # Check if claude CLI is available
    if ! command -v claude &>/dev/null; then
        echo "$fallback"
        return 0
    fi

    # Try with timeout command (Linux) or gtimeout (macOS with coreutils)
    if command -v timeout &>/dev/null; then
        result=$(echo "$diff" | timeout "$CLAUDE_TIMEOUT" claude -p "$prompt" 2>/dev/null) || true
    elif command -v gtimeout &>/dev/null; then
        result=$(echo "$diff" | gtimeout "$CLAUDE_TIMEOUT" claude -p "$prompt" 2>/dev/null) || true
    else
        # Fallback: background process with manual timeout
        local tmpfile=$(mktemp)
        local pid

        (echo "$diff" | claude -p "$prompt" > "$tmpfile" 2>/dev/null) &
        pid=$!

        # Wait with timeout
        local elapsed=0
        while kill -0 $pid 2>/dev/null && [ $elapsed -lt $CLAUDE_TIMEOUT ]; do
            sleep 1
            ((elapsed++))
        done

        # Kill if still running (timed out)
        if kill -0 $pid 2>/dev/null; then
            kill $pid 2>/dev/null
            wait $pid 2>/dev/null || true
            log "WARNING: Claude CLI timed out after ${CLAUDE_TIMEOUT}s"
            rm -f "$tmpfile"
            echo "$fallback"
            return 0
        fi

        wait $pid 2>/dev/null || true
        result=$(cat "$tmpfile" 2>/dev/null) || true
        rm -f "$tmpfile"
    fi

    # Return result or fallback
    if [ -n "$result" ] && [ ${#result} -gt 5 ]; then
        echo "$result"
    else
        echo "$fallback"
    fi
}

# Resolve conflicts automatically based on file type
resolve_conflicts() {
    local resolved_count=0
    local unresolved_files=()

    # Get list of conflicted files
    local conflicted_files=$(git diff --name-only --diff-filter=U)

    if [ -z "$conflicted_files" ]; then
        return 0
    fi

    echo -e "${YELLOW}Auto-resolving conflicts...${NC}"

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        if [ "$DRY_RUN" = true ]; then
            if [[ "$file" == *.md ]]; then
                echo -e "${YELLOW}[DRY-RUN] Would resolve (union): $file${NC}"
            elif [[ "$file" == .obsidian/* ]]; then
                echo -e "${YELLOW}[DRY-RUN] Would resolve (local): $file${NC}"
            else
                echo -e "${YELLOW}[DRY-RUN] Would resolve (remote): $file${NC}"
            fi
            ((resolved_count++))
            continue
        fi

        if [[ "$file" == *.md ]]; then
            # Markdown: union merge already applied by .gitattributes
            # Just accept the merge result (which has both sides' content)
            git add "$file"
            log "AUTO-RESOLVED (union): $file"
            echo -e "${GREY}  Resolved (union): $file${NC}"
            ((resolved_count++))

        elif [[ "$file" == .obsidian/* ]]; then
            # Obsidian metadata: keep local version
            git checkout --ours "$file"
            git add "$file"
            log "AUTO-RESOLVED (ours): $file"
            echo -e "${GREY}  Resolved (local): $file${NC}"
            ((resolved_count++))

        else
            # Other files: try to accept theirs (prefer remote)
            if git checkout --theirs "$file" 2>/dev/null; then
                git add "$file"
                log "AUTO-RESOLVED (theirs): $file"
                echo -e "${GREY}  Resolved (remote): $file${NC}"
                ((resolved_count++))
            else
                unresolved_files+=("$file")
            fi
        fi
    done <<< "$conflicted_files"

    if [ ${#unresolved_files[@]} -gt 0 ]; then
        echo -e "${RED}Could not auto-resolve:${NC}"
        for f in "${unresolved_files[@]}"; do
            echo "  - $f"
        done
        log "UNRESOLVED: ${unresolved_files[*]}"
        return 1
    fi

    [ $resolved_count -gt 0 ] && echo -e "${GREEN}Auto-resolved $resolved_count conflict(s)${NC}"
    return 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# MAIN SCRIPT
# =============================================================================

cd "$JOURNAL_DIR" || exit 1

# Phase 0: Initialization
if [ "$DRY_RUN" = true ]; then
    echo -e "${BOLD}${YELLOW}=== DRY-RUN MODE ===${NC}"
    echo -e "${GREY}No changes will be made. Showing what would be executed.${NC}"
    echo ""
fi

# Rotate log if needed
rotate_log

# Check for stale rebase state
check_stale_rebase

# Ensure git config is set up for auto-resolution
git config --local rerere.enabled true 2>/dev/null || true
git config --local rerere.autoupdate true 2>/dev/null || true
git config --local merge.conflictstyle diff3 2>/dev/null || true
git config --local pull.rebase true 2>/dev/null || true
git config --local rebase.autostash true 2>/dev/null || true
git config --local merge.ours.driver true 2>/dev/null || true

# Check if on a branch
if ! git symbolic-ref HEAD &>/dev/null; then
    echo -e "${RED}Error: Not on a branch (detached HEAD state)${NC}"
    echo "Run: git checkout main"
    log "FAILED: Detached HEAD state"
    exit 1
fi

# Show workflow overview
echo -e "${BOLD}Git Sync Workflow:${NC}"
echo "  1. Stage all changes"
echo "  2. Commit with AI message (if changes exist)"
echo "  3. Pull with rebase (auto-resolve conflicts)"
echo "  4. Push to remote"
echo ""

echo -e "${GREEN}Starting git sync...${NC}"
log "Starting sync"

# Phase 1: Stage all changes
echo "Step 1/4: Staging all changes..."
git_grey add -A

if [ "$DRY_RUN" = true ]; then
    DIFF=$(git diff --staged 2>/dev/null || git diff)
else
    DIFF=$(git diff --staged)
fi

# Phase 2: Commit local changes (if any)
echo "Step 2/4: Committing local changes..."
if [ "$DRY_RUN" = true ]; then
    if [ -n "$DIFF" ]; then
        MESSAGE=$(generate_commit_message "$DIFF")
        echo -e "${YELLOW}[DRY-RUN] Would commit with message: ${NC}$MESSAGE"
    else
        echo -e "${YELLOW}No local changes to commit.${NC}"
    fi
elif git diff --staged --quiet; then
    echo -e "${YELLOW}No local changes to commit.${NC}"
else
    MESSAGE=$(generate_commit_message "$DIFF")
    git_grey commit -m "$MESSAGE"
    log "Committed: $MESSAGE"
fi

# Phase 3: Pull and rebase with conflict resolution
echo "Step 3/4: Pulling latest changes..."

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Would execute: git pull --rebase${NC}"
    echo -e "${YELLOW}[DRY-RUN] Would auto-resolve any conflicts${NC}"
else
    pull_succeeded=false
    max_rebase_attempts=3
    rebase_attempt=0

    while [ $rebase_attempt -lt $max_rebase_attempts ] && [ "$pull_succeeded" = false ]; do
        if retry git_grey pull --rebase; then
            pull_succeeded=true
        else
            ((rebase_attempt++))

            # Check if we're in a rebase state with conflicts
            if [ -d "$JOURNAL_DIR/.git/rebase-merge" ] || [ -d "$JOURNAL_DIR/.git/rebase-apply" ]; then
                echo -e "${YELLOW}Rebase conflict detected, attempting auto-resolution...${NC}"

                if resolve_conflicts; then
                    # Try to continue rebase
                    if git rebase --continue 2>/dev/null; then
                        pull_succeeded=true
                        echo -e "${GREEN}Rebase continued successfully after auto-resolution${NC}"
                    else
                        # Check for more conflicts
                        if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
                            continue  # Try resolving again
                        fi
                    fi
                else
                    # Could not auto-resolve - abort and fail
                    echo -e "${RED}Could not auto-resolve all conflicts${NC}"
                    git rebase --abort 2>/dev/null || true
                    log "FAILED: Unresolvable conflicts"
                    exit 1
                fi
            else
                # Not a conflict issue - likely network error
                if [ $rebase_attempt -lt $max_rebase_attempts ]; then
                    echo -e "${YELLOW}Pull failed, retrying...${NC}"
                    sleep 2
                else
                    echo -e "${RED}Pull failed after $max_rebase_attempts attempts${NC}"
                    log "FAILED: Pull failed after retries"
                    exit 1
                fi
            fi
        fi
    done
fi

# Phase 4: Push
echo "Step 4/4: Pushing to remote..."
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Would execute: git push${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}=== DRY-RUN COMPLETE ===${NC}"
    echo -e "${GREY}No changes were made. Run without --dry-run to execute.${NC}"
    log "DRY-RUN completed"
else
    if retry git_grey push; then
        echo -e "${GREEN}✓ Git sync completed successfully!${NC}"
        log "SUCCESS"
    else
        echo -e "${RED}Push failed after retries${NC}"
        log "FAILED: Push failed after retries"
        exit 1
    fi
fi
