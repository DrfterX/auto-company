#!/bin/bash
# Set the following environment variables before running:
#   MODELSCOPE_API_KEY - ModelScope API key
#   SENSENOVA_API_KEY  - SenseNova API key

MS_KEY="${MODELSCOPE_API_KEY:-}"
SN_KEY="${SENSENOVA_API_KEY:-}"

echo "=== ModelScope Rate Limit Headers ==="
if [ -n "$MS_KEY" ]; then
  curl -sI -X POST "https://api-inference.modelscope.cn/v1/chat/completions" \
    -H "Authorization: Bearer $MS_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"deepseek-ai/DeepSeek-V4-Flash","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' 2>/dev/null | grep -iE "rate|limit|quota|x-ratelimit|retry|x-ms|x-request|remaining" || echo "(no rate limit headers)"
else
  echo "(MODELSCOPE_API_KEY not set)"
fi

echo ""
echo "=== SenseNova Rate Limit Headers ==="
if [ -n "$SN_KEY" ]; then
  curl -sI -X POST "https://token.sensenova.cn/v1/chat/completions" \
    -H "Authorization: Bearer $SN_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' 2>/dev/null | grep -iE "rate|limit|quota|x-ratelimit|retry|x-sn" || echo "(no rate limit headers)"
else
  echo "(SENSENOVA_API_KEY not set)"
fi
