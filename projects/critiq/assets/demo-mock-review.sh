#!/usr/bin/env bash
# Wrap critiq output for demo recording
# Outputs realistic CLI review output without needing an API key
# Matches the exact format from src/cli.ts printPretty()

# Simulate API call delay
sleep 1

cat << 'OUTPUT'

──────────────────────────────────────────────────
  🤖  Critiq Review
──────────────────────────────────────────────────

  Found 2 potential issues in your diff — all worth a look before merge.

  Score: ★★★☆☆  6/10

  CRITICAL  src/auth.ts:142
       [security] high confidence
       Password reset token uses Math.random() instead of crypto.randomBytes().
       This produces ~32 bits of entropy — insufficient for security-critical tokens.
       Replace with: crypto.randomBytes(32).toString('hex')

  WARNING  src/api/handler.ts:67
       [bug] high confidence
       Missing null check after user lookup: `const user = await db.findUser(id)`
       followed by `user.email` without verifying user exists. If the ID is stale
       or invalid, this throws an unhandled TypeError at runtime.

──────────────────────────────────────────────────
  Tokens: 2148 (↑1520 ↓628)
──────────────────────────────────────────────────
OUTPUT