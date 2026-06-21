# Critiq — Zero-noise AI Code Review Agent

[![npm](https://img.shields.io/npm/v/critiq-cli)](https://www.npmjs.com/package/critiq-cli)
[![npm downloads](https://img.shields.io/npm/dm/critiq-cli)](https://www.npmjs.com/package/critiq-cli)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub](https://img.shields.io/github/stars/DrfterX/critiq?style=social)](https://github.com/DrfterX/critiq)
[![monito](https://monito.yycomyy.workers.dev/api/badge.svg)](https://monito.yycomyy.workers.dev)

**Critiq** brings AI-powered code review to your terminal — focused, low-noise, and language-agnostic.

> One principle: catch real bugs, security flaws, and performance issues. Skip the style nitpicks.

## Quick Start

```bash
# via npm (recommended)
npx critiq-cli < diff.patch

# via install script
curl -fsSL https://raw.githubusercontent.com/DrfterX/critiq/main/scripts/install.sh | bash

# review current changes
git diff HEAD | critiq
```

Set `CRITIQ_API_KEY` (any OpenAI/Anthropic-compatible API) and you're ready.

## Demo

![Critiq in action](assets/demo.gif)

*A terminal recording of critiq reviewing a sample diff — detecting a SQL injection, a cache key bug, and a JWT encoding issue.*

## Why Critiq?

**Critiq is not just "an AI wrapper around DeepSeek".** It's a carefully designed code review tool that solves real problems:

### vs. Just asking an AI ("review this code")

| | Direct AI Prompt | Critiq |
|---|:---:|:---:|
| Noise control | None — AI lists everything it notices | Hard cap at 3 comments, silence when nothing is wrong |
| Consistency | Depends on how you phrase the prompt | Stable prompt engineering, same rules every time |
| Structured output | Random format, needs manual parsing | Standardized JSON: severity + confidence + score |
| Severity/Confidence | You judge yourself | `high/medium/low` + `critical/warning/info` on every comment |
| Ready to use | Need to write prompt, parse result, integrate | `git diff HEAD \| critiq` — done |

**In short:** Critiq is what you get when you take a generic AI and tune it specifically for code review — noise-cancelled, structured, and ready to use.

### vs. Other Code Review Tools

| Feature | Critiq | CodeRabbit | PR-Agent |
|---------|--------|------------|----------|
| Noisiness | ≤3 comments, real issues only | 10+ comments, noisy | Configurable |
| Pricing | Free + CLI / $9 mo SaaS | $12/mo+ | $29/mo+ |
| Model | DeepSeek V4 Flash | Proprietary | GPT-4 |
| Confidence Tag | ✅ high/medium/low | ❌ | ❌ |
| Local / Offline | ✅ CLI runs anywhere | ❌ SaaS only | ❌ SaaS only |
| Language | Chinese-first reviews | English | English |

## Adopted by Developers

![npm downloads](https://img.shields.io/npm/dm/critiq-cli) [![GitHub stars](https://img.shields.io/github/stars/DrfterX/critiq?style=social)](https://github.com/DrfterX/critiq)

**177+ downloads in the last month** · Zero-dependency CLI · 30-second setup · `git diff HEAD | critiq`

### From the Blog

Read the full story behind Critiq:
[**"Why I Built Yet Another Code Review Tool (and Why It's Different)"** →](https://critiq.pages.dev/blog/)

Covers architecture decisions, prompt engineering, the noise-first philosophy, and what makes Critiq different from CodeRabbit, PR-Agent, and raw AI prompts.

## Installation

### npm (recommended)

```bash
npm install -g critiq-cli
```

### One-line install (no npm account needed)

```bash
curl -fsSL https://raw.githubusercontent.com/DrfterX/critiq/main/scripts/install.sh | bash
```

What the script does:
1. ✅ Checks Node.js >= 18
2. ✅ Clones Critiq to `~/.critiq/`
3. ✅ Installs dependencies & builds
4. ✅ Registers `critiq` globally
5. ✅ Adds to `~/.bashrc` / `~/.zshrc` PATH

### Manual

```bash
git clone --depth 1 https://github.com/DrfterX/critiq.git ~/.critiq-source
cd ~/.critiq-source
npm install --silent && npm run build && npm link
```

## CLI Usage

```bash
# review current uncommitted changes
git diff HEAD | critiq

# review a specific commit
git show <commit> | critiq --pr-title "Commit message"

# review a PR diff
curl -L https://github.com/owner/repo/pull/123.diff | critiq --pr-title "Fix bug" --repo owner/repo --pr-number 123

# JSON output for CI integration
git diff main HEAD | critiq --json | jq '.comments'

# review from a file
critiq --file changes.diff --pr-title "My PR"
```

## GitHub Action (one-minute setup)

Create `.github/workflows/critiq-review.yml` in your repo:

```yaml
name: Critiq Code Review
on: [pull_request]
permissions:
  contents: read
  pull-requests: write
  issues: write
jobs:
  critiq-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Critiq Review
        uses: DrfterX/critiq/.github/actions/critiq-review@main
        with:
          api-key: ${{ secrets.CRITIQ_API_KEY }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

Then add `CRITIQ_API_KEY` to your repo's Secrets.

## Features

### ✅ Current
- [x] **CLI review**: `git diff | critiq` — review local code changes
- [x] **GitHub Action**: zero-config CI integration, posts inline comments on PRs
- [x] **Confidence scoring**: every comment tagged high/medium/low
- [x] **Chinese-first output**: reviews in Chinese, code stays in English
- [x] **JSON mode**: `--json` for CI/script integration

### 🚧 Roadmap
- [ ] **GitHub App**: auto-review via Cloudflare Workers
- [ ] **Web Dashboard**: review history in the browser
- [ ] **VS Code Extension**: in-editor instant review
- [ ] **GitLab / Bitbucket support**

## Options

```
USAGE:
  critiq [options]                   # read diff from stdin
  critiq --file <path>               # read diff from file
  cat diff.diff | critiq             # pipe

OPTIONS:
  -f, --file <path>       Read diff from file
  -t, --pr-title <text>   PR title (default: "Local Code Review")
  -b, --pr-body <text>    PR description (optional)
  -r, --repo <name>       Repo name (default: "local/repo")
  -n, --pr-number <num>   PR number (default: 0)
  -j, --json              Raw JSON output only
  --max-diff <bytes>      Max diff size (default: 40000)
  -h, --help              Show help

ENVIRONMENT:
  CRITIQ_API_KEY        Required. API key for any compatible provider.
  CRITIQ_API_BASE       API base URL (default: https://api.deepseek.com/v1)
  CRITIQ_MODEL          Model name (default: deepseek-chat)
```

## How It Works

1. Read diff (stdin or file)
2. Build review prompt with `buildReviewPrompt()` — diff context + review rules
3. Call AI API (DeepSeek / any compatible provider)
4. Parse JSON response, apply safety limits (≤3 comments, score 1-10)
5. Output review (pretty or JSON)

### Cost

DeepSeek V4 Flash costs ~**$0.01/million tokens**:
- 200-line diff → ~2K tokens
- Per review cost: ~**$0.00002**
- 1000 reviews/month: ~**$0.02**

## Development

```bash
git clone https://github.com/DrfterX/critiq.git
npm install
npm run typecheck
npm test

# local use
export CRITIQ_API_KEY=sk-xxx
git diff HEAD | npx tsx src/cli.ts
```

## Project Structure

```
critiq/
├── src/
│   ├── cli.ts           # CLI entry point
│   ├── review.ts        # API calling logic
│   ├── prompt.ts        # Review prompt engineering
│   ├── github.ts        # GitHub App auth (Worker)
│   ├── db.ts            # D1 database layer (Worker)
│   ├── index.ts         # Cloudflare Worker entry
│   └── types.ts         # Shared types
├── frontend/            # Landing page
├── migrations/          # D1 database migrations
├── sample/              # E2E tests
├── scripts/
│   ├── install.sh       # One-line install script
│   └── deploy-critiq.sh # Deployment script
├── action/              # GitHub Action
└── wrangler.toml        # Cloudflare Workers config
```

## License

MIT © DrfterX
