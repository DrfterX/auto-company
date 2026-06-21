import { describe, it, expect } from 'vitest'
import { parseArgs } from './cli'

describe('CLI parseArgs', () => {
  it('parses default options', () => {
    const r = parseArgs(['node', 'cli.ts'])
    expect(r.opts.prTitle).toBe('Local Code Review')
    expect(r.opts.repo).toBe('local/repo')
    expect(r.opts.prNumber).toBe(0)
    expect(r.opts.format).toBe('pretty')
    expect(r.helpRequested).toBe(false)
    expect(r.versionRequested).toBe(false)
  })

  it('parses --file', () => {
    const r = parseArgs(['node', 'cli.ts', '--file', 'changes.diff'])
    expect(r.opts.file).toBe('changes.diff')
  })

  it('parses -f shorthand', () => {
    const r = parseArgs(['node', 'cli.ts', '-f', 'path/to/diff.patch'])
    expect(r.opts.file).toBe('path/to/diff.patch')
  })

  it('parses --pr-title', () => {
    const r = parseArgs(['node', 'cli.ts', '--pr-title', 'Fix login bug'])
    expect(r.opts.prTitle).toBe('Fix login bug')
  })

  it('parses --json flag', () => {
    const r = parseArgs(['node', 'cli.ts', '--json'])
    expect(r.opts.format).toBe('json')
  })

  it('parses -j shorthand', () => {
    const r = parseArgs(['node', 'cli.ts', '-j'])
    expect(r.opts.format).toBe('json')
  })

  it('parses --pr-body', () => {
    const r = parseArgs(['node', 'cli.ts', '--pr-body', 'Fixes the issue'])
    expect(r.opts.prBody).toBe('Fixes the issue')
  })

  it('parses --repo and --pr-number', () => {
    const r = parseArgs(['node', 'cli.ts', '--repo', 'myorg/myrepo', '--pr-number', '42'])
    expect(r.opts.repo).toBe('myorg/myrepo')
    expect(r.opts.prNumber).toBe(42)
  })

  it('parses --max-diff', () => {
    const r = parseArgs(['node', 'cli.ts', '--max-diff', '1000'])
    expect(r.opts.maxDiffLength).toBe(1000)
  })

  it('sets helpRequested on --help', () => {
    const r = parseArgs(['node', 'cli.ts', '--help'])
    expect(r.helpRequested).toBe(true)
    expect(r.versionRequested).toBe(false)
  })

  it('sets helpRequested on -h', () => {
    const r = parseArgs(['node', 'cli.ts', '-h'])
    expect(r.helpRequested).toBe(true)
  })

  it('sets versionRequested on --version', () => {
    const r = parseArgs(['node', 'cli.ts', '--version'])
    expect(r.versionRequested).toBe(true)
    expect(r.helpRequested).toBe(false)
  })

  it('sets versionRequested on -v', () => {
    const r = parseArgs(['node', 'cli.ts', '-v'])
    expect(r.versionRequested).toBe(true)
  })

  it('ignores unknown non-flag args silently', () => {
    const r = parseArgs(['node', 'cli.ts', 'some-file'])
    expect(r.opts.file).toBeUndefined()
  })

  it('throws on unknown flag option', () => {
    expect(() => parseArgs(['node', 'cli.ts', '--unknown-flag'])).toThrow()
  })
})