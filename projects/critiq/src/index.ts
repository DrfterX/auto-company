// Critiq — Main entry point (Cloudflare Worker)
import { Hono } from 'hono'
import { handlePREvent } from './github'
import { Database, setEnv } from './db'

export type Bindings = {
  PR_STATE: KVNamespace
  COMMENT_CACHE: KVNamespace
  DB: D1Database
  REVIEW_ARTIFACTS: R2Bucket
  DEEPSEEK_API_KEY: string
  GITHUB_APP_PRIVATE_KEY: string
  GITHUB_APP_WEBHOOK_SECRET: string
  GITHUB_APP_ID: string
  SESSION_SECRET: string
  // Critiq optional config (override defaults)
  CRITIQ_API_BASE?: string
  CRITIQ_MODEL?: string
  CRITIQ_API_KEY?: string
}

const app = new Hono<{ Bindings: Bindings }>()

// Health check
app.get('/', (c) => {
  return c.json({
    name: 'critiq',
    version: '0.1.1',
    status: 'ok',
    timestamp: new Date().toISOString(),
  })
})

// GitHub Webhook endpoint
app.post('/webhook', async (c) => {
  const env = c.env
  setEnv(env)

  // Verify webhook signature
  const signature = c.req.header('x-hub-signature-256')
  if (!signature) {
    return c.json({ error: 'Missing signature' }, 401)
  }

  const body = await c.req.text()
  const expectedSig = 'sha256=' + await sha256Hex(env.GITHUB_APP_WEBHOOK_SECRET, body)
  if (!constantTimeCompare(signature, expectedSig)) {
    return c.json({ error: 'Invalid signature' }, 401)
  }

  // Parse event type
  const eventType = c.req.header('x-github-event') || ''

  if (eventType === 'ping') {
    return c.json({ ok: true, message: 'pong' })
  }

  if (eventType !== 'pull_request') {
    return c.json({ ok: true, message: `Ignored: ${eventType}` })
  }

  let payload: any
  try {
    payload = JSON.parse(body)
  } catch {
    return c.json({ error: 'Invalid JSON' }, 400)
  }

  const result = await handlePREvent(
    payload,
    env.DEEPSEEK_API_KEY,
    env.GITHUB_APP_PRIVATE_KEY,
    env.GITHUB_APP_ID,
    payload.installation?.id,
    env,
  )

  return c.json(result)
})

// Direct review endpoint (for testing without GitHub App)
app.post('/review', async (c) => {
  const env = c.env
  const body = await c.req.json<{
    diff: string
    prTitle: string
    prBody?: string
    repoFullName: string
    prNumber: number
  }>()

  if (!body.diff || !body.prTitle || !body.repoFullName || !body.prNumber) {
    return c.json({ error: 'Missing required fields' }, 400)
  }

  const { buildReviewPrompt } = await import('./prompt')
  const { runReview } = await import('./review')
  const systemPrompt = buildReviewPrompt(body.diff, body.prTitle, body.prBody || null, body.repoFullName, body.prNumber)
  const result = await runReview(systemPrompt, env.DEEPSEEK_API_KEY, env)
  return c.json(result)
})

// List recent PR reviews
app.get('/api/reviews', async (c) => {
  const db = new Database(c.env as any)
  const limit = Math.min(100, parseInt(c.req.query('limit') || '20'))
  const offset = parseInt(c.req.query('offset') || '0')
  const prs = await db.listPRs(limit, offset)
  return c.json({ prs, total: prs.length })
})

// Feedback endpoint
app.post('/api/feedback', async (c) => {
  const db = new Database(c.env as any)
  const feedback = await c.req.json()
  await db.saveFeedback({
    commentId: feedback.commentId,
    helpful: feedback.helpful,
    feedbackText: feedback.feedbackText,
    userId: feedback.userId,
    timestamp: new Date().toISOString(),
  })
  return c.json({ ok: true })
})

// App installation status
app.get('/api/status', (c) => {
  return c.json({
    appName: 'critiq',
    appUrl: 'https://github.com/apps/critiq',
    docsUrl: 'https://critiq.dev/docs',
  })
})

// ─── Helpers ──────────────────────────────────────────────────────────────────

async function sha256Hex(secret: string, body: string): Promise<string> {
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw', encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false, ['sign'],
  )
  const sig = await crypto.subtle.sign('HMAC', key, encoder.encode(body))
  return Array.from(new Uint8Array(sig))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
}

function constantTimeCompare(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let result = 0
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i)
  }
  return result === 0
}

export default app