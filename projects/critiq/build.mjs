// Critiq build script — using esbuild
import * as esbuild from 'esbuild'
import { readFileSync, writeFileSync, existsSync } from 'fs'

const BANNER = '#!/usr/bin/env node'

async function main() {
  // 1. Bundle CLI (all deps inlined)
  await esbuild.build({
    entryPoints: ['src/cli.ts'],
    outfile: 'dist/cli.js',
    bundle: true,
    platform: 'node',
    target: 'node18',
    format: 'esm',
    banner: { js: BANNER },
  })

  // 2. Bundle library entry (for programmatic import)
  await esbuild.build({
    entryPoints: ['src/review.ts'],
    outfile: 'dist/review.js',
    bundle: true,
    platform: 'node',
    target: 'node18',
    format: 'esm',
  })

  // 3. Generate type declarations via tsc
  const { execSync } = await import('child_process')
  try {
    execSync('npx tsc --declaration --emitDeclarationOnly --outDir dist', {
      stdio: 'pipe',
    })
    console.log('Types: dist/review.d.ts ✓')
  } catch (e) {
    console.warn('Types: generation skipped (tsc declaration only)')
  }

  const cliSize = existsSync('dist/cli.js')
    ? `${(readFileSync('dist/cli.js').length / 1024).toFixed(1)} KB`
    : 'missing'
  console.log(`CLI:  dist/cli.js (${cliSize})`)
  console.log(`Lib:  dist/review.js ✓`)
}

main().catch((e) => {
  console.error('Build failed:', e)
  process.exit(1)
})