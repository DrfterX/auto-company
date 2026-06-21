#!/bin/bash
# 备份状态检查 — 本机(Railway 备用) 健康监控
# 用于: auto-loop 健康检查 / cron 周期性监控

set -euo pipefail

LOCAL_URL="${LOCAL_URL:-http://127.0.0.1:5100}"
RAILWAY_URL="${RAILWAY_URL:-https://optionsarbitragesystem-production.up.railway.app}"
STATUS_FILE="/Users/ayong/projects/auto-company_test/logs/backup-status.json"

check_url() {
    local url="$1"
    local timeout="${2:-5}"
    curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null || echo "000"
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LOCAL_CODE=$(check_url "$LOCAL_URL" 3)
RAILWAY_CODE=$(check_url "$RAILWAY_URL" 10)

LOCAL_OK=false
RAILWAY_OK=false
[ "$LOCAL_CODE" = "200" ] && LOCAL_OK=true
[ "$RAILWAY_CODE" = "200" ] && RAILWAY_OK=true

# 判断主/备模式
if $LOCAL_OK; then
    MODE="PRIMARY"
    STATUS="本机主用 — Railway 备用就绪"
elif $RAILWAY_OK; then
    MODE="FALLBACK"
    STATUS="本机不可用 — Railway 接管中"
else
    MODE="DOWN"
    STATUS="本机和 Railway 均不可达"
fi

# 写入 JSON 状态
cat > "$STATUS_FILE" << EOF
{
  "timestamp": "$NOW",
  "mode": "$MODE",
  "local": {
    "url": "$LOCAL_URL",
    "code": "$LOCAL_CODE",
    "healthy": $LOCAL_OK
  },
  "railway": {
    "url": "$RAILWAY_URL",
    "code": "$RAILWAY_CODE",
    "healthy": $RAILWAY_OK
  },
  "status": "$STATUS"
}
EOF

# 输出结果
echo "=== 备份状态: $MODE ==="
echo "本机:   $LOCAL_CODE ($([ "$LOCAL_OK" = "true" ] && echo '✅' || echo '❌'))"
echo "Railway: $RAILWAY_CODE ($([ "$RAILWAY_OK" = "true" ] && echo '✅' || echo '❌'))"
echo "状态:   $STATUS"
echo "文件:   $STATUS_FILE"
