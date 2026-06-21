import { describe, it, expect } from 'vitest'
import { buildReviewPrompt } from './prompt'

describe('buildReviewPrompt', () => {
  const sampleDiff = `diff --git a/src/app.ts b/src/app.ts
@@ -1,5 +1,6 @@
-const x = 1
-const y = 2
-console.log(x + y)
+const a = 1
+const b = 2
+const c = a + b
+console.log(c)`

  it('includes diff content in the prompt', () => {
    const prompt = buildReviewPrompt(sampleDiff, 'Refactor variables', null, 'user/repo', 42)
    expect(prompt).toContain(sampleDiff)
    expect(prompt).toContain('user/repo#42')
    expect(prompt).toContain('Refactor variables')
  })

  it('handles empty diff gracefully', () => {
    const prompt = buildReviewPrompt('', 'Empty PR', null, 'test/test', 1)
    expect(prompt).toContain('## Diff to Review')
  })

  it('includes PR body when provided', () => {
    const prompt = buildReviewPrompt(sampleDiff, 'Fix bug', 'This fixes a critical bug', 'org/repo', 7)
    expect(prompt).toContain('This fixes a critical bug')
  })

  it('states (none) when PR body is null', () => {
    const prompt = buildReviewPrompt(sampleDiff, 'No body', null, 'a/b', 3)
    expect(prompt).toContain('(none)')
  })

  it('truncates large diffs to 40000 chars', () => {
    const largeDiff = 'x'.repeat(50000)
    const prompt = buildReviewPrompt(largeDiff, 'Large diff', null, 'r/n', 1)
    // The prompt should contain at most ~40000 chars of diff
    const diffSection = prompt.split('```diff\n')[1]?.split('\n```')[0] || ''
    expect(diffSection.length).toBeLessThanOrEqual(40000)
  })

  it('enforces max 3 comments constraint', () => {
    const prompt = buildReviewPrompt(sampleDiff, 'Test', 'test', 'test/test', 1)
    expect(prompt).toMatch(/MAXIMUM 3 comments/i)
    expect(prompt).toMatch(/AT MOST 3 comments/i)
  })

  it('writes review in Chinese', () => {
    const prompt = buildReviewPrompt(sampleDiff, 'Test', null, 'test/test', 1)
    expect(prompt).toContain('中文')
    expect(prompt).toContain('Chinese')
  })
})