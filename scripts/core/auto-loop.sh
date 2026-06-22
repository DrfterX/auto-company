#!/bin/bash
# ============================================================
# Auto Company — 24/7 Autonomous Loop
# Mod: Self-manage quota avoidance (pause 4h after 450 cycles)
#   - Auto pause 14400s when approaching limit (≥450 cycles in ~4h)
#   - Reset counter on resume
# ============================================================


# Loop settings (all overridable via env vars)
ENGINE="${ENGINE:-claude}"
ENGINE="$(echo "$ENGINE" | tr '[:upper:]' '[:lower:]')"
MODEL="${MODEL:-}"
MODEL_LABEL="${MODEL:-config-default}"
CLAUDE_BIN="${CLAUDE_BIN:-}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
CODEX_BIN="${CODEX_BIN:-}"
CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE:-danger-full-access}"
LOOP_INTERVAL="${LOOP_INTERVAL:-30}"
CYCLE_TIMEOUT_SECONDS="${CYCLE_TIMEOUT_SECONDS:-900}"
MAX_CONSECUTIVE_ERRORS="${MAX_CONSECUTIVE_ERRORS:-5}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-300}"
LIMIT_WAIT_SECONDS="${LIMIT_WAIT_SECONDS:-3600}"
MAX_LOGS="${MAX_LOGS:-200}"
AUTO_LOOP_PROTECT_GITIGNORE="${AUTO_LOOP_PROTECT_GITIGNORE:-1}"
WARMUP_TIMEOUT_SECONDS="${WARMUP_TIMEOUT_SECONDS:-300}"
WARMUP_CYCLES="${WARMUP_CYCLES:-0}"
RESOLVED_ENGINE_BIN=""

# === Resolve project root (always relative to this script) ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LOG_DIR="$PROJECT_DIR/logs"
CONSENSUS_FILE="$PROJECT_DIR/memories/consensus.md"
PROMPT_FILE="$PROJECT_DIR/PROMPT.md"
PID_FILE="$PROJECT_DIR/.auto-loop.pid"
STATE_FILE="$PROJECT_DIR/.auto-loop-state"
CRON_STATE_FILE="$PROJECT_DIR/.cron-state.json"

# Loop settings (all overridable via env vars)
ENGINE="${ENGINE:-claude}"
ENGINE="$(echo "$ENGINE" | tr '[:upper:]' '[:lower:]')"
MODEL="${MODEL:-}"
MODEL_LABEL="${MODEL:-config-default}"
CLAUDE_BIN="${CLAUDE_BIN:-}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
CODEX_BIN="${CODEX_BIN:-}"
CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE:-danger-full-access}"
LOOP_INTERVAL="${LOOP_INTERVAL:-30}"
CYCLE_TIMEOUT_SECONDS="${CYCLE_TIMEOUT_SECONDS:-900}"
MAX_CONSECUTIVE_ERRORS="${MAX_CONSECUTIVE_ERRORS:-5}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-300}"
LIMIT_WAIT_SECONDS="${LIMIT_WAIT_SECONDS:-3600}"
MAX_LOGS="${MAX_LOGS:-200}"
AUTO_LOOP_PROTECT_GITIGNORE="${AUTO_LOOP_PROTECT_GITIGNORE:-1}"
WARMUP_TIMEOUT_SECONDS="${WARMUP_TIMEOUT_SECONDS:-300}"
WARMUP_CYCLES="${WARMUP_CYCLES:-0}"
RESOLVED_ENGINE_BIN=""

if [ "$ENGINE" != "claude" ] && [ "$ENGINE" != "codex" ] && [ "$ENGINE" != "engine" ]; then
    echo "Error: ENGINE must be 'claude', 'codex', or 'engine' (received: '$ENGINE')."
    exit 1
fi

# Keep Agent Teams compatibility for legacy prompts/config.
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

# === Functions ===

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[$timestamp] $1"
    echo "$msg" >> "$LOG_DIR/auto-loop.log"
    if [ -t 1 ]; then
        echo "$msg"
    fi
}

log_cycle() {
    local cycle_num=$1
    local status=$2
    local msg=$3
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] Cycle #$cycle_num [$status] $msg" >> "$LOG_DIR/auto-loop.log"
    if [ -t 1 ]; then
        echo "[$timestamp] Cycle #$cycle_num [$status] $msg"
    fi
}

check_usage_limit() {
    local output="$1"
    if echo "$output" | grep -qi "usage limit\|rate limit\|too many requests\|resource_exhausted\|overloaded\|quota\|429\|billing\|insufficient credits\|ECONNRESET\|connection reset\|connection refused\|ENOTFOUND"; then
        return 0
    fi
    return 1
}

check_stop_requested() {
    if [ -f "$PROJECT_DIR/.auto-loop-stop" ]; then
        rm -f "$PROJECT_DIR/.auto-loop-stop"
        return 0
    fi
    return 1
}

save_state() {
    cat > "$STATE_FILE" << EOF
LOOP_COUNT=$loop_count
ERROR_COUNT=$error_count
LAST_RUN=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=$1
MODEL=$MODEL_LABEL
ENGINE=$ENGINE
EOF
}

cleanup() {
    log "=== Auto Loop Shutting Down (PID $$) ==="
    rm -f "$PID_FILE"
    save_state "stopped"
    # Kill the anthropic adapter
    if [ -n "$ADAPTER_PID" ] && kill -0 "$ADAPTER_PID" 2>/dev/null; then
        kill "$ADAPTER_PID" 2>/dev/null || true
        log "Anthropic adapter (PID $ADAPTER_PID) stopped"
    fi
    exit 0
}

snapshot_gitignore() {
    if [ "$AUTO_LOOP_PROTECT_GITIGNORE" = "0" ]; then
        echo ""
        return
    fi

    local gitignore_file="$PROJECT_DIR/.gitignore"
    local snapshot_file=""
    if [ -f "$gitignore_file" ]; then
        snapshot_file=$(mktemp)
        cp "$gitignore_file" "$snapshot_file"
    fi
    echo "$snapshot_file"
}

restore_gitignore_if_changed() {
    local snapshot_file="$1"
    if [ "$AUTO_LOOP_PROTECT_GITIGNORE" = "0" ]; then
        [ -n "$snapshot_file" ] && rm -f "$snapshot_file"
        return
    fi

    local gitignore_file="$PROJECT_DIR/.gitignore"
    local changed=0

    if [ -f "$gitignore_file" ]; then
        if [ -z "$snapshot_file" ] || [ ! -f "$snapshot_file" ]; then
            changed=1
        elif ! cmp -s "$gitignore_file" "$snapshot_file"; then
            changed=1
        fi
    else
        if [ -n "$snapshot_file" ] && [ -f "$snapshot_file" ]; then
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        if [ -n "$snapshot_file" ] && [ -f "$snapshot_file" ]; then
            cp "$snapshot_file" "$gitignore_file"
            log_cycle "$loop_count" "GUARD" "Blocked cycle mutation of .gitignore and restored baseline"
        else
            rm -f "$gitignore_file"
            log_cycle "$loop_count" "GUARD" "Blocked cycle-created .gitignore and removed it"
        fi
    fi

    [ -n "$snapshot_file" ] && rm -f "$snapshot_file"
}

