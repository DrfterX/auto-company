// Critiq — GitHub App authentication & PR event handler
import { GitHubPRPayload, ReviewResult } from './types'
import { buildReviewPrompt } from './prompt'
import { runReview } from './review'
import type { Bindings } from './index'

// ─── GitHub App JWT Auth ─────────────────────────────────────────────────────

/**
 * Generate a GitHub App JWT for API authentication.
 * JWT is signed with the app's private key and expires in 10 minutes.
 */
async function createAppJWT(appId: string, privateKeyPEM: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const payload = {
    iat: now - 60,            // issued 60s ago (clock drift tolerance)
    exp: now + 600,           // expires in 10 minutes
    iss: appId,
  }
  const encoder = new TextEncoder()
  const header = { alg: 'RS256', typ: 'JWT' }
  const headerB64 = b64url(encoder.encode(JSON.stringify(header)))
  const payloadB64 = b64url(encoder.encode(JSON.stringify(payload)))
  const signingInput = `${headerB64}.${payloadB64}`

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(privateKeyPEM),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  )
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, encoder.encode(signingInput))
  return `${signingInput}.${b64url(sig)}`
}

function b64url(buf: ArrayBuffer | Uint8Array): string {
  const u8 = buf instanceof Uint8Array ? buf : new Uint8Array(buf)
  return btoa(String.fromCharCode(...u8))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN [\w ]+-----/g, '')
    .replace(/-----END [\w ]+-----/g, '')
    .replace(/\s/g, '')
  const bytes = atob(b64)
  const buf = new Uint8Array(bytes.length)
  for (let i = 0; i < bytes.length; i++) buf[i] = bytes.charCodeAt(i)
  return buf.buffer as ArrayBuffer
}

// ─── Installation Access Token ───────────────────────────────────────────────

/**
 * Exchange a GitHub App JWT for an installation access token.
 * This token can be used to call the GitHub API on behalf of the installation.
 */
async function getInstallationToken(
  installationId: number,
  appId: string,
  privateKey: string,
): Promise<string> {
  const jwt = await createAppJWT(appId, privateKey)
  const url = `https://api.github.com/app/installations/${installationId}/access_tokens`
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      Accept: 'application/vnd.github.v3+json',
      Authorization: `Bearer ${jwt}`,
      'User-Agent': 'critiq',
    },
  })
  if (!response.ok) {
    const errText = await response.text()
    throw new Error(`GitHub API error getting installation token (${response.status}): ${errText}`)
  }
  const data = await response.json() as { token: string }
  return data.token
}

// ─── GitHub API Calls ────────────────────────────────────────────────────────

async function getPRDiff(
  repoFullName: string,
  prNumber: number,
  token: string,
): Promise<string> {
  const url = `https://api.github.com/repos/${repoFullName}/pulls/${prNumber}`
  const response = await fetch(url, {
    headers: {
      Accept: 'application/vnd.github.v3.diff',
      Authorization: `Bearer ${token}`,
      'User-Agent': 'critiq',
      'X-GitHub-Api-Version': '2022-11-28',
    },
  })
  if (!response.ok) {
    throw new Error(`GitHub API error (${response.status}) fetching diff for ${repoFullName}#${prNumber}`)
  }
  return response.text()
}

async function postPRComment(
  repoFullName: string,
  prNumber: number,
  body: string,
  path: string,
  line: number,
  headSha: string,
  token: string,
): Promise<void> {
  const url = `https://api.github.com/repos/${repoFullName}/pulls/${prNumber}/comments`
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      'User-Agent': 'critiq',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    body: JSON.stringify({ body, path, line, commit_id: headSha }),
  })
  if (!response.ok) {
    const errText = await response.text()
    console.error(`Failed to post comment on ${repoFullName}#${prNumber}: ${errText}`)
  }
}

async function postPRReviewSummary(
  repoFullName: string,
  prNumber: number,
  summary: string,
  token: string,
): Promise<void> {
  const url = `https://api.github.com/repos/${repoFullName}/issues/${prNumber}/comments`
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      'User-Agent': 'critiq',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    body: JSON.stringify({ body: summary }),
  })
  if (!response.ok) {
    const errText = await response.text()
    console.error(`Failed to post summary on ${repoFullName}#${prNumber}: ${errText}`)
  }
}

// ─── PR Event Handler ────────────────────────────────────────────────────────

export async function handlePREvent(
  payload: GitHubPRPayload,
  apiKey: string,
  privateKey: string,
  appId: string,
  installationId?: number,
  env?: Bindings,
): Promise<{ success: boolean; commentCount: number; error?: string }> {
  const { action, pull_request: pr, repository, number: prNumber } = payload

  // Only review on opened or synchronize (new commits pushed)
  if (action !== 'opened' && action !== 'synchronize') {
    return { success: true, commentCount: 0 }
  }

  // Skip merged PRs
  if (pr.merged) {
    return { success: true, commentCount: 0 }
  }

  const repoFullName = repository.full_name
  const headSha = pr.head.sha
  // Check if repo is eligible for free review
  // Private repos need a valid subscription; public repos are always free
  // For MVP: all repos are processed, subscription check comes later

  try {
    console.log(`[${repoFullName}#${prNumber}] Reviewing: "${pr.title}"`)

    // Get installation access token
    if (!installationId) {
      throw new Error('Missing installation ID')
    }
    const token = await getInstallationToken(installationId, appId, privateKey)

    // Get diff
    const diff = await getPRDiff(repoFullName, prNumber, token)
    if (!diff || diff.length < 10) {
      console.log(`[${repoFullName}#${prNumber}] Diff too small, skipping`)
      return { success: true, commentCount: 0 }
    }

    // Run review
    const systemPrompt = buildReviewPrompt(diff, pr.title, pr.body, repoFullName, prNumber)
    const result = await runReview(systemPrompt, apiKey, env)

    console.log(
      `[${repoFullName}#${prNumber}] ${result.comments.length} comments, score ${result.overallScore}`
    )

    // Post inline comments
    if (result.comments.length > 0) {
      for (const comment of result.comments) {
        await postPRComment(
          repoFullName, prNumber, comment.body,
          comment.path, comment.line, headSha, token,
        )
      }
    }

    // Post review summary
    const summaryBody = buildSummaryBody(result)
    await postPRReviewSummary(repoFullName, prNumber, summaryBody, token)

    return { success: true, commentCount: result.comments.length }
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error)
    console.error(`[${repoFullName}#${prNumber}] Failed: ${msg}`)
    return { success: false, commentCount: 0, error: msg }
  }
}

function buildSummaryBody(result: ReviewResult): string {
  const lines = [
    `## 🤖 Critiq Review`,
    ``,
    `${result.summary || 'No significant issues found.'}`,
    ``,
    `**Score**: ${result.overallScore}/10`,
  ]

  if (result.comments.length > 0) {
    const critical = result.comments.filter(c => c.severity === 'critical').length
    const warnings = result.comments.filter(c => c.severity === 'warning').length
    lines.push(`**Comments**: ${result.comments.length} (${critical} critical, ${warnings} warnings)`)
  }

  lines.push(
    ``,
    `---`,
    `> 💡 AI-generated review — always exercise your own judgment.`,
    `> [Feedback](https://critiq.dev/feedback) — was this review helpful? 👍 👎`,
  )

  return lines.join('\n')
}