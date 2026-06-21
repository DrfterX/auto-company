#!/bin/bash
# ============================================================
# Auto Company — Start with SenseNova Model
# ============================================================
# Starts the auto-loop using sensenova-6.7-flash-lite via
# the SenseNova auth proxy (127.0.0.1:8082).
#
# Usage:
#   ./start-sensenova.sh              # Start with SenseNova model
#   ./start-sensenova.sh --daemon     # Install as launchd daemon
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# SenseNova proxy settings
export ANTHROPIC_BASE_URL="http://127.0.0.1:8082"
export MODEL="sensenova-6.7-flash-lite"
export CLAUDE_PERMISSION_MODE="bypassPermissions"
export ENGINE="claude"
export CYCLE_TIMEOUT_SECONDS="1200"
export LOOP_INTERVAL="60"

# Ensure proxy is running
if ! curl -s http://127.0.0.1:8082/health >/dev/null 2>&1; then
    echo "WARNING: SenseNova proxy not running at 127.0.0.1:8082"
    echo "Starting proxy in background..."
    cd ~/.hermes/scripts
    python3 sense-auth-proxy.py 8082 &
    sleep 2
fi

echo "Starting Auto Company with SenseNova..."
echo "  Model: sensenova-6.7-flash-lite"
echo "  API:   http://127.0.0.1:8082"
echo "  Interval: ${LOOP_INTERVAL}s"
echo ""

cd "$PROJECT_DIR"
exec ./scripts/core/auto-loop.sh 2>&1 | tee -a "$PROJECT_DIR/logs/auto-loop-sensenova.log"
