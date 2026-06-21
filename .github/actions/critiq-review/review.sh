#!/usr/bin/env bash
# ===========================================================================
# Critiq — GitHub Action Review Script
# ===========================================================================
# Called by the critiq-review composite action.  Runs Critiq on the PR diff,
# posts inline review comments and a summary via the GitHub API, and
# optionally fails the CI job when critical issues are found.
#
# Environment variables (set by action.yml):
#   API_KEY        — LLM provider API key
#   GITHUB_TOKEN   — GitHub token with pull requests: write scope
#   FAIL_ON_ISSUES — "true" to fail CI on critical findings
#   CRITIQ_DIR     — absolute path to Critiq project root
#   REVIEW_SCRIPT  — path to this script (set by action.yml)
#
# GitHub Actions built-in env:
#   GITHUB_REPOSITORY — owner/repo
#   GITHUB_EVENT_PATH — path to the event payload JSON
# ===========================================================================
set -euo pipefail

API_KEY="${API_KEY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
FAIL_ON_ISSUES="${FAIL_ON_ISSUES:-false}"
CRITIQ_DIR="${CRITIQ_DIR:-${GITHUB_WORKSPACE:-}}"

# ── Guard: required inputs ──
if [ -z "$API_KEY" ]; then
  echo "::error::API_KEY is required. Set the api-key input or CRITIQ_API_KEY env var."
  exit 1
fi
if [ -z "$GITHUB_TOKEN" ]; then
  echo "::error::GITHUB_TOKEN is required. Set the github-token input."
  exit 1
fi
if [ ! -f "$GITHUB_EVENT_PATH" ]; then
  echo "::error::GITHUB_EVENT_PATH not found: $GITHUB_EVENT_PATH"
  exit 1
fi

# ── Read PR info from event payload ──
PR_NUMBER=$(jq -r '.pull_request.number // 0' "$GITHUB_EVENT_PATH")
HEAD_SHA=$(jq -r '.pull_request.head.sha // ""' "$GITHUB_EVENT_PATH")
BASE_REF=$(jq -r '.pull_request.base.ref // ""' "$GITHUB_EVENT_PATH")
REPO_FULL_NAME="${GITHUB_REPOSITORY:-}"

if [ "$PR_NUMBER" -eq 0 ] || [ -z "$HEAD_SHA" ]; then
  echo "::error::This action only runs on pull_request events (no PR number or head SHA found)."
  exit 1
fi

echo "::group::Critiq Review"
echo "Reviewing ${REPO_FULL_NAME}#${PR_NUMBER} (base: ${BASE_REF})"

# ── Get diff via git ──
echo "Fetching base ref origin/${BASE_REF}..."
git fetch origin "$BASE_REF" 2>&1 | sed 's/^/  /' || echo "  (fetch may already be local)"

echo "Computing diff..."
DIFF_FILE=$(mktemp)
trap 'rm -f "$DIFF_FILE"' EXIT

if ! git diff "origin/${BASE_REF}...HEAD" > "$DIFF_FILE" 2>/dev/null; then
  # Fallback: use merge-base
  MERGE_BASE=$(git merge-base "origin/${BASE_REF}" HEAD 2>/dev/null || echo "")
  if [ -n "$MERGE_BASE" ]; then
    git diff "$MERGE_BASE" HEAD > "$DIFF_FILE"
    echo "  (used merge-base: ${MERGE_BASE})"
  else
    echo "::error::Could not compute diff from PR base."
    echo "::endgroup::"
    exit 1
  fi
fi

DIFF_SIZE=$(wc -c < "$DIFF_FILE" | tr -d ' ')
echo "Diff size: ${DIFF_SIZE} bytes"

if [ "$DIFF_SIZE" -lt 10 ]; then
  echo "Diff too small — nothing to review. Skipping."
  echo "::endgroup::"
  exit 0
fi

# ── Run Critiq (use pre-built CLI) ──
echo "Running Critiq..."
export CRITIQ_API_KEY="$API_KEY"

RESULT_FILE=$(mktemp)
trap 'rm -f "$DIFF_FILE" "$RESULT_FILE"' EXIT

CRITIQ_CLI="${CRITIQ_DIR}/dist/cli.js"
if [ ! -f "$CRITIQ_CLI" ]; then
  echo "::error::Critiq CLI not found at ${CRITIQ_CLI}"
  echo "Build it first: cd ${CRITIQ_DIR} && npm ci && node build.mjs"
  echo "::endgroup::"
  exit 1
fi