get_file_size_bytes() {
    local target_file="$1"
    if [ ! -f "$target_file" ]; then
        echo 0
        return
    fi

    if stat -c%s "$target_file" >/dev/null 2>&1; then
        stat -c%s "$target_file"
        return
    fi

    if stat -f%z "$target_file" >/dev/null 2>&1; then
        stat -f%z "$target_file"
        return
    fi

    wc -c < "$target_file" | tr -d ' '
}

rotate_logs() {
    # Keep only the latest N cycle logs
    local count
    count=$(find "$LOG_DIR" -name "cycle-*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt "$MAX_LOGS" ]; then
        local to_delete=$((count - MAX_LOGS))
        find "$LOG_DIR" -name "cycle-*.log" -type f | sort | head -n "$to_delete" | xargs rm -f 2>/dev/null || true
        log "Log rotation: removed $to_delete old cycle logs"
    fi

    # Rotate main log if over 10MB
    local log_size
    log_size=$(get_file_size_bytes "$LOG_DIR/auto-loop.log")
    if [ "$log_size" -gt 10485760 ]; then
        mv "$LOG_DIR/auto-loop.log" "$LOG_DIR/auto-loop.log.old"
        log "Main log rotated (was ${log_size} bytes)"
    fi
}

cleanup_accidental_root_artifacts() {
    local removed=0
    local removed_names=""
    local f base

    # Known accidental artifacts caused by malformed shell redirections in generated commands.
    for f in "$PROJECT_DIR"/=* "$PROJECT_DIR"/口径说明*; do
        [ -f "$f" ] || continue
        if [ ! -s "$f" ]; then
            rm -f "$f"
            removed=$((removed + 1))
            base=$(basename "$f")
            if [ -z "$removed_names" ]; then
                removed_names="$base"
            else
                removed_names="$removed_names, $base"
            fi
        fi
    done

    if [ "$removed" -gt 0 ]; then
        log_cycle "$loop_count" "GUARD" "Removed accidental root zero-byte artifact(s): $removed_names"
    fi
}

backup_consensus() {
    if [ -f "$CONSENSUS_FILE" ]; then
        cp "$CONSENSUS_FILE" "$CONSENSUS_FILE.bak"
    fi
}

restore_consensus() {
    if [ -f "$CONSENSUS_FILE.bak" ]; then
        cp "$CONSENSUS_FILE.bak" "$CONSENSUS_FILE"
        log "Consensus restored from backup after failed cycle"
    fi

    # --- Retry tracking: mark the restored Next Action so the next cycle knows it failed before ---
    local RETRY_FILE="$PROJECT_DIR/.consensus-retry-count"
    local retries=0
    if [ -f "$RETRY_FILE" ]; then
        retries=$(cat "$RETRY_FILE" 2>/dev/null || echo 0)
    fi
    retries=$((retries + 1))
    echo "$retries" > "$RETRY_FILE"

    if [ -f "$CONSENSUS_FILE" ]; then
        if [ "$retries" -ge 3 ]; then
            # 3+ consecutive restores: force pivot (old approach is clearly not working)
            sed -i '' 's/^## Next Action.*/## Next Action (FORCED PIVOT — retried '${retries}' times without progress)\n\n**System directive:** This task has failed '${retries}' consecutive times. Abandon it. Instead, identify the next highest-value action you can execute independently. If no obvious alternative exists, do a self-audit: review your codebase, write documentation, or refactor for quality./' "$CONSENSUS_FILE"
            log "Consensus pivot forced after ${retries} consecutive restore cycles"
            rm -f "$RETRY_FILE"
        else
            # 1-2 restores: mark the Next Action as retried so the next cycle adapts
            local na_line
            na_line=$(grep "^## Next Action" "$CONSENSUS_FILE" 2>/dev/null | head -1)
            if [ -n "$na_line" ] && ! echo "$na_line" | grep -q "RETRY"; then
                sed -i '' 's/^## Next Action.*/## Next Action (RETRY #'"${retries}"' — previous attempt failed, try a narrower scope or different approach)/' "$CONSENSUS_FILE"
                log "Next Action marked as RETRY #${retries}"
            fi
        fi
    fi

    # Clean up piled-up System directive noise left by pivot logic
    sed -i '' '/^\*\*System directive:\*\*/d' "$CONSENSUS_FILE" 2>/dev/null || true
}

validate_consensus() {
    if [ ! -s "$CONSENSUS_FILE" ]; then
        return 1
    fi
    if ! grep -q "^# Auto Company Consensus" "$CONSENSUS_FILE"; then
        return 1
    fi
    if ! grep -q "^## Next Action" "$CONSENSUS_FILE"; then
        return 1
    fi
    if ! grep -q "^## Company State" "$CONSENSUS_FILE"; then
        return 1
    fi
    return 0
}

consensus_changed_since_backup() {
    if [ ! -f "$CONSENSUS_FILE" ]; then
        return 1
    fi

    if [ ! -f "$CONSENSUS_FILE.bak" ]; then
        return 0
    fi

    if cmp -s "$CONSENSUS_FILE" "$CONSENSUS_FILE.bak"; then
        return 1
    fi

    return 0
}

resolve_codex_bin() {
    if [ -n "$CODEX_BIN" ]; then
        if [ -x "$CODEX_BIN" ]; then
            echo "$CODEX_BIN"
            return 0
        fi
        if command -v "$CODEX_BIN" >/dev/null 2>&1; then
            command -v "$CODEX_BIN"
            return 0
        fi
    fi

    # Prefer WSL-local Codex installed via nvm.
    local nvm_candidate=""
    for candidate in "$HOME"/.nvm/versions/node/*/bin/codex; do
        if [ -x "$candidate" ]; then
            nvm_candidate="$candidate"
        fi
    done
    if [ -n "$nvm_candidate" ]; then
        echo "$nvm_candidate"
        return 0
    fi

    # Fallback: ask an interactive bash shell (loads user profile).
    local interactive_candidate
    interactive_candidate=$(bash -ic 'command -v codex' 2>/dev/null | tail -n1 | tr -d '\r' || true)
    if [ -n "$interactive_candidate" ] && [ -x "$interactive_candidate" ]; then
        echo "$interactive_candidate"
        return 0
    fi

    # Last fallback: current shell PATH.
    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    return 1
}

resolve_claude_bin() {
    if [ -n "$CLAUDE_BIN" ]; then
        if [ -x "$CLAUDE_BIN" ]; then
            echo "$CLAUDE_BIN"
            return 0
        fi
        if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
            command -v "$CLAUDE_BIN"
            return 0
        fi
    fi

    # Prefer WSL-local Claude CLI installed via nvm.
    local nvm_candidate=""
    for candidate in "$HOME"/.nvm/versions/node/*/bin/claude; do
        if [ -x "$candidate" ]; then
            nvm_candidate="$candidate"
        fi
    done
    if [ -n "$nvm_candidate" ]; then
        echo "$nvm_candidate"
        return 0
    fi

    # Fallback: ask an interactive bash shell (loads user profile).
    local interactive_candidate
    interactive_candidate=$(bash -ic 'command -v claude' 2>/dev/null | tail -n1 | tr -d '\r' || true)
    if [ -n "$interactive_candidate" ] && [ -x "$interactive_candidate" ]; then
        echo "$interactive_candidate"
        return 0
    fi

    # Last fallback: current shell PATH.
    if command -v claude >/dev/null 2>&1; then
        command -v claude
        return 0
    fi

    return 1
}

resolve_engine_bin() {
    case "$ENGINE" in
        claude)
            resolve_claude_bin
            ;;
        engine)
            # Python engine (direct SenseNova call, no adapter)
            local engine_py="$PROJECT_DIR/scripts/core/engine.py"
            if [ -f "$engine_py" ]; then
                echo "/Users/ayong/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
                return 0
            fi
            return 1
            ;;
        codex)
            resolve_codex_bin
            ;;
        *)
            return 1
            ;;
    esac
}

