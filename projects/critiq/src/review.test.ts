import { describe, it, expect, vi, beforeEach } from 'vitest'

// Mock fetch before importing the module under test
const mockFetch = vi.fn()
vi.stubGlobal('fetch', mockFetch)

const { runReview } = await import('./review')

describe('runReview', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  const apiKey = 'sk-test-key'
  const prompt = 'Review this code please'

  it('returns parsed review result on success', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        id: 'test-123',
        choices: [{
          index: 0,
          message: { content: JSON.stringify({
            comments: [
              {
                path: 'src/app.ts',
                line: 10,
                body: '这里可能有一个内存泄漏',
                severity: 'warning',
                confidence: 'high',
                category: 'bug',
              },
            ],
            summary: '整体来看代码质量不错',
            overallScore: 7,
          }), role: 'assistant' },
          finish_reason: 'stop',
        }],
        usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
      }),
    })

    const result = await runReview(prompt, apiKey)
    expect(result.comments).toHaveLength(1)
    expect(result.comments[0].path).toBe('src/app.ts')
    expect(result.comments[0].severity).toBe('warning')
    expect(result.summary).toBe('整体来看代码质量不错')
    expect(result.overallScore).toBe(7)
    expect(result.tokenUsage.prompt).toBe(100)
    expect(result.tokenUsage.completion).toBe(50)
  })

  it('caps comments at 3 and removes empty entries', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        choices: [{
          message: { content: JSON.stringify({
            comments: [
              { path: 'a.ts', line: 1, body: 'bug 1', severity: 'critical', confidence: 'high', category: 'bug' },
              { path: 'b.ts', line: 2, body: 'bug 2', severity: 'warning', confidence: 'medium', category: 'bug' },
              { path: 'c.ts', line: 3, body: 'bug 3', severity: 'info', confidence: 'low', category: 'style' },
              { path: 'd.ts', line: 4, body: 'bug 4', severity: 'warning', confidence: 'medium', category: 'bug' },
              { path: 'e.ts', line: 5, body: 'bug 5', severity: 'info', confidence: 'low', category: 'performance' },
              {},
              { body: 'no path' },
              { path: 'x.ts', line: 1, body: '', severity: 'critical', confidence: 'high', category: 'bug' },
            ],
            summary: 'Has issues',
            overallScore: 5,
          }), role: 'assistant' },
        }],
        usage: { prompt_tokens: 200, completion_tokens: 100, total_tokens: 300 },
      }),
    })

    const result = await runReview(prompt, apiKey)
    // 5 valid comments → capped to 3
    expect(result.comments.length).toBeLessThanOrEqual(3)
    // All results should have path and body
    for (const c of result.comments) {
      expect(c.path).toBeTruthy()
      expect(c.body).toBeTruthy()
    }
  })

  it('returns default values on parse failure', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        choices: [{
          message: { content: 'invalid json{', role: 'assistant' },
          finish_reason: 'stop',
        }],
        usage: { prompt_tokens: 50, completion_tokens: 10, total_tokens: 60 },
      }),
    })

    const result = await runReview(prompt, apiKey)
    expect(result.comments).toEqual([])
    expect(result.summary).toBe('Failed to parse review output')
    expect(result.overallScore).toBe(5)
  })

  it('clamps overallScore between 1 and 10', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: JSON.stringify({
          comments: [],
          summary: 'Score test',
          overallScore: 0,
        }), role: 'assistant' } }],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
      }),
    })

    let result = await runReview(prompt, apiKey)
    expect(result.overallScore).toBe(1) // clamped from 0

    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: JSON.stringify({
          comments: [],
          summary: 'Score test 2',
          overallScore: 99,
        }), role: 'assistant' } }],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
      }),
    })

    result = await runReview(prompt, apiKey)
    expect(result.overallScore).toBe(10) // clamped from 99
  })

  it('throws on API error', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: false,
      status: 401,
      text: async () => 'Invalid API key',
    })

    await expect(runReview(prompt, apiKey)).rejects.toThrow(/AI API error.*401/)
  })

  it('passes correct request body to API', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: '{}', role: 'assistant' } }],
        usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
      }),
    })

    await runReview(prompt, apiKey)

    const callUrl = mockFetch.mock.calls[0][0]
    const callOpts = mockFetch.mock.calls[0][1]

    expect(callUrl).toBe('https://api.deepseek.com/v1/chat/completions')
    expect(callOpts.method || 'GET').toBe('POST')
    expect(callOpts.headers.Authorization).toBe('Bearer sk-test-key')
    expect(callOpts.headers['Content-Type']).toBe('application/json')

    const body = JSON.parse(callOpts.body)
    expect(body.model).toBe('deepseek-chat')
    expect(body.temperature).toBe(0.1)
    expect(body.max_tokens).toBe(2048)
    expect(body.response_format).toEqual({ type: 'json_object' })
  })
})