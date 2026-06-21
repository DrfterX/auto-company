#!/bin/bash
# Set CLOUDFLARE_API_TOKEN environment variable before running
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "Error: CLOUDFLARE_API_TOKEN environment variable is not set"
  exit 1
fi
# Test account access
echo "=== Account ID? ==="
curl -s --max-time 8 "https://api.cloudflare.com/client/v4/accounts" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);[print(f'{a[\"id\"]} {a[\"name\"]}') for a in d.get('result',[])]; print(f'Status: {\"✅\" if d.get(\"success\") else \"❌\"} {d.get(\"errors\",\"\")}')" 2>/dev/null
echo ""
echo "=== Wrangler whoami ==="
CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" /opt/homebrew/bin/wrangler whoami 2>&1 | tail -5