run_codex_cycle() {
    local prompt="$1"
    local output_file timeout_flag message_file

    output_file=$(mktemp)
    timeout_flag=$(mktemp)
    message_file=$(mktemp)

    set +e
    (
        cd "$PROJECT_DIR" || exit 1
        local codex_cmd=("$RESOLVED_ENGINE_BIN" "exec" "-c" "sandbox_mode=\"${CODEX_SANDBOX_MODE}\"" "-o" "$message_file")
        if [ -n "$MODEL" ]; then
            codex_cmd+=("-m" "$MODEL")
        fi
        codex_cmd+=("$prompt")
        "${codex_cmd[@]}"
    ) > "$output_file" 2>&1 &
    local codex_pid=$!

    (
        sleep "$CYCLE_TIMEOUT_SECONDS"
        if kill -0 "$codex_pid" 2>/dev/null; then
            echo "1" > "$timeout_flag"
            kill -TERM "$codex_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$codex_pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!

    wait "$codex_pid"
    EXIT_CODE=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    set -e

    OUTPUT=$(cat "$output_file")
    RESULT_MESSAGE=$(cat "$message_file" 2>/dev/null || true)
    rm -f "$output_file" "$message_file"

    if [ -s "$timeout_flag" ]; then
        CYCLE_TIMED_OUT=1
        EXIT_CODE=124
    else
        CYCLE_TIMED_OUT=0
    fi
    rm -f "$timeout_flag"
}

run_claude_cycle() {
    local prompt="$1"
    local output_file timeout_flag

    output_file=$(mktemp)
    timeout_flag=$(mktemp)

    set +e
    (
        cd "$PROJECT_DIR" || exit 1
        # Only use adapter for claude engine; engine.py calls SenseNova directly
        if [ "$ENGINE" = "claude" ]; then
            export ANTHROPIC_BASE_URL="http://127.0.0.1:${ADAPTER_PORT}"
        fi

        local claude_cmd=()
        if [ "$ENGINE" = "engine" ]; then
            claude_cmd=("$RESOLVED_ENGINE_BIN" "$PROJECT_DIR/scripts/core/engine.py" "-p" "$prompt" "--output-format" "json")
        else
            claude_cmd=("$RESOLVED_ENGINE_BIN" "-p" "$prompt" "--output-format" "json")
        fi
        if [ -n "$MODEL" ]; then
            claude_cmd+=("--model" "$MODEL")
        fi
        if [ -n "$CLAUDE_PERMISSION_MODE" ]; then
            claude_cmd+=("--permission-mode" "$CLAUDE_PERMISSION_MODE")
        fi
        "${claude_cmd[@]}"
    ) > "$output_file" 2>&1 &
    local claude_pid=$!

    (
        sleep "$CYCLE_TIMEOUT_SECONDS"
        if kill -0 "$claude_pid" 2>/dev/null; then
            echo "1" > "$timeout_flag"
            kill -TERM "$claude_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$claude_pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!

    wait "$claude_pid"
    EXIT_CODE=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    set -e

    # ── Reaper: ensure Claude process is fully dead before proceeding ──
    local _r=0
    while kill -0 "$claude_pid" 2>/dev/null; do
        _r=$((_r + 1))
        [ "$_r" -gt 5 ] && { log "WARN: Claude PID $claude_pid alive after 5 attempts"; break; }
        kill -KILL "$claude_pid" 2>/dev/null || true
        sleep 1
    done
    [ "$_r" -gt 0 ] && log "Reaper: Claude PID $claude_pid dead after ${_r}s"

    OUTPUT=$(cat "$output_file")
    RESULT_MESSAGE="$OUTPUT"
    rm -f "$output_file"

    if [ -s "$timeout_flag" ]; then
        CYCLE_TIMED_OUT=1
        EXIT_CODE=124
    else
        CYCLE_TIMED_OUT=0
    fi
    rm -f "$timeout_flag"
}

run_engine_cycle() {
    local prompt="$1"
    case "$ENGINE" in
        claude|engine)
            run_claude_cycle "$prompt"
            ;;
        codex)
            run_codex_cycle "$prompt"
            ;;
        *)
            echo "Error: Unsupported ENGINE '$ENGINE'" >&2
            return 1
            ;;
    esac
}

extract_cycle_metadata() {
    RESULT_TEXT=""
    CYCLE_COST="N/A"
    CYCLE_SUBTYPE="unknown"
    CYCLE_IS_ERROR=0
    CYCLE_API_STATUS=0
    CYCLE_TYPE="${ENGINE}_exec"

    if [ "$ENGINE" = "claude" ] || [ "$ENGINE" = "engine" ]; then
        if command -v jq >/dev/null 2>&1; then
            RESULT_TEXT=$(echo "$RESULT_MESSAGE" | jq -r '.result // .message // .output_text // empty' 2>/dev/null | head -c 2000 || true)
            if [ -z "$RESULT_TEXT" ]; then
                RESULT_TEXT=$(echo "$RESULT_MESSAGE" | jq -r '.. | .text? // empty' 2>/dev/null | head -c 2000 || true)
            fi

            parsed_cost=$(echo "$RESULT_MESSAGE" | jq -r '.total_cost_usd // .cost_usd // empty' 2>/dev/null || true)
            if [ -n "$parsed_cost" ]; then
                CYCLE_COST="$parsed_cost"
            fi

            parsed_subtype=$(echo "$RESULT_MESSAGE" | jq -r '.subtype // empty' 2>/dev/null || true)
            if [ -n "$parsed_subtype" ]; then
                CYCLE_SUBTYPE="$parsed_subtype"
            fi

            # Claude CLI misleadingly sets subtype=success even for 429/exhaustion errors
            # Check is_error to get the real truth
            CYCLE_IS_ERROR=0
            parsed_is_error=$(echo "$RESULT_MESSAGE" | jq -r '.is_error // empty' 2>/dev/null || true)
            if [ "$parsed_is_error" = "true" ]; then
                CYCLE_IS_ERROR=1
            fi

            # Extract HTTP status for precise quota detection
            CYCLE_API_STATUS=0
            parsed_api_status=$(echo "$RESULT_MESSAGE" | jq -r '.api_error_status // empty' 2>/dev/null || true)
            if [ -n "$parsed_api_status" ] && [ "$parsed_api_status" != "null" ]; then
                CYCLE_API_STATUS="$parsed_api_status"
            fi

            # Extract limit_type for 429 discrimination (rpm vs quota)
            CYCLE_LIMIT_TYPE=""
            parsed_limit_type=$(echo "$RESULT_MESSAGE" | jq -r '.limit_type // empty' 2>/dev/null || true)
            if [ -n "$parsed_limit_type" ] && [ "$parsed_limit_type" != "null" ]; then
                CYCLE_LIMIT_TYPE="$parsed_limit_type"
            fi

            parsed_type=$(echo "$RESULT_MESSAGE" | jq -r '.type // empty' 2>/dev/null || true)
            if [ -n "$parsed_type" ]; then
                CYCLE_TYPE="$parsed_type"
            fi
        fi

        if [ -z "$RESULT_TEXT" ]; then
            RESULT_TEXT=$(echo "$OUTPUT" | head -c 2000 || true)
        fi

        if [ "$CYCLE_SUBTYPE" = "unknown" ]; then
            if [ "$EXIT_CODE" -eq 0 ]; then
                CYCLE_SUBTYPE="success"
            else
                CYCLE_SUBTYPE="error"
            fi
        fi
        return
    fi

    RESULT_TEXT=$(echo "$RESULT_MESSAGE" | head -c 2000 || true)
    if [ -z "$RESULT_TEXT" ]; then
        RESULT_TEXT=$(echo "$OUTPUT" | head -c 2000 || true)
    fi

    if [ "$EXIT_CODE" -eq 0 ]; then
        CYCLE_SUBTYPE="success"
    else
        CYCLE_SUBTYPE="error"
    fi
}

