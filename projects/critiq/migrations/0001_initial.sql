-- Migration 0001: Initial schema for Critiq
-- Creates tables for PR reviews, feedback, and users

CREATE TABLE IF NOT EXISTS prs (
  id TEXT PRIMARY KEY,
  repo_full_name TEXT NOT NULL,
  pr_number INTEGER NOT NULL,
  pr_title TEXT NOT NULL,
  pr_author TEXT NOT NULL,
  pr_url TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'reviewing', 'completed', 'failed')),
  review_summary TEXT,
  comment_count INTEGER NOT NULL DEFAULT 0,
  overall_score INTEGER,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  repo_private INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(repo_full_name, pr_number)
);

CREATE INDEX idx_prs_repo ON prs(repo_full_name);
CREATE INDEX idx_prs_created ON prs(created_at DESC);
CREATE INDEX idx_prs_status ON prs(status);

CREATE TABLE IF NOT EXISTS review_comments (
  id TEXT PRIMARY KEY,
  pr_id TEXT NOT NULL,
  path TEXT NOT NULL,
  line INTEGER,
  body TEXT NOT NULL,
  severity TEXT NOT NULL CHECK(severity IN ('critical', 'warning', 'info')),
  confidence TEXT NOT NULL CHECK(confidence IN ('high', 'medium', 'low')),
  category TEXT NOT NULL CHECK(category IN ('security', 'bug', 'performance', 'style', 'best-practice')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (pr_id) REFERENCES prs(id) ON DELETE CASCADE
);

CREATE INDEX idx_comments_pr ON review_comments(pr_id);

CREATE TABLE IF NOT EXISTS feedback (
  id TEXT PRIMARY KEY,
  comment_id TEXT NOT NULL,
  helpful INTEGER NOT NULL DEFAULT 1,
  feedback_text TEXT,
  user_id TEXT,
  timestamp TEXT NOT NULL
);

CREATE INDEX idx_feedback_comment ON feedback(comment_id);

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  github_login TEXT UNIQUE NOT NULL,
  email TEXT,
  plan TEXT NOT NULL DEFAULT 'free' CHECK(plan IN ('free', 'pro', 'team')),
  repo_limit INTEGER NOT NULL DEFAULT 3,
  pr_limit INTEGER NOT NULL DEFAULT 100,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_users_github ON users(github_login);
CREATE INDEX idx_users_plan ON users(plan);

CREATE TABLE IF NOT EXISTS installations (
  id TEXT PRIMARY KEY,
  github_installation_id INTEGER UNIQUE NOT NULL,
  account_login TEXT NOT NULL,
  account_type TEXT NOT NULL DEFAULT 'user',
  repo_selection TEXT NOT NULL DEFAULT 'selected',
  plan TEXT NOT NULL DEFAULT 'free',
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_installations_account ON installations(account_login);