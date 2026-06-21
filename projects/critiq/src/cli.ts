// Critiq CLI — Local AI Code Review Tool
// Usage:
//   critiq < diff.diff                    # stdin
//   critiq --file diff.diff               # file
//   critiq --pr "Title" < diff.diff       # with PR title
//   critiq --help

import { realpathSync } from 'node:fs'
import { buildReviewPrompt } from './prompt'
import { runReview } from './review'

declare const VERSION: string // injected by esbuild define

interface CLIOptions {
  file?: string
  prTitle: string
  prBody?: string
  repo: string
  prNumber: number
  format: 'pretty' | 'json'
  maxDiffLength: number
}

interface ParseResult {
  opts: CLIOptions
  helpRequested: boolean
  versionRequested: boolean
}

function parseArgs(argv: string[]): ParseResult {
  const opts: CLIOptions = {
    prTitle: 'Local Code Review',
    repo: 'local/repo',
    prNumber: 0,
    format: 'pretty',
    maxDiffLength: 40000,
  }

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i]
    switch (arg) {
      case '--file':
      case '-f':
        opts.file = argv[++i]
        break
      case '--pr-title':
      case '-t':
        opts.prTitle = argv[++i]
        break
      case '--pr-body':
      case '-b':
        opts.prBody = argv[++i]
        break
      case '--repo':
      case '-r':
        opts.repo = argv[++i]
        break
      case '--pr-number':
      case '-n':
        opts.prNumber = parseInt(argv[++i], 10)
        break
      case '--json':
      case '-j':
        opts.format = 'json'
        break
      case '--max-diff':
        opts.maxDiffLength = parseInt(argv[++i], 10)
        break
      case '--version':
      case '-v':
        return { opts, helpRequested: false, versionRequested: true }
      case '--help':
      case '-h':
        return { opts, helpRequested: true, versionRequested: false }
      default:
        if (arg.startsWith('-')) {
          throw new Error(`Unknown option: ${arg}`)
        }
    }
  }

  return { opts, helpRequested: false, versionRequested: false }
}

function printHelp(): void {
  console.log(`
Critiq — Zero-noise AI Code Review Agent (CLI)

USAGE:
  critiq [options]                   # Read diff from stdin
  critiq --file <path>               # Read diff from file
  cat diff.diff | critiq             # Pipe diff

OPTIONS:
  -f, --file <path>       Read diff from file instead of stdin
  -t, --pr-title <text>   PR title (default: "Local Code Review")
  -b, --pr-body <text>    PR description (optional)
  -r, --repo <name>       Repo name (default: "local/repo")
  -n, --pr-number <num>   PR number (default: 0)
  -j, --json              Output raw JSON only
  --max-diff <bytes>      Max diff length to send (default: 40000)
  -h, --help              Show this help
  -v, --version           Show version number

ENVIRONMENT:
  CRITIQ_API_KEY          Required. Your API key (any OpenAI-compatible provider).
  CRITIQ_API_BASE         API base URL (default: https://api.deepseek.com/v1)
  CRITIQ_MODEL            Model name (default: deepseek-chat)
  DEEPSEEK_API_KEY        Deprecated fallback for CRITIQ_API_KEY.

EXAMPLES:
  critiq --file changes.diff --pr-title "Fix login bug"
  git diff main HEAD | critiq --pr-title "WIP changes" -j
  critiq -f my.diff -t "My PR" --json | jq '.comments'
`)
}

async function readDiff(opts: CLIOptions): Promise<string> {
  if (opts.file) {
    const fs = await import('fs')
    return fs.readFileSync(opts.file, 'utf-8')
  }

  // Read from stdin
  const chunks: Buffer[] = []
  for await (const chunk of process.stdin) {
    chunks.push(Buffer.from(chunk))
  }

  if (chunks.length === 0) {
    console.error('Error: No diff provided. Pipe a diff or use --file.')
    console.error('  git diff HEAD~1 | npx critiq')
    process.exit(1)
  }

  return Buffer.concat(chunks).toString('utf-8')
}

async function main(): Promise<void> {
  const parsed = parseArgs(process.argv)

  if (parsed.versionRequested) {
    console.log(`critiq-cli v${typeof VERSION !== 'undefined' ? VERSION : '0.0.0-dev'}`)
    return
  }

  if (parsed.helpRequested) {
    printHelp()
    return
  }

  const opts = parsed.opts
  const apiKey = process.env.CRITIQ_API_KEY || process.env.DEEPSEEK_API_KEY

  if (!apiKey) {
    console.error('Error: CRITIQ_API_KEY (or DEEPSEEK_API_KEY) environment variable is required.')
    console.error('  export CRITIQ_API_KEY=sk-your-key-here')
    process.exit(1)
  }

  const diff = await readDiff(opts)

  if (diff.length < 10) {
    console.log('Diff too small — nothing to review.')
    return
  }

  const prompt = buildReviewPrompt(
    diff.slice(0, opts.maxDiffLength),
    opts.prTitle,
    opts.prBody || null,
    opts.repo,
    opts.prNumber,
  )

  const result = await runReview(prompt, apiKey)

  if (opts.format === 'json') {
    console.log(JSON.stringify(result, null, 2))
    return
  }

  // Pretty output
  printPretty(result)
}

function printPretty(result: {
  comments: Array<{
    path: string
    line: number
    body: string
    severity: string
    confidence: string
    category: string
  }>
  summary: string
  overallScore: number
  tokenUsage: { prompt: number; completion: number }
}): void {
  const sevColor = (s: string) => {
    switch (s) {
      case 'critical': return '\x1b[31m' // red
      case 'warning':  return '\x1b[33m' // yellow
      case 'info':     return '\x1b[36m' // cyan
      default:         return '\x1b[0m'
    }
  }

  console.log('\n' + '─'.repeat(50))
  console.log('  🤖  Critiq Review')
  console.log('─'.repeat(50))

  if (result.summary) {
    console.log(`\n  ${result.summary}\n`)
  }

  console.log(`  Score: ${'★'.repeat(Math.round(result.overallScore / 2))}${'☆'.repeat(5 - Math.round(result.overallScore / 2))}  ${result.overallScore}/10\n`)

  if (result.comments.length === 0) {
    console.log('  ✅  No issues found — clean code!\n')
  } else {
    for (const c of result.comments) {
      const color = sevColor(c.severity)
      console.log(`  ${color}${c.severity.toUpperCase()}\x1b[0m  ${c.path}:${c.line}`)
      console.log(`       [${c.category}] ${c.confidence} confidence`)
      console.log(`       ${c.body}\n`)
    }
  }

  console.log('─'.repeat(50))
  console.log(`  Tokens: ${result.tokenUsage.prompt + result.tokenUsage.completion} (↑${result.tokenUsage.prompt} ↓${result.tokenUsage.completion})`)
  console.log('─'.repeat(50) + '\n')
}

// Run if executed directly (not when imported as module)
// We must resolve symlinks because npm global installs (`npm install -g`)
// create a symlinked bin entry, making process.argv[1] end with e.g. "critiq"
// rather than "cli.js".
const scriptPath = process.argv[1]
  ? (() => { try { return realpathSync(process.argv[1]) } catch { return process.argv[1] } })()
  : ''
const isMainModule = scriptPath.endsWith('cli.ts') || scriptPath.endsWith('cli.js')
if (isMainModule) {
  main().catch((err) => {
    console.error('Fatal error:', err instanceof Error ? err.message : String(err))
    process.exit(1)
  })
}

// Export for programmatic use
export { main, parseArgs, readDiff }