# === API Connectivity Check (via adapter, then to SenseNova) ===
check_api_connectivity() {
    # In engine mode, check SenseNova directly; in claude mode, check adapter
    local http_code
    if [ "$ENGINE" = "engine" ]; then
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "https://token.sensenova.cn/v1/models" \
            -H "Authorization: Bearer ${ANTHROPIC_AUTH_TOKEN:-}" \
            --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")
        case "$http_code" in
            200|401|429) return 0 ;;  # 200=ok, 401=auth(means reachable), 429=limited
            *) return 1 ;;
        esac
    else
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://127.0.0.1:${ADAPTER_PORT}/health" \
            --connect-timeout 3 --max-time 5 2>/dev/null || echo "000")
        case "$http_code" in
            200|400|401|429|500|502|503) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

# === Key Rotation ===
# SenseNova 免费额度每 5 小时重置。用完一个 key 自动切换下一个。
KEY_STATE_FILE="$PROJECT_DIR/.key-rotation-state"
KEY_IDS=(AC_API_KEY_1 AC_API_KEY_2 AC_API_KEY_3 AC_API_KEY_4 AC_API_KEY_5 AC_API_KEY_6)

rotate_api_key() {
    local now key_exhausted_at elapsed_hours best_key best_idx

    now=$(date +%s)

    # Read key state from file (JSON lines: key_id exhausted_timestamp)
    # Format: each line = "KEY_ID TIMESTAMP" (TIMESTAMP=0 means fresh)
    if [ ! -f "$KEY_STATE_FILE" ]; then
        # Initialize: all keys start fresh (timestamp=0)
        > "$KEY_STATE_FILE"
        for kid in "${KEY_IDS[@]}"; do
            echo "$kid 0" >> "$KEY_STATE_FILE"
        done
    fi

    # Find the best (non-exhausted or recovered) key
    best_key=""
    best_idx=0
    while read -r line; do
        local kid ts
        kid=$(echo "$line" | awk '{print $1}')
        ts=$(echo "$line" | awk '{print $2}')
        if [ "$ts" -eq 0 ]; then
            # Fresh key (never exhausted)
            best_key="$kid"
            break
        fi
        elapsed_hours=$(( (now - ts) / 3600 ))
        if [ "$elapsed_hours" -ge 5 ]; then
            # Recovered after 5h cooldown
            best_key="$kid"
            # Reset timestamp
            sed -i '' "s/^$kid .*/$kid 0/" "$KEY_STATE_FILE"
            break
        fi
    done < "$KEY_STATE_FILE"

    # If no key found in order scan, do a full search
    if [ -z "$best_key" ]; then
        while read -r line; do
            local kid ts
            kid=$(echo "$line" | awk '{print $1}')
            ts=$(echo "$line" | awk '{print $2}')
            if [ "$ts" -eq 0 ]; then
                best_key="$kid"
                break
            fi
            elapsed_hours=$(( (now - ts) / 3600 ))
            if [ "$elapsed_hours" -ge 5 ]; then
                best_key="$kid"
                sed -i '' "s/^$kid .*/$kid 0/" "$KEY_STATE_FILE"
                break
            fi
        done < "$KEY_STATE_FILE"
    fi

    # Fallback: all keys exhausted, none recovered yet
    if [ -z "$best_key" ]; then
        local oldest_ts=$((now + 1))
        local oldest_kid="${KEY_IDS[0]}"
        while read -r line; do
            local kid ts
            kid=$(echo "$line" | awk '{print $1}')
            ts=$(echo "$line" | awk '{print $2}')
            if [ "$ts" -gt 0 ] && [ "$ts" -lt "$oldest_ts" ]; then
                oldest_ts=$ts
                oldest_kid="$kid"
            fi
        done < "$KEY_STATE_FILE"
        local wait_sec=$(( 5 * 3600 - (now - oldest_ts) ))
        [ "$wait_sec" -lt 0 ] && wait_sec=0
        local wait_min=$(( wait_sec / 60 ))
        log "ALL 6 API keys exhausted. Next recovery (${oldest_kid}) in ${wait_min}min at $(date -r $oldest_ts -j '+%H:%M' 2>/dev/null || echo 'soon')+5h"
        ALL_KEYS_EXHAUSTED=$wait_sec
        return 2  # Special code: all keys exhausted
    fi

    # Read the actual key value from environment or .env
    local key_value
    key_value=$(eval echo "\${$best_key:-}")
    if [ -z "$key_value" ]; then
        log "ERROR: Key $best_key is empty! Check .env file"
        return 1
    fi

    export ANTHROPIC_AUTH_TOKEN="$key_value"
    export ANTHROPIC_API_KEY="$key_value"
    # Show account name instead of raw key prefix (security: prevent key leak in logs)
    local key_account
    key_account=$(eval echo "\${${best_key}_ACCOUNT:-}")
    if [ -n "$key_account" ]; then
        log_cycle "$loop_count" "KEY" "Using $best_key ($key_account)"
    else
        log_cycle "$loop_count" "KEY" "Using $best_key (${key_value:0:12}...)"
    fi
    return 0
}

# === Timestamp Stamping ===
# Model agents don't reliably run `date` — they often copy-paste old timestamps.
# Bash enforces the real time after every successful cycle.
stamp_consensus_timestamp() {
    local now
    now=$(date '+%Y-%m-%d %H:%M %Z')
    if [ -f "$CONSENSUS_FILE" ]; then
        # Replace the line immediately after "## Last Updated" with the real time
        sed -i '' "/^## Last Updated$/{n;s/.*/$now/;}" "$CONSENSUS_FILE"
    fi
}

mark_key_exhausted() {
    local now
    now=$(date +%s)

    # Find which key is currently active and mark it
    local current_token="${ANTHROPIC_AUTH_TOKEN:-}"
    if [ -z "$current_token" ]; then
        return
    fi

    while read -r line; do
        local kid ts
        kid=$(echo "$line" | awk '{print $1}')
        ts=$(echo "$line" | awk '{print $2}')
        local key_val
        key_val=$(eval echo "\${$kid:-}")
        if [ "$key_val" = "$current_token" ] && [ "$ts" -eq 0 ]; then
            sed -i '' "s/^$kid 0/$kid $now/" "$KEY_STATE_FILE"
            local readable
            readable=$(date '+%Y-%m-%d %H:%M:%S')
            log_cycle "$loop_count" "KEY" "Marked $kid as exhausted at $readable"
            break
        fi
    done < "$KEY_STATE_FILE"
}

