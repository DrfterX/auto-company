// Critiq — Shared types
export type Severity = 'critical' | 'warning' | 'info'
export type Confidence = 'high' | 'medium' | 'low'
export type Category = 'security' | 'bug' | 'performance' | 'style' | 'best-practice'
export type Plan = 'free' | 'pro' | 'team'
export type ReviewStatus = 'pending' | 'reviewing' | 'completed' | 'failed'

export interface ReviewComment {
  path: string
  line: number
  body: string
  severity: Severity
  confidence: Confidence
  category: Category
}

export interface ReviewResult {
  comments: ReviewComment[]
  summary: string
  overallScore: number
  tokenUsage: {
    prompt: number
    completion: number
  }
}

export interface GitHubPRPayload {
  action: string
  number: number
  pull_request: {
    html_url: string
    title: string
    body: string | null
    merged: boolean
    head: {
      sha: string
      ref: string
      repo: { full_name: string; clone_url: string }
    }
    base: {
      sha: string
      ref: string
      repo: { full_name: string; clone_url: string }
    }
    user: { login: string }
  }
  repository: {
    full_name: string
    private: boolean
  }
  installation?: {
    id: number
  }
}

export interface ReviewFeedback {
  commentId: string
  helpful: boolean
  feedbackText?: string
  userId?: string
  timestamp: string
}

export interface PRRecord {
  id: string
  repoFullName: string
  prNumber: number
  prTitle: string
  prAuthor: string
  prUrl: string
  status: ReviewStatus
  reviewSummary: string | null
  commentCount: number
  overallScore: number | null
  tokensUsed: number
  repoPrivate: boolean
  createdAt: string
  updatedAt: string
}

export interface UserRecord {
  id: string
  githubLogin: string
  email: string | null
  plan: Plan
  repoLimit: number
  prLimit: number
  createdAt: string
}

export interface InstallationRecord {
  id: string
  githubInstallationId: number
  accountLogin: string
  accountType: string
  repoSelection: string
  plan: Plan
  createdAt: string
  updatedAt: string
}