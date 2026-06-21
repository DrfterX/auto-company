#!/usr/bin/env bash
set -euo pipefail

# Critiq Smoke Test
# Run against a local wrangler dev instance

BASE_URL="${CRITIQ_BASE_URL:-http://localhost:8787}"
PASS=0
FAIL=0

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }

# 1. Health check
echo "=== Test 1: Health Check ==="
RESP=$(curl -sf "$BASE_URL/" 2>/dev/null || echo "FAILED")
if echo "$RESP" | grep -q '"status":"ok"'; then
  green "  PASS: Health check returned ok"
  PASS=$((PASS+1))
else
  red "  FAIL: Health check failed: $RESP"
  FAIL=$((FAIL+1))
fi

# 2. Ping webhook
echo "=== Test 2: Ping Webhook ==="
RESP=$(curl -sf -X POST "$BASE_URL/webhook" \
  -H "Content-Type: application/json" \
  -H "x-github-event: ping" \
  -d '{"zen":"testing"}' 2>/dev/null || echo "FAILED")
if echo "$RESP" | grep -q '"pong"'; then
  green "  PASS: Ping webhook responded"
  PASS=$((PASS+1))
else
  red "  FAIL: Ping webhook failed: $RESP"
  FAIL=$((FAIL+1))
fi

# 3. Manual review endpoint (no auth, just schema validation)
echo "=== Test 3: Manual Review Schema Validation ==="
RESP=$(curl -sf -X POST "$BASE_URL/review" \
  -H "Content-Type: application/json" \
  -d '{"diff":"","prTitle":"test","repoFullName":"test/repo","prNumber":1}' 2>/dev/null || echo "FAILED")
if echo "$RESP" | grep -q '"error"'; then
  green "  PASS: Empty diff properly rejected"
  PASS=$((PASS+1))
else
  red "  FAIL: Expected error for empty diff: $RESP"
  FAIL=$((FAIL+1))
fi

# 4. Missing fields
echo "=== Test 4: Missing Fields ==="
RESP=$(curl -sf -X POST "$BASE_URL/review" \
  -H "Content-Type: application/json" \
  -d '{"diff":"some diff"}' 2>/dev/null || echo "FAILED")
if echo "$RESP" | grep -q '"error"'; then
  green "  PASS: Missing fields properly rejected"
  PASS=$((PASS+1))
else
  red "  FAIL: Expected error for missing fields: $RESP"
  FAIL=$((FAIL+1))
fi

# 5. Large diff rejection
echo "=== Test 5: Large Diff Rejection ==="
LARGE_DIFF=$(python3 -c "print('x' * 60000)")
RESP=$(curl -sf -X POST "$BASE_URL/review" \
  -H "Content-Type: application/json" \
  -d "{\"diff\":\"$LARGE_DIFF\",\"prTitle\":\"test\",\"repoFullName\":\"test/repo\",\"prNumber\":1}" 2>/dev/null || echo "FAILED")
if echo "$RESP" | grep -q '"error"'; then
  green "  PASS: Large diff properly rejected"
  PASS=$((PASS+1))
else
  red "  FAIL: Expected error for large diff: $RESP"
  FAIL=$((FAIL+1))
fi

# 6. Reviews list endpoint (empty)
echo "=== Test 6: Reviews List ==="
RESP=$(curl -sf "$BASE_URL/reviews" 2>/dev/null || echo "FAILED")
if echo "$RESP" | grep -q '"prs"'; then
  green "  PASS: Reviews list returned"
  PASS=$((PASS+1))
else
  red "  FAIL: Reviews list failed: $RESP"
  FAIL=$((FAIL+1))
fi

# Summary
echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  green "All smoke tests passed! 🎉"
else
  red "Some tests failed ☹️"
  exit 1
fi