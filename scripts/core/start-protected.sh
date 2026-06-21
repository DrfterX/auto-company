#!/bin/bash
# ============================================================
# Auto Company — Start Loop with Lock Protection
# ============================================================
# Starts the auto-loop only if no other instance is running.
# Uses a lock file to prevent multiple simultaneous instances.
#
# Usage:
#   ./start-protected.sh              # Start with lock check
#   ./start-protected.sh --force      # Force start (kill existing)
# ============================================================

set -euo pipefail

PROJECT_DIR="$HOME/projects/auto-company_test"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="$PROJECT_DIR/.auto-loop.lock"
PID_FILE="$PROJECT_DIR/.auto-loop.pid"

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1"
}

# Check if another instance is running
check_running() {
    # Check lock file
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "$lock_pid"
            return 0
        fi
    fi
    
    # Check PID file
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    
    # Check for running claude processes with Auto Company prompt
    local running_pids=$(ps aux | grep -E 'claude.*Auto Company.*Autonomous Loop Prompt' | grep -v grep | awk '{print $2}' | head -1)
    if [ -n "$running_pids" ]; then
        echo "$running_pids"
        return 0
    fi
    
    return 1
}

# Acquire lock
acquire_lock() {
    local pid=$$
    echo "$pid" > "$LOCK_FILE"
    log "Lock acquired: PID $pid"
}

# Release lock
release_lock() {
    rm -f "$LOCK_FILE"
    log "Lock released"
}

# Kill existing process
kill_existing() {
    local pid=$1
    log "Killing existing process PID $pid..."
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$LOCK_FILE" "$PID_FILE"
    log "Existing process terminated"
}

# Main
case "${1:-}" in
    --force)
        log "Force mode: checking for existing instance..."
        local existing=$(check_running 2>/dev/null || echo "")
        if [ -n "$existing" ]; then
            kill_existing "$existing"
        fi
        ;;
    --help|-h)
        echo "Usage:"
        echo "  ./start-protected.sh              # Start with lock check"
        echo "  ./start-protected.sh --force      # Force start (kill existing)"
        exit 0
        ;;
esac

# Check if already running
existing=$(check_running 2>/dev/null || echo "")
if [ -n "$existing" ]; then
    log "ERROR: Auto Company loop is already running (PID $existing)"
    log "Use --force to kill existing and restart, or run cleanup-orphaned.sh"
    exit 1
fi

# Acquire lock and start
acquire_lock

# Trap to release lock on exit
trap release_lock EXIT

log "Starting Auto Company loop..."
log "  Lock file: $LOCK_FILE"
log "  Project: $PROJECT_DIR"

cd "$PROJECT_DIR"

# Run the actual auto-loop
exec "$SCRIPT_DIR/auto-loop.sh" 2>&1 | tee -a "$PROJECT_DIR/logs/auto-loop-protected.log"
