#!/usr/bin/env node
/**
 * Critiq Demo Script — produces realistic output for demo GIF
 * Mimics the exact output format of dist/cli.js printPretty()
 */

const path = process.argv[2] || 'sample/changes.diff';
const fs = await import('fs');
const diff = fs.readFileSync(path, 'utf-8');

const sevColor = (s) => {
  switch (s) {
    case 'critical': return '\x1b[31m';
    case 'warning':  return '\x1b[33m';
    case 'info':     return '\x1b[36m';
    default:         return '\x1b[0m';
  }
};

const result = {
  comments: [
    {
      path: 'src/api/users.ts',
      line: 27,
      body: 'SQL 注入风险：直接将用户输入的 id 拼接到查询中。应使用参数化查询 (PreparedStatement) 来防止 SQL 注入攻击。建议使用类似 `SELECT * FROM users WHERE id = $1` 的格式。',
      severity: 'critical',
      confidence: 'high',
      category: 'security'
    },
    {
      path: 'src/utils/cache.ts',
      line: 4,
      body: '缓存 key 填充逻辑有误：`padEnd(64)` 会改变原始 key，导致缓存无法命中。如需对齐，应在查询时统一处理或移除该逻辑。',
      severity: 'warning',
      confidence: 'medium',
      category: 'bug'
    },
    {
      path: 'src/auth.ts',
      line: 15,
      body: 'JWT 解码使用了 `atob()`，仅支持 ASCII。对于包含中文字符的 Base64 编码 payload，应使用 `Buffer.from().toString()` 确保兼容性。',
      severity: 'info',
      confidence: 'high',
      category: 'best-practice'
    }
  ],
  summary: '整体代码质量良好，包含一些重要改进。SQL 注入修复是关键问题，缓存 key 和 JWT 解码也有优化空间。建议优先修复 SQL 注入问题。',
  overallScore: 7,
  tokenUsage: { prompt: 1254, completion: 382 }
};

console.log('\n' + '─'.repeat(50));
console.log('  🤖  Critiq Review');
console.log('─'.repeat(50));

if (result.summary) {
  console.log(`\n  ${result.summary}\n`);
}

console.log(`  Score: ${'★'.repeat(Math.round(result.overallScore / 2))}${'☆'.repeat(5 - Math.round(result.overallScore / 2))}  ${result.overallScore}/10\n`);

for (const c of result.comments) {
  const color = sevColor(c.severity);
  console.log(`  ${color}${c.severity.toUpperCase()}\x1b[0m  ${c.path}:${c.line}`);
  console.log(`       [${c.category}] ${c.confidence} confidence`);
  console.log(`       ${c.body}\n`);
}

console.log('─'.repeat(50));
console.log(`  Tokens: ${result.tokenUsage.prompt + result.tokenUsage.completion} (↑${result.tokenUsage.prompt} ↓${result.tokenUsage.completion})`);
console.log('─'.repeat(50) + '\n');
