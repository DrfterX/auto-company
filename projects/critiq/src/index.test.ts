import { describe, it, expect } from 'vitest'
import app from './index'

type JsonResponse = Record<string, unknown>

describe('Critiq API', () => {
  it('health check returns ok', async () => {
    const res = await app.request('/')
    expect(res.status).toBe(200)
    const body = await res.json() as JsonResponse
    expect(body.status).toBe('ok')
  })

  it('rejects missing webhook signature', async () => {
    const res = await app.request('/webhook', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    })
    expect(res.status).toBe(401)
  })

  it('accepts ping event with proper env bindings', async () => {
    const env = {
      GITHUB_APP_WEBHOOK_SECRET: 'test-secret',
    }
    const res = await app.request('/webhook', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-github-event': 'ping',
        'x-hub-signature-256': 'sha256=' + await sha256Hex('test-secret', JSON.stringify({ zen: 'test' })),
      },
      body: JSON.stringify({ zen: 'test' }),
    }, env)
    const body = await res.json() as JsonResponse
    expect(body.ok).toBe(true)
  })

  it('manual review rejects empty diff', async () => {
    const res = await app.request('/review', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        diff: '',
        prTitle: 'test',
        repoFullName: 'test/repo',
        prNumber: 1,
      }),
    })
    expect(res.status).toBe(400)
  })

  it('manual review rejects missing fields', async () => {
    const res = await app.request('/review', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ diff: 'some diff' }),
    })
    expect(res.status).toBe(400)
  })

  it('reviews list returns empty array initially', async () => {
    const env = {
      DB: {
        prepare: () => ({
          bind: () => ({
            all: async () => ({ results: [] }),
          }),
        }),
      },
    }
    const res = await app.request('/api/reviews', {}, env)
    const body = await res.json() as JsonResponse
    expect(body).toHaveProperty('prs')
    expect(Array.isArray(body.prs)).toBe(true)
  })
})

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