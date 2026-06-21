#!/bin/bash
set -euo pipefail
# Set MODELSCOPE_API_KEY environment variable before running
MS_KEY="${MODELSCOPE_API_KEY:-}"
if [ -z "$MS_KEY" ]; then
  echo "Error: MODELSCOPE_API_KEY environment variable is not set"
  exit 1
fi

models=(
  "deepseek-ai/DeepSeek-V4-Flash"
  "deepseek-ai/DeepSeek-V4-Pro"
  "deepseek-ai/DeepSeek-V3.2"
  "deepseek-ai/DeepSeek-R1-0528"
  "MiniMax/MiniMax-M2.7"
  "Qwen/QVQ-72B-Preview"
  "Qwen/Qwen3-VL-235B-A22B-Instruct"
  "Qwen/Qwen3.5-122B-A10B"
  "Qwen/Qwen3.5-397B-A17B"
  "ZhipuAI/GLM-5.1"
  "moonshotai/Kimi-K2.5"
)

for model in "${models[@]}"; do
  printf "%-45s " "$model"
  resp=$(curl -s --max-time 25 -X POST "https://api-inference.modelscope.cn/v1/chat/completions" \
    -H "Authorization: Bearer $MS_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"say hi in 3 words\"}],\"max_tokens\":15}" 2>/dev/null)
  echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'choices' in d:
    c=d['choices'][0]['message']['content'][:40].replace('\n',' ')
    print(f'✅ {c}')
else:
    e=d.get('error',{})
    print(f'❌ {e.get(\"code\",\"\"):6s} {e.get(\"message\",str(d)[:60])}')
" 2>/dev/null || echo "❌ network error"
done