node "$CRITIQ_CLI" \
  --file "$DIFF_FILE" \
  --json \
  --pr-title "PR #${PR_NUMBER} Review" \
  --repo "$REPO_FULL_NAME" \
  --pr-number "$PR_NUMBER" \
  > "$RESULT_FILE" 2> >(sed 's/^/  [critiq] /' >&2) || {
    echo "::error::Critiq CLI failed."
    echo "::endgroup::"
    exit 1
  }

# ── Parse results ──
COMMENT_COUNT=$(jq '.comments | length' "$RESULT_FILE")
OVERALL_SCORE=$(jq '.overallScore // 0' "$RESULT_FILE")
SUMMARY=$(jq -r '.summary // "No significant issues found."' "$RESULT_FILE")
CRITICAL_COUNT=$(jq '[.comments[] | select(.severity == "critical")] | length' "$RESULT_FILE")

echo "Results: $COMMENT_COUNT comments, score ${OVERALL_SCORE}/10, ${CRITICAL_COUNT} critical"

# ── Save result for downstream steps ──
cp "$RESULT_FILE" /tmp/critiq-result.json

# ── Post inline comments ──
if [ "$COMMENT_COUNT" -gt 0 ]; then
  echo "Posting ${COMMENT_COUNT} inline comment(s)..."
  jq -c '.comments[]' "$RESULT_FILE" | while read -r comment; do
    COMMENT_PATH=$(echo "$comment" | jq -r '.path')
    COMMENT_LINE=$(echo "$comment" | jq -r '.line // 1')
    COMMENT_SEVERITY=$(echo "$comment" | jq -r '.severity // "info"')
    COMMENT_CATEGORY=$(echo "$comment" | jq -r '.category // ""')
    COMMENT_BODY=$(echo "$comment" | jq -r '.body')
    COMMENT_CONFIDENCE=$(echo "$comment" | jq -r '.confidence // ""')

    # Build markdown body
    MD="**Critiq — ${COMMENT_SEVERITY}**"
    [ -n "$COMMENT_CATEGORY" ] && MD="${MD} [${COMMENT_CATEGORY}]"
    [ -n "$COMMENT_CONFIDENCE" ] && MD="${MD} (${COMMENT_CONFIDENCE} confidence)"
    MD="${MD}

${COMMENT_BODY}"

    curl -sf -X POST \
      "https://api.github.com/repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/comments" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/vnd.github.v3+json" \
      -d "$(jq -n \
        --arg body "$MD" \
        --arg path "$COMMENT_PATH" \
        --argjson line "$COMMENT_LINE" \
        --arg commit_id "$HEAD_SHA" \
        '{body: $body, path: $path, line: $line, commit_id: $commit_id}'
      )" > /dev/null && \
      echo "  Comment on ${COMMENT_PATH}:${COMMENT_LINE}" || \
      echo "  ::warning::Failed to post comment on ${COMMENT_PATH}:${COMMENT_LINE}"
  done
fi

# ── Post review summary as PR issue comment ──
SEVERITY_BADGE=""
if [ "$CRITICAL_COUNT" -gt 0 ]; then
  SEVERITY_BADGE="![Critical](https://img.shields.io/badge/critical-${CRITICAL_COUNT}-red)"
elif [ "$COMMENT_COUNT" -gt 0 ]; then
  SEVERITY_BADGE="![Info](https://img.shields.io/badge/issues-${COMMENT_COUNT}-yellow)"
else
  SEVERITY_BADGE="![Clean](https://img.shields.io/badge/clean-passing-green)"
fi

SUMMARY_BODY="## 🤖 Critiq Review

${SUMMARY}

${SEVERITY_BADGE}

| Metric | Value |
|--------|-------|
| Score | ${OVERALL_SCORE}/10 |
| Comments | ${COMMENT_COUNT} |
| Critical | ${CRITICAL_COUNT} |

---

> 💡 AI-generated review — always exercise your own judgment.
> Powered by [Critiq](https://github.com/DrfterX/critiq)"

curl -sf -X POST \
  "https://api.github.com/repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/comments" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/vnd.github.v3+json" \
  -d "$(jq -n --arg body "$SUMMARY_BODY" '{body: $body}')" > /dev/null && \
  echo "Summary comment posted." || \
  echo "::warning::Failed to post review summary comment."

echo "::endgroup::"

# ── Fail CI if critical issues and fail-on-issues is true ──
if [ "$FAIL_ON_ISSUES" = "true" ] && [ "$CRITICAL_COUNT" -gt 0 ]; then
  echo "::error::Critiq found ${CRITICAL_COUNT} critical issue(s). Failing CI as configured (fail-on-issues=true)."
  exit 1
fi

echo "Critiq review completed successfully."