#!/bin/bash
# ============================================================
# Auto Company — Cleanup Orphaned Claude Code Processes
# ============================================================
# Kills all redundant Auto Company Claude Code processes that
# are not the primary loop. Keeps only ONE active instance.
#
# Usage:
#   ./cleanup-orphaned.sh              # Dry-run (show what would be killed)
#   ./cleanup-orphaned.sh --kill       # Actually kill orphaned processes
#   ./cleanup-orphaned.sh --force      # Kill ALL Auto Company Claude processes
# ============================================================

set -euo pipefail

PROJECT_DIR="$HOME/projects/auto-company_test"
LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/cleanup-orphaned.log"

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Find all Auto Company Claude Code processes
# Pattern: claude -p "# Auto Company — Autonomous Loop Prompt"
find_auto_company_processes() {
    ps aux | grep -E 'claude.*Auto Company.*Autonomous Loop Prompt' | grep -v grep | awk '{print $2}'
}

# Get the primary loop PID from PID file (if exists and running)
get_primary_pid() {
    local pid_file="$PROJECT_DIR/.auto-loop.pid"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    return 1
}

# Count processes
count_processes() {
    find_auto_company_processes | wc -l | tr -d ' '
}

# Kill a process
kill_process() {
    local pid=$1
    local force=${2:-false}
    
    if [ "$force" = "true" ]; then
        kill -9 "$pid" 2>/dev/null && echo "  KILLED (SIGKILL) PID $pid" || echo "  FAILED to kill PID $pid"
    else
        kill -TERM "$pid" 2>/dev/null && echo "  SENT SIGTERM to PID $pid" || echo "  FAILED to signal PID $pid"
    fi
}

# Main cleanup logic
cleanup_orphaned() {
    local mode="${1:-dry-run}"
    local processes=$(find_auto_company_processes)
    local count=$(echo "$processes" | grep -c . || echo 0)
    local primary_pid=$(get_primary_pid 2>/dev/null || echo "")
    
    log "=== Cleanup Orphaned Auto Company Processes ==="
    log "Found $count Auto Company Claude Code processes"
    log "Primary PID (from .auto-loop.pid): ${primary_pid:-none}"
    log ""
    
    if [ "$count" -eq 0 ]; then
        log "No Auto Company processes found. Nothing to clean."
        return 0
    fi
    
    local killed=0
    local kept=0
    
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        
        # Get process info for logging
        local proc_info=$(ps -p "$pid" -o etime,cmd 2>/dev/null | tail -1 || echo "unknown")
        
        if [ -n "$primary_pid" ] && [ "$pid" = "$primary_pid" ]; then
            log "KEEP (primary): PID $pid - $proc_info"
            kept=$((kept + 1))
        else
            if [ "$mode" = "kill" ] || [ "$mode" = "force" ]; then
                kill_process "$pid" "$([ "$mode" = "force" ] && echo true || echo false)"
                killed=$((killed + 1))
            else
                log "ORPHAN (would kill): PID $pid - $proc_info"
            fi
        fi
    done <<< "$processes"
    
    log ""
    log "Summary: $kept kept, $killed killed (mode: $mode)"
    
    # Clean up stale PID file if primary is gone
    if [ -z "$primary_pid" ] && [ -f "$PROJECT_DIR/.auto-loop.pid" ]; then
        log "Cleaning up stale PID file"
        rm -f "$PROJECT_DIR/.auto-loop.pid"
    fi
    
    return 0
}

# Parse arguments
case "${1:-}" in
    --kill)
        cleanup_orphaned "kill"
        ;;
    --force)
        cleanup_orphaned "force"
        ;;
    --help|-h)
        echo "Usage:"
        echo "  ./cleanup-orphaned.sh              # Dry-run (show what would be killed)"
        echo "  ./cleanup-orphaned.sh --kill       # Actually kill orphaned processes"
        echo "  ./cleanup-orphaned.sh --force      # Kill ALL Auto Company Claude processes"
        ;;
    *)
        cleanup_orphaned "dry-run"
        ;;
esac