# === Exponential Backoff ===
compute_backoff() {
    local chain=${1:-1}
    local base=10
    local exponent=$((chain - 1))
    if [ "$exponent" -lt 0 ]; then
        exponent=0
    fi
    local backoff=$(( base * (1 << exponent) ))
    if [ "$backoff" -gt 300 ]; then
        backoff=300
    fi
    echo "$backoff"
}

# === Deadlock Detection ===
NA_HISTORY_FILE="$PROJECT_DIR/.next-action-history"
detect_next_action_stuck() {
    local current_na
    current_na=$(grep "^## Next Action" "$CONSENSUS_FILE" 2>/dev/null | head -1 | sed 's/^## Next Action[[:space:]]*//' | tr -d '\n' || true)
    if [ -z "$current_na" ]; then
        return 1
    fi

    echo "$current_na" >> "$NA_HISTORY_FILE"
    local lines
    lines=$(wc -l < "$NA_HISTORY_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt 3 ]; then
        tail -n 3 "$NA_HISTORY_FILE" > "${NA_HISTORY_FILE}.tmp" && mv "${NA_HISTORY_FILE}.tmp" "$NA_HISTORY_FILE"
        lines=3
    fi
    if [ "$lines" -lt 3 ]; then
        return 1
    fi

    local first second third
    first=$(sed -n '1p' "$NA_HISTORY_FILE")
    second=$(sed -n '2p' "$NA_HISTORY_FILE")
    third=$(sed -n '3p' "$NA_HISTORY_FILE")
    if [ "$first" = "$second" ] && [ "$second" = "$third" ] && [ -n "$first" ]; then
        return 0
    fi
    return 1
}

pivot_stuck_next_action() {
    if [ -f "$CONSENSUS_FILE" ]; then
        sed -i '' "s/^## Next Action.*/## Next Action (FORCED PIVOT — previous action stuck for 3 cycles)\n\n**System directive:** The previous Next Action was repeated for 3 consecutive cycles without progress. Abandon the blocked action. Instead, identify the next highest-value action you can execute without the blocked dependency. If the block is API\/auth related, switch to a project that needs no external credentials. If all projects are blocked, perform a self-audit: review your own code, write documentation, or refactor for quality./" "$CONSENSUS_FILE" 2>/dev/null || true
    fi
    rm -f "$NA_HISTORY_FILE"
}

# === Subtask Granularity Check (prevent ≥20min subtasks from entering a cycle) ===
check_subtask_granularity() {
    if [ ! -f "$CONSENSUS_FILE" ]; then
        return 0
    fi

    local oversized
    oversized=$(python3 -c "
import re, sys

with open('$CONSENSUS_FILE', 'r') as f:
    content = f.read()

# Find the Next Action section and its subtask table
# Pattern: | N.M | ... | 预期耗时 | ... |
lines = content.split('\n')
in_next = False
in_table = False
issues = []

for line in lines:
    if line.startswith('## Next Action'):
        in_next = True
        continue
    if in_next and line.startswith('## '):
        break  # End of Next Action section
    if in_next and line.startswith('| ---'):
        in_table = True
        continue
    if in_next and in_table and line.startswith('|'):
        # Parse table row: | # | 子任务 | 预期耗时 | 产出物 | 状态 |
        cols = [c.strip() for c in line.split('|')]
        # cols[0] is empty, cols[1] = #, cols[2] = 子任务, cols[3] = 预期耗时, cols[4] = 产出物, cols[5] = 状态
        if len(cols) >= 4:
            subtask_id = cols[1] if len(cols) > 1 else '?'
            task_name = cols[2] if len(cols) > 2 else '?'
            duration_str = cols[3] if len(cols) > 3 else ''
            # Parse duration: '15min', '~2h', '1.5h', '20min', '30min', '45min', '~45min'
            duration_str_clean = duration_str.replace('~', '').replace(' ', '').lower()
            minutes = 0
            if duration_str_clean.endswith('h'):
                try:
                    minutes = float(duration_str_clean.replace('h', '')) * 60
                except ValueError:
                    pass
            elif duration_str_clean.endswith('min'):
                try:
                    minutes = float(duration_str_clean.replace('min', ''))
                except ValueError:
                    pass
            elif duration_str_clean.endswith('m'):
                try:
                    minutes = float(duration_str_clean.replace('m', ''))
                except ValueError:
                    pass

            if minutes >= 20:
                issues.append(f'{subtask_id} {task_name} ({duration_str}) = {int(minutes)}min')

if issues:
    print(';;'.join(issues))
    sys.exit(1)
sys.exit(0)
" 2>/dev/null || true)

    local exit_code=$?
    if [ "$exit_code" -eq 1 ] && [ -n "$oversized" ]; then
        # Found oversized subtasks — log warning and modify consensus
        log_cycle "$loop_count" "GRANULARITY" "Subtask(s) exceed 20min limit: ${oversized}"
        # Insert a re-split reminder above the Next Action table
        local warning="> ⚠️ **Granularity Alert:** The following subtask(s) exceed the 20-minute limit and must be re-split before execution: ${oversized}"
        if ! grep -q "Granularity Alert" "$CONSENSUS_FILE" 2>/dev/null; then
            # Insert warning after the Next Action header
            sed -i '' '/^## Next Action/a\
'"$warning"'' "$CONSENSUS_FILE" 2>/dev/null || true
            log_cycle "$loop_count" "GRANULARITY" "Warning inserted into consensus — re-split required"
        fi
        return 1
    fi
    return 0
}

# === Idle Detection (save tokens when nothing to do) ===
IDLE_HEAD_FILE="$PROJECT_DIR/.last-cycle-head"
IDLE_SKIP_COUNT_FILE="$PROJECT_DIR/.idle-skip-count"
check_has_work() {
    # Returns 0 if there's work (git HEAD changed OR uncommitted changes)
    # Returns 1 if idle (nothing changed since last cycle)
    if [ ! -f "$IDLE_HEAD_FILE" ]; then
        return 0
    fi
    # Check HEAD change
    local last_head
    last_head=$(cat "$IDLE_HEAD_FILE" 2>/dev/null || true)
    local current_head
    current_head=$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || date +%s)
    if [ "$last_head" != "$current_head" ]; then
        return 0
    fi
    # Check uncommitted changes
    if cd "$PROJECT_DIR" && git status --porcelain 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}
save_cycle_head() {
    cd "$PROJECT_DIR" && git rev-parse HEAD > "$IDLE_HEAD_FILE" 2>/dev/null || echo "$(date +%s)" > "$IDLE_HEAD_FILE"
}
write_status_json() {
    local cycle_status="$1"
    local idle_count quota_json
    idle_count=$(cat "$IDLE_SKIP_COUNT_FILE" 2>/dev/null || echo 0)
    quota_json='{}'  # No proxy quota endpoint — LIMIT detection happens via Claude CLI output
    local na_text
    na_text=$(grep '^## Next Action' "$CONSENSUS_FILE" 2>/dev/null | head -1 | sed 's/^## Next Action[[:space:]]*//' | tr -d '\n' | sed 's/"/\\"/g' || true)
    local rev_text
    rev_text=$(grep -i 'Revenue' "$CONSENSUS_FILE" 2>/dev/null | head -1 | sed 's/.*Revenue: //' | tr -d '\n' || true)
    local usr_text
    usr_text=$(grep -i 'Users' "$CONSENSUS_FILE" 2>/dev/null | head -1 | sed 's/.*Users: //' | tr -d '\n' || true)
    local qt_text
    qt_text=$(echo "$quota_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps({'mode':d.get('mode','unknown'),'totalTokens':d.get('total_tokens',0)}))" 2>/dev/null || echo '{"mode":"unknown","totalTokens":0}')
    printf '{\n' > "$PROJECT_DIR/status.json"
    printf '  "cycle": %s,\n' "$loop_count" >> "$PROJECT_DIR/status.json"
    printf '  "status": "%s",\n' "$cycle_status" >> "$PROJECT_DIR/status.json"
    printf '  "exitCode": %s,\n' "${EXIT_CODE:-0}" >> "$PROJECT_DIR/status.json"
    printf '  "cost": "%s",\n' "${CYCLE_COST:-N/A}" >> "$PROJECT_DIR/status.json"
    printf '  "errorType": "%s",\n' "${cycle_failed_reason:-none}" >> "$PROJECT_DIR/status.json"
    printf '  "nextAction": "%s",\n' "$na_text" >> "$PROJECT_DIR/status.json"
    printf '  "revenue": "%s",\n' "$rev_text" >> "$PROJECT_DIR/status.json"
    printf '  "users": "%s",\n' "$usr_text" >> "$PROJECT_DIR/status.json"
    printf '  "idleSkipCount": %s,\n' "$idle_count" >> "$PROJECT_DIR/status.json"
    printf '  "quota": %s,\n' "$qt_text" >> "$PROJECT_DIR/status.json"
    printf '  "timestamp": "%s"\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$PROJECT_DIR/status.json"
    printf '}\n' >> "$PROJECT_DIR/status.json"
}

# === Setup ===

mkdir -p "$LOG_DIR" "$PROJECT_DIR/memories"

# Clean up stale stop file from previous run
rm -f "$PROJECT_DIR/.auto-loop-stop"

# Check for existing instance
if [ -f "$PID_FILE" ]; then
    existing_pid=$(cat "$PID_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "Auto loop already running (PID $existing_pid). Stop it first with ./stop-loop.sh"
        exit 1
    fi
fi

# Check dependencies
if ! RESOLVED_ENGINE_BIN="$(resolve_engine_bin)"; then
    if [ "$ENGINE" = "claude" ] || [ "$ENGINE" = "engine" ]; then
        echo "Error: Claude CLI not found. Install Claude Code in WSL and verify with 'claude --version'."
    else
        echo "Error: Codex CLI not found. Install Codex in WSL and verify with 'codex --version'."
    fi
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: PROMPT.md not found at $PROMPT_FILE"
    exit 1
fi

# Source .env if it exists (load ANTHROPIC_BASE_URL, MODEL, etc.)
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

# Write PID file
echo $$ > "$PID_FILE"

# Trap signals for graceful shutdown
trap cleanup SIGTERM SIGINT SIGHUP

# Start mini Anthropic adapter (translates role=system → top-level system param)
ADAPTER_PORT="${ADAPTER_PORT:-8082}"
ADAPTER_PID=""
start_anthropic_adapter() {
    local adapter_script="$PROJECT_DIR/scripts/core/anthropic-adapter.py"
    if [ ! -f "$adapter_script" ]; then
        log "ERROR: anthropic-adapter.py not found at $adapter_script"
        exit 1
    fi
    # Clean up any stale adapter on this port
    local stale_pid
    stale_pid=$(lsof -t -i:${ADAPTER_PORT} 2>/dev/null || true)
    if [ -n "$stale_pid" ]; then
        log "Killing stale adapter on port ${ADAPTER_PORT} (PID $stale_pid)"
        kill -9 $stale_pid 2>/dev/null || true
        sleep 1
    fi
    python3 "$adapter_script" &
    ADAPTER_PID=$!
    # Wait for adapter to be ready
    for i in $(seq 1 10); do
        if curl -s "http://127.0.0.1:${ADAPTER_PORT}/health" --connect-timeout 2 >/dev/null 2>&1; then
            log "Anthropic adapter started on port ${ADAPTER_PORT} (PID $ADAPTER_PID)"
            break
        fi
        sleep 1
    done
}
if [ "$ENGINE" = "claude" ]; then
    start_anthropic_adapter
fi

# Initialize counters
loop_count=0
error_count=0
error_chain=0
subtask_breakdown_flag=0
api_health_fail_count=0
idle_skip_count=0
ALL_KEYS_EXHAUSTED=0

# Clear stale deadlock history from previous run
rm -f "$NA_HISTORY_FILE"

log "=== Auto Company Loop Started (PID $$) ==="
log "Project: $PROJECT_DIR"
if [ "$ENGINE" = "codex" ]; then
    log "Engine: codex | Model: $MODEL_LABEL | Sandbox: $CODEX_SANDBOX_MODE"
else
    log "Engine: claude | Model: $MODEL_LABEL | PermissionMode: $CLAUDE_PERMISSION_MODE"
fi
log "Engine bin: $RESOLVED_ENGINE_BIN"
engine_version=$("$RESOLVED_ENGINE_BIN" --version 2>/dev/null | head -n1 || true)
case "$RESOLVED_ENGINE_BIN" in
    /mnt/c/*)
        if [ "$ENGINE" = "codex" ]; then
            log "Warning: Codex binary resolves to Windows-mounted path. Prefer WSL-local install for stability."
        else
            log "Warning: Claude binary resolves to Windows-mounted path. Prefer WSL-local install for stability."
        fi
        ;;
esac
if [ -n "$engine_version" ]; then
    if [ "$ENGINE" = "codex" ]; then
        log "Codex version: $engine_version"
    else
        log "Claude version: $engine_version"
    fi
fi
log "Interval: ${LOOP_INTERVAL}s | Default timeout: ${CYCLE_TIMEOUT_SECONDS}s | Warmup: ${WARMUP_TIMEOUT_SECONDS}s × ${WARMUP_CYCLES} cycles | Breaker: ${MAX_CONSECUTIVE_ERRORS} errors"

# === Main Loop ===

while true; do
    # Check for stop request
    if check_stop_requested; then
        log "Stop requested. Shutting down gracefully."
        cleanup
    fi

    # PID file health check — recreate if missing (guards against accidental deletion)
    if [ ! -f "$PID_FILE" ]; then
        echo $$ > "$PID_FILE"
        log "PID file recovered (was missing, recreated as $$)"
    fi

    loop_count=$((loop_count + 1))
    cycle_log="$LOG_DIR/cycle-$(printf '%04d' "$loop_count")-$(date '+%Y%m%d-%H%M%S').log"

    log_cycle "$loop_count" "START" "Beginning work cycle"
    save_state "running"

    # Log rotation
    rotate_logs

    # Ensure anthropic adapter is alive; restart if dead (claude engine only)
    if [ "$ENGINE" = "claude" ]; then
        if ! kill -0 "$ADAPTER_PID" 2>/dev/null; then
            log "Anthropic adapter (PID $ADAPTER_PID) is dead. Restarting..."
            start_anthropic_adapter
        fi
    fi

    # Quick connectivity check: verify SenseNova endpoint is reachable
    if ! check_api_connectivity; then
        api_health_fail_count=$((api_health_fail_count + 1))
        log_cycle "$loop_count" "SKIP" "SenseNova endpoint unreachable (fail #${api_health_fail_count}); skipping cycle"
        if [ "$api_health_fail_count" -ge 5 ]; then
            log_cycle "$loop_count" "ALERT" "SenseNova endpoint unreachable for 5+ consecutive checks. Check network or https://token.sensenova.cn"
            api_health_fail_count=0
        fi
        save_state "api_unhealthy"
        sleep 10
        continue
    fi
    api_health_fail_count=0

    # Rotate API key: pick the best available key, cycle on exhaustion
    ALL_KEYS_EXHAUSTED=0
    rotate_api_key
    key_rc=$?
    if [ "$key_rc" -eq 2 ]; then
        log_cycle "$loop_count" "NO_KEYS" "All 6 API keys exhausted. Pausing 600s..."
        save_state "no_keys"
        write_status_json "NO_KEYS"
        sleep 600
        log_cycle "$loop_count" "NO_KEYS" "Cooldown complete. Keys should be recovered. Resuming..."
        save_state "idle"
        continue
    fi

    # Backup consensus before cycle

    # Idle detection: skip LLM call if nothing changed
    if ! check_has_work && [ "$error_count" -eq 0 ]; then
        idle_skip_count=$((idle_skip_count + 1))
        echo "$idle_skip_count" > "$IDLE_SKIP_COUNT_FILE"
        # Only log every 10th idle skip to avoid log spam
        if [ $((idle_skip_count % 10)) -eq 0 ]; then
            log_cycle "$loop_count" "IDLE" "No changes detected for ${idle_skip_count} cycles — skipping LLM to save tokens"
        fi
        write_status_json "IDLE"
        save_state "idle"
        sleep "$LOOP_INTERVAL"
        continue
    fi
    idle_skip_count=0
ALL_KEYS_EXHAUSTED=0
    rm -f "$IDLE_SKIP_COUNT_FILE"

    # Subtask granularity check: flag any subtask ≥20min before proceeding
    check_subtask_granularity

    backup_consensus
    gitignore_snapshot=$(snapshot_gitignore)

    # Build prompt with consensus pre-injected
    PROMPT=$(cat "$PROMPT_FILE")
    CONSENSUS=$(cat "$CONSENSUS_FILE" 2>/dev/null || echo "No consensus file found. This is the very first cycle.")

    # === Cron restoration: inject proactive cron recovery ===
    CRON_RESTORE=""
    if [ -f "$CRON_STATE_FILE" ]; then
        CRON_JOBS=$(cat "$CRON_STATE_FILE")
        CRON_TEMPLATE=$(cat "$PROJECT_DIR/.cron-restore-template.md")
        CRON_RESTORE="${CRON_TEMPLATE/__CRON_JSON__/$CRON_JOBS}"
    fi

    FULL_PROMPT="$PROMPT

---

## Runtime Guardrails (must follow)

1. Early in the cycle, create or update \`memories/consensus.md\` with the required section skeleton.
2. If work scope is large, persist partial decisions to \`memories/consensus.md\` before deep dives.
3. Prefer shipping one completed milestone over broad parallel exploration.
4. Never write files via shell heredoc (\`cat <<EOF\`), EXCEPT for \`memories/consensus.md\` at the end of each cycle. Use \`apply_patch\` for other file creates/edits.
5. Never execute shell lines that begin with \`>\` or \`>=\`; treat them as text and keep them inside markdown/files.
6. **Cron persistence:** Whenever you create a cron job via \`CronCreate\`, immediately write its config to \`.cron-state.json\`. Whenever you detect a session restart (empty CronList), restore cron from \`.cron-state.json\` as the first action of the cycle.

---
$CRON_RESTORE

## Current Consensus (pre-loaded, do NOT re-read this file)

$CONSENSUS

---

This is Cycle #$loop_count. Act decisively."

    # ── Inject subtask breakdown prefix if previous cycle hit max-turns ──
    if [ "$subtask_breakdown_flag" = "1" ]; then
        FULL_PROMPT="## ⚠️ BREAKDOWN MODE — Previous cycle ran out of turns

The task is too large. You MUST:
1. Read the Next Action below
2. Break it into ~3 numbered subtasks
3. Execute ONLY subtask #1 this cycle
4. End with partial result: what was done + what remains for next cycle

DO NOT attempt the full task. ONE subtask only.

---

$FULL_PROMPT"
        subtask_breakdown_flag=0  # reset for next cycle
    fi


    # Dynamic timeout: use warmup timeout for early cycles after restart (saves tokens)
    if [ "$loop_count" -le "$WARMUP_CYCLES" ]; then
        CYCLE_TIMEOUT_SECONDS="$WARMUP_TIMEOUT_SECONDS"
        log_cycle "$loop_count" "WARMUP" "Warmup probe cycle #1/1 — read-only, ${WARMUP_TIMEOUT_SECONDS}s"
        FULL_PROMPT="$FULL_PROMPT

## ⚡ Warmup Probe Mode (read-only health check)

This is a **read-only warmup probe**, NOT a normal work cycle.

### What you MUST do:
1. **Read** \`memories/consensus.md\` and verify it loads correctly
2. **Read** a few key project files (\`README.md\`, \`PROMPT.md\`)
3. **Check** python, node, and basic tools are accessible
4. **Report** a brief \`[WARMUP] OK — ...\` summary to stdout

### What you MUST NOT do:
- ❌ Do NOT write or modify any files
- ❌ Do NOT update consensus.md
- ❌ Do NOT call Write, Edit, Delete, or any destructive tool
- ❌ Do NOT start working on tasks

### Output:
Write \`[WARMUP] OK — ...\` or \`[WARMUP] FAIL — ...\` to stdout and exit cleanly."
    else
        # First real cycle after warmup: cold start needs extra time to read project + think
        if [ "$loop_count" -eq $((WARMUP_CYCLES + 1)) ]; then
            CYCLE_TIMEOUT_SECONDS=3600
            log_cycle "$loop_count" "COLD_START" "First real cycle — extended timeout to 3600s"
        else
            CYCLE_TIMEOUT_SECONDS=900
        fi
    fi

    # Run selected engine in headless mode with per-cycle timeout
    run_engine_cycle "$FULL_PROMPT"
    # CRITICAL: run_engine_cycle re-enables "set -e" internally (run_claude_cycle line 466).
    # Restore +e here to prevent the main loop from crashing on any non-zero exit.
    set +e

    # Save full output to cycle log
    echo "$OUTPUT" > "$cycle_log"

    # Clean up known malformed-redirection artifacts created by bad generated shell commands.
    cleanup_accidental_root_artifacts
    restore_gitignore_if_changed "$gitignore_snapshot"

    # Extract result fields for status classification
    extract_cycle_metadata

    cycle_failed_reason=""
    cycle_soft_timeout=0
    if [ "$CYCLE_TIMED_OUT" -eq 1 ]; then
        if validate_consensus && consensus_changed_since_backup; then
            cycle_soft_timeout=1
        else
            cycle_failed_reason="Timed out after ${CYCLE_TIMEOUT_SECONDS}s"
        fi
    elif [ "$EXIT_CODE" -ne 0 ]; then
        # Non-zero exit code - but check if model actually did real work
        # (Claude CLI exit 1 is common even after successful work)
        # Only treat as failure if the API itself reported an error (is_error=true)
        # or the consensus wasn't updated
        if [ "$CYCLE_IS_ERROR" -eq 1 ]; then
            cycle_failed_reason="API error: exit $EXIT_CODE (is_error=true)"
        elif [ "$CYCLE_SUBTYPE" = "success" ] && validate_consensus && consensus_changed_since_backup; then
            : # Real work was done despite exit 1 → OK
        else
            cycle_failed_reason="Exit code $EXIT_CODE"
        fi
    elif ! validate_consensus; then
        cycle_failed_reason="consensus.md validation failed after cycle"
    fi

    if [ "$cycle_soft_timeout" -eq 1 ]; then
        log_cycle "$loop_count" "OK" "Timed out after ${CYCLE_TIMEOUT_SECONDS}s but consensus was updated; keeping progress (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE})"
        if [ -n "$RESULT_TEXT" ]; then
            log_cycle "$loop_count" "SUMMARY" "$(echo "$RESULT_TEXT" | head -c 300)"
        fi
        error_count=0
        error_chain=0
        rm -f "$PROJECT_DIR/.consensus-retry-count"
        stamp_consensus_timestamp
    elif [ -z "$cycle_failed_reason" ]; then
        log_cycle "$loop_count" "OK" "Completed (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE})"
        if [ -n "$RESULT_TEXT" ]; then
            log_cycle "$loop_count" "SUMMARY" "$(echo "$RESULT_TEXT" | head -c 300)"
        fi

        # === 验证层: 代码修改后自动验证，不通过则回滚 ===
        VERIFY_SCRIPT="$PROJECT_DIR/scripts/core/verify.sh"
        if [ -f "$VERIFY_SCRIPT" ]; then
            VERIFY_LOG="$PROJECT_DIR/.cycle/verify.log"
            mkdir -p "$PROJECT_DIR/.cycle"
            bash "$VERIFY_SCRIPT" > "$VERIFY_LOG" 2>&1
            VERIFY_EXIT=$?
            if [ "$VERIFY_EXIT" -ne 0 ]; then
                VERIFY_SUMMARY=$(tail -5 "$VERIFY_LOG" | head -3 | tr '\n' ' ')
                log_cycle "$loop_count" "VERIFY_FAIL" "Code verification failed — rolling back: $VERIFY_SUMMARY"
                # 回滚 options_arbitrage_system 的代码修改
                cd "$PROJECT_DIR/projects/options_arbitrage_system" && git checkout -- . 2>/dev/null || true
                cd "$PROJECT_DIR" && git checkout -- . 2>/dev/null || true
                # 标记为失败
                cycle_failed_reason="Verification failed — code rolled back"
                error_count=$((error_count + 1))
                error_chain=$((error_chain + 1))
                # 把失败原因追加到共识
                if [ -f "$CONSENSUS_FILE" ]; then
                    sed -i '' "/^## What We Did This Cycle/a\\
- ⚠️ 验证失败回滚: ${VERIFY_SUMMARY}" "$CONSENSUS_FILE" 2>/dev/null || true
                fi
                # 走失败处理路径
                save_state "verify_fail"
                write_status_json "VERIFY_FAIL"
                sleep "$LOOP_INTERVAL"
                continue
            else
                log_cycle "$loop_count" "VERIFY_PASS" "Code verified OK"
            fi
        fi

        error_count=0
        error_chain=0
        rm -f "$PROJECT_DIR/.consensus-retry-count"
        stamp_consensus_timestamp
    else
        error_count=$((error_count + 1))
        error_chain=$((error_chain + 1))
        log_cycle "$loop_count" "FAIL" "$cycle_failed_reason (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE}, errors: $error_count/$MAX_CONSECUTIVE_ERRORS)"

        # ── Subtask breakdown detection ──
        # Engine ran but hit max-turns (API was fine, no 429/401, cost>0)
        # → next cycle should break task into smaller pieces
        if [ "$CYCLE_API_STATUS" = "0" ] && [ "$CYCLE_IS_ERROR" = "1" ] && [ "$CYCLE_COST" != "N/A" ] && [ "$CYCLE_COST" != "0" ]; then
            subtask_breakdown_flag=1
            log_cycle "$loop_count" "BREAKDOWN" "Detected max-turns-exceeded. Next cycle will auto-split task into subtasks."
        fi

        # Check for API auth/limit errors
        log "[DEBUG] CYCLE_API_STATUS=$CYCLE_API_STATUS, CYCLE_LIMIT_TYPE=$CYCLE_LIMIT_TYPE, CYCLE_IS_ERROR=$CYCLE_IS_ERROR"
        if [ "$CYCLE_API_STATUS" = "429" ] || [ "$CYCLE_API_STATUS" = "401" ]; then
            # Consensus restore: 401 always restore; 429 may keep partial progress
            if [ "$CYCLE_API_STATUS" = "429" ] && validate_consensus && consensus_changed_since_backup; then
                stamp_consensus_timestamp
                log_cycle "$loop_count" "PARTIAL" "429 hit but consensus was partially updated — keeping progress"
            else
                restore_consensus
            fi

            # ── 429 RPM limit (not quota) ──
            if [ "$CYCLE_API_STATUS" = "429" ] && [ "$CYCLE_LIMIT_TYPE" = "rpm" ]; then
                log_cycle "$loop_count" "RPM" "RPM rate limit. Waiting 180s then retry same key..."
                save_state "waiting_rpm"
                sleep 180
                error_count=0
                error_chain=0
                continue
            fi

            # ── 429 quota exhaustion ── rotate key immediately, no wait
            if [ "$CYCLE_API_STATUS" = "429" ]; then
                mark_key_exhausted
                rotate_api_key
                log_cycle "$loop_count" "QUOTA" "API quota exhausted. Key rotated immediately. Continue..."
                error_count=0
                error_chain=0
                continue
            fi

            # ── 401 expired key ── rotate immediately, no wait
            if [ "$CYCLE_API_STATUS" = "401" ]; then
                mark_key_exhausted
                rotate_api_key
                log_cycle "$loop_count" "AUTH" "API 401. Key rotated immediately. Continue..."
                error_count=0
                error_chain=0
                continue
            fi
            error_chain=0
            continue
        fi

        # Non-429 failure: restore consensus unconditionally
        restore_consensus

        # Exponential backoff on failure (chain: 1→10s, 2→20s, 3→40s, 4→80s, 5→160s, cap 300s)
        backoff_seconds=$(compute_backoff "$error_chain")
        log_cycle "$loop_count" "BACKOFF" "Exponential backoff: ${backoff_seconds}s (chain #${error_chain})"

        # Deadlock detection: check if Next Action is stuck
        if detect_next_action_stuck; then
            log_cycle "$loop_count" "STUCK" "Next Action unchanged for 3 cycles — forcing direction change"
            pivot_stuck_next_action
            error_chain=0
        fi

        # Write structured status for Dashboard
        write_status_json "FAIL"

        # Circuit breaker (uses backoff instead of fixed sleep)
        if [ "$error_count" -ge "$MAX_CONSECUTIVE_ERRORS" ]; then
            log_cycle "$loop_count" "BREAKER" "Circuit breaker tripped! Cooling down ${COOLDOWN_SECONDS}s..."
            save_state "circuit_break"
            sleep "$COOLDOWN_SECONDS"
            error_count=0
            error_chain=0
            rm -f "$PROJECT_DIR/.consensus-retry-count"
            log "Circuit breaker reset. Resuming..."
            continue
        fi

        save_state "idle"
        sleep "$backoff_seconds"
        continue
    fi

    save_state "idle"
    write_status_json "OK"
    save_cycle_head
    log_cycle "$loop_count" "WAIT" "Sleeping ${LOOP_INTERVAL}s before next cycle..."
    sleep "$LOOP_INTERVAL"
done
