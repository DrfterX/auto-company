// Critiq — Database layer (D1 + KV)
import type { PRRecord, ReviewFeedback } from './types'

interface Env {
  DB: D1Database
  PR_STATE: KVNamespace
  COMMENT_CACHE: KVNamespace
}

function genId(): string {
  return crypto.randomUUID()
}

export class Database {
  private _db: D1Database
  private _env: Env

  constructor(bindings: Env) {
    this._env = bindings
    this._db = bindings.DB
  }

  // ─── PR Records ───────────────────────────────────────────────────────────
  // NOTE: savePR() removed — no route writes PR records, so the prs table
  // stays empty. getPR/listPRs are retained so /api/reviews still responds
  // (returns empty) without breaking the published API contract.

  async getPR(repoFullName: string, prNumber: number): Promise<PRRecord | null> {
    const row = await this._db.prepare(
      'SELECT * FROM prs WHERE repo_full_name = ? AND pr_number = ?'
    ).bind(repoFullName, prNumber).first<any>()
    return row ? mapRow(row) : null
  }

  async listPRs(limit = 20, offset = 0): Promise<PRRecord[]> {
    const { results } = await this._db.prepare(
      'SELECT * FROM prs ORDER BY created_at DESC LIMIT ? OFFSET ?'
    ).bind(limit, offset).all<any>()
    return results.map(mapRow)
  }

  // ─── Feedback ─────────────────────────────────────────────────────────────

  async saveFeedback(f: ReviewFeedback): Promise<void> {
    await this._db.prepare(`
      INSERT INTO feedback (id, comment_id, helpful, feedback_text, user_id, timestamp)
      VALUES (?, ?, ?, ?, ?, ?)
    `).bind(
      genId(), f.commentId, f.helpful ? 1 : 0,
      f.feedbackText || null, f.userId || null, f.timestamp,
    ).run()
  }

  // ─── KV Helpers ───────────────────────────────────────────────────────────

  async getPRState(repo: string, num: number): Promise<string | null> {
    return this._env.PR_STATE.get(`${repo}/${num}`)
  }
  async setPRState(repo: string, num: number, state: string): Promise<void> {
    await this._env.PR_STATE.put(`${repo}/${num}`, state, { expirationTtl: 86400 * 7 })
  }

  async getCachedComments(repo: string, num: number): Promise<string | null> {
    return this._env.COMMENT_CACHE.get(`${repo}/${num}`)
  }
  async setCachedComments(repo: string, num: number, data: string): Promise<void> {
    await this._env.COMMENT_CACHE.put(`${repo}/${num}`, data, { expirationTtl: 86400 * 30 })
  }
}

function mapRow(row: any): PRRecord {
  return {
    id: row.id,
    repoFullName: row.repo_full_name,
    prNumber: row.pr_number,
    prTitle: row.pr_title,
    prAuthor: row.pr_author,
    prUrl: row.pr_url,
    status: row.status,
    reviewSummary: row.review_summary,
    commentCount: row.comment_count,
    overallScore: row.overall_score,
    tokensUsed: row.tokens_used,
    repoPrivate: row.repo_private === 1,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}

// Closure workaround — setEnv is called once per request in index.ts
let _env: Env
export function setEnv(e: Env) { _env = e }
export function getEnv(): Env { return _env }