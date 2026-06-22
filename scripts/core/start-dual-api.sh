#!/bin/bash
# Auto Company — 纯 SenseNova 启动（无降级）
# 主力: SenseNova DeepSeek V4 Flash (免费，每5小时刷新)
# 备用: 无 — 完全依赖主力，不可用则等待退避

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROXY_PORT=8082
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

cd "$PROJECT_DIR"

# ============================================
# 0. 加载 .env（必须先于代理启动，确保6个Key全注入）
# ============================================
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env"
    set +a
    echo "[${TIMESTAMP}] 📦 .env loaded"
fi

# ============================================
# 1. 启动 SenseNova 代理
# ============================================
# 从 hermes 配置中提取 API Keys（覆盖 .env 中的 AC_API_KEY_1）
SENSE_NOVA_KEY=$(python3 -c "
txt = open('$HOME/.hermes/config.yaml').read()
for line in txt.splitlines():
    s = line.strip()
    if 'api_key:' in s and 'sk-ygTf' in s:
        key = s.split('api_key:', 1)[1].strip()
        if key: print(key); break
" 2>/dev/null)

MODELSCOPE_KEY=$(python3 -c "
txt = open('$HOME/.hermes/config.yaml').read()
for line in txt.splitlines():
    s = line.strip()
    if 'api_key:' in s and 'ms-' in s:
        key = s.split('api_key:', 1)[1].strip()
        if key and len(key) > 30: print(key); break
" 2>/dev/null)

if [ -n "$SENSE_NOVA_KEY" ]; then
    export AC_API_KEY_1="$SENSE_NOVA_KEY"
fi
if [ -n "$MODELSCOPE_KEY" ]; then
    export MODELSCOPE_API_KEY="$MODELSCOPE_KEY"
fi

if ! lsof -ti:$PROXY_PORT >/dev/null 2>&1; then
    echo "[${TIMESTAMP}] 启动 SenseNova 代理 (端口 ${PROXY_PORT})..."
    python3 "$SCRIPT_DIR/sensenova-proxy.py" $PROXY_PORT &
    sleep 2
    if lsof -ti:$PROXY_PORT >/dev/null 2>&1; then
        echo "  ✅ SenseNova 代理已启动"
    else
        echo "  ❌ 代理启动失败"
        exit 1
    fi
else
    echo "[${TIMESTAMP}] SenseNova 代理已在运行"
fi

# ============================================
# 2. 快速连通性检测
# ============================================
echo "---"
echo "API 状态检查:"
STATUS=$(curl -sf http://127.0.0.1:${PROXY_PORT}/health 2>/dev/null || echo '{"status":"unreachable"}')
echo "  $(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print('🟢 SenseNova: 在线' if d.get('status')=='ok' else '🔴 SenseNova: 不可达')" 2>/dev/null || echo '🔴 代理健康检查失败')"

# ============================================
# 3. 启动 Auto Company
# ============================================
echo "---"
echo "启动 Auto Company 自主代理系统..."
echo "  模型: deepseek-v4-flash"
echo "  API 代理: http://127.0.0.1:${PROXY_PORT}"
echo "  主力: SenseNova (纯主力，无降级备份)"
echo "  工作目录: ${PROJECT_DIR}"
echo ""

# .env 已在步骤0加载，此处直接使用

export ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}"
export ANTHROPIC_API_KEY="${DEEPSEEK_API_KEY:-}"
export MODEL="deepseek-v4-flash"
export ENGINE="claude"
export CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
export CYCLE_TIMEOUT_SECONDS="1800"
export LOOP_INTERVAL="30"

exec ./scripts/core/auto-loop.sh 2>&1 | tee -a "$PROJECT_DIR/logs/auto-loop.log"