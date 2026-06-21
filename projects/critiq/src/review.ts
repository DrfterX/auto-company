import { ReviewResult } from './types'
import type { Bindings } from './index'

// Configurable via env vars — works with any OpenAI-compatible API
// e.g., DeepSeek, OpenAI, Alibaba DashScope, SiliconFlow, Moonshot, etc.
// Worker: env param; CLI/test: process.env fallback
export function getApiBase(env?: Bindings): string {
  return (env?.CRITIQ_API_BASE as string) || process.env.CRITIQ_API_BASE || 'https://api.deepseek.com/v1'
}

export function getModel(env?: Bindings): string {
  return (env?.CRITIQ_MODEL as string) || process.env.CRITIQ_MODEL || 'deepseek-chat'
}

export function resolveApiKey(key: string, env?: Bindings): string {
  // Accept any of these env vars (precedence order)
  return (env?.CRITIQ_API_KEY as string) || process.env.CRITIQ_API_KEY || key
}

interface DeepSeekMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

interface DeepSeekResponse {
  id: string
  choices: Array<{
    index: number
    message: {
      content: string
      role: string
    }
    finish_reason: string
  }>
  usage: {
    prompt_tokens: number
    completion_tokens: number
    total_tokens: number
  }
}

export async function runReview(
  systemPrompt: string,
  apiKey: string,
  env?: Bindings,
  signal?: AbortSignal
): Promise<ReviewResult> {
  const apiBase = getApiBase(env)
  const model = getModel(env)
  const resolvedKey = resolveApiKey(apiKey, env)
  const messages: DeepSeekMessage[] = [
    { role: 'system', content: systemPrompt },
    { role: 'user', content: '请审查以上 PR 的 diff，输出 JSON 格式的 review 结果。' },
  ]

  const response = await fetch(`${apiBase}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${resolvedKey}`,
    },
    body: JSON.stringify({
      model,
      messages,
      temperature: 0.1, // low temperature for deterministic review
      max_tokens: 2048,
      response_format: { type: 'json_object' },
    }),
    signal,
  })

  if (!response.ok) {
    const errText = await response.text()
    throw new Error(`AI API error (${response.status}): ${errText}`)
  }

  const data: DeepSeekResponse = await response.json()
  const content = data.choices?.[0]?.message?.content || '{}'

  let parsed: Partial<ReviewResult>
  try {
    parsed = JSON.parse(content)
  } catch {
    parsed = { comments: [], summary: 'Failed to parse review output', overallScore: 5 }
  }

  // Validate and sanitize
  const comments = (parsed.comments || [])
    .filter(c => c.path && c.body)
    .slice(0, 3) // hard cap at 3

  return {
    comments,
    summary: parsed.summary || '',
    overallScore: Math.max(1, Math.min(10, parsed.overallScore ?? 5)),
    tokenUsage: {
      prompt: data.usage?.prompt_tokens || 0,
      completion: data.usage?.completion_tokens || 0,
    },
  }
}