# Critiq — 零噪音 AI 代码审查

[![npm](https://img.shields.io/npm/v/critiq-cli)](https://www.npmjs.com/package/critiq-cli)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub](https://img.shields.io/github/stars/DrfterX/critiq?style=social)](https://github.com/DrfterX/critiq)
[![monito](https://monito.yycomyy.workers.dev/api/badge.svg)](https://monito.yycomyy.workers.dev)

**Critiq** 是一个 AI Code Review Agent，专为开发者设计。核心原则：**低噪声，高信号**。

> 只抓真实 bug、安全漏洞和性能问题，不做无意义的代码风格指责。

## 🚀 30 秒快速开始

```bash
# npm 安装（推荐）
npx critiq-cli < diff.patch

# 或一键安装（不需要 npm 账号）
curl -fsSL https://raw.githubusercontent.com/DrfterX/critiq/main/scripts/install.sh | bash

# 审查当前改动
git diff HEAD | critiq
```

设置环境变量 `CRITIQ_API_KEY`（支持 DeepSeek、ModelScope、OpenAI 等兼容 API）即可使用。

## 为什么用 Critiq？

**Critiq 不是简单的"套了个 DeepSeek 的壳"。** 它是一个精心设计的代码审查工具，解决了真实问题：

### vs. 直接让 AI 审查代码

| | 直接调 AI | Critiq |
|---|:---:|:---:|
| 噪声控制 | 无 — AI 把注意到的事全列出来 | 硬上限 3 条，没问题就沉默 |
| 一致性 | 看你怎么写 prompt，每次不一样 | 固定 prompt 工程，每次规则一致 |
| 输出格式 | 随机，需要手动解析 | 标准化 JSON：严重度 + 置信度 + 评分 |
| 是否即用 | 要写 prompt、解析结果、自己集成 | `git diff HEAD \| critiq` — 搞定 |

**一句话：** Critiq = 把通用 AI 精调成"只做代码审查"的专业工具 — 去噪、结构化、拿来就用。

### vs. 其他代码审查工具

| 特性 | Critiq | CodeRabbit | PR-Agent |
|------|--------|------------|----------|
| **噪声控制** | 3 条，只抓真实 bug | 常输出 10+ 条噪音 | 可配置但偏多 |
| **定价** | Free + CLI / $9 月 SaaS | $12/月起 | $29/月起 |
| **模型** | DeepSeek V4 Flash | 自研 | GPT-4 |
| **置信度标签** | high/medium/low | ❌ | ❌ |
| **离线使用** | CLI 本地运行 | SaaS only | SaaS only |
| **语言** | 中文优先 | 英文 | 英文 |

## 📦 安装

### npm 安装（推荐）

```bash
npm install -g critiq-cli
```

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/DrfterX/critiq/main/scripts/install.sh | bash
```

安装脚本会：
1. ✅ 检测 Node.js 版本（需 >= 18）
2. ✅ 克隆 Critiq 到 `~/.critiq/`
3. ✅ 安装依赖并构建
4. ✅ 全局注册 `critiq` 命令
5. ✅ 自动在 `~/.bashrc` / `~/.zshrc` 中添加 PATH

### 手动安装

```bash
git clone --depth 1 https://github.com/DrfterX/critiq.git ~/.critiq-source
cd ~/.critiq-source
npm install --silent && npm run build && npm link
```

## 🛠️ CLI 使用

```bash
# 审查当前改动
git diff HEAD | critiq

# 审查某个 commit
git show <commit> | critiq --pr-title "Commit message"

# 审查 PR diff
curl -L https://github.com/owner/repo/pull/123.diff | critiq --pr-title "Fix bug" --repo owner/repo --pr-number 123

# JSON 输出（方便 CI 集成）
git diff main HEAD | critiq --json | jq '.comments'

# 从文件读取 diff
critiq --file changes.diff --pr-title "My PR"
```

## GitHub Action 集成（一分钟配置）

在仓库中创建 `.github/workflows/critiq-review.yml`：

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

然后在 GitHub 仓库 Settings → Secrets 中添加 `CRITIQ_API_KEY`。

> ✅ Action 会自动在 PR 上发布**行内评论**和**汇总评分**。

## 功能

### ✅ 当前可用
- [x] **CLI 审查**: `git diff | critiq` — 审查本地代码改动
- [x] **GitHub Action**: 一键集成到 CI，自动在 PR 上发布行内评论
- [x] **JSON 输出**: `--json` 标志，方便 CI 集成
- [x] **置信度评估**: 每条评论标记 high/medium/low 置信度
- [x] **中文 Review**: 全部用中文输出，代码保留英文

### 🚧 Roadmap
- [ ] **GitHub App**: 通过 Cloudflare Workers 自动审查 PR
- [ ] **Dashboard**: Web 界面查看审查历史
- [ ] **VS Code 扩展**: 编辑器内即时审查
- [ ] **GitLab / Bitbucket 支持**: 多平台

## 参数

```
USAGE:
  critiq [options]                   # 从 stdin 读取 diff
  critiq --file <path>               # 从文件读取 diff
  cat diff.diff | critiq             # 管道

OPTIONS:
  -f, --file <path>       从文件读取 diff（替代 stdin）
  -t, --pr-title <text>   PR 标题（默认: "Local Code Review"）
  -b, --pr-body <text>    PR 描述（可选）
  -r, --repo <name>       仓库名（默认: "local/repo"）
  -n, --pr-number <num>   PR 编号（默认: 0）
  -j, --json              只输出原始 JSON
  --max-diff <bytes>      最大 diff 长度（默认: 40000）
  -h, --help              帮助

ENVIRONMENT:
  CRITIQ_API_KEY        必需。API Key（支持 DeepSeek、ModelScope、OpenAI 等）。
  CRITIQ_API_BASE       API Base URL（默认: https://api.deepseek.com/v1）
  CRITIQ_MODEL          模型名（默认: deepseek-chat）
```

## 如何工作

1. 读取 diff（从 stdin 或文件）
2. 用 `buildReviewPrompt()` 构建审查提示词 — 包含 diff 上下文和审查规则
3. 通过兼容 API 调用 AI 模型进行审查
4. 解析 JSON 响应，应用安全限制（最多 3 条 comment，评分 1-10）
5. 输出审查结果（pretty 或 JSON）

### API 调用成本

DeepSeek V4 Flash 定价约 **$0.01/百万 token**：
- 一个典型 PR 的 diff（200 行）消耗约 2K tokens
- 每次审查成本：约 **$0.00002**（几乎免费）
- 每月 1000 次审查：约 **$0.02**

## 开发

```bash
git clone https://github.com/DrfterX/critiq.git
npm install
npm run typecheck
npm test

# 本地使用
export CRITIQ_API_KEY=sk-xxx
git diff HEAD | npx tsx src/cli.ts
```

## 项目结构

```
critiq/
├── src/
│   ├── cli.ts           # CLI 入口
│   ├── review.ts        # API 调用逻辑
│   ├── prompt.ts        # 审查提示词工程
│   ├── github.ts        # GitHub App 认证（Worker 部署用）
│   ├── db.ts            # D1 数据库层（Worker 部署用）
│   ├── index.ts         # Cloudflare Worker 入口
│   └── types.ts         # 共享类型定义
├── frontend/            # Landing Page
├── migrations/          # D1 数据库迁移
├── sample/              # E2E 测试
├── scripts/
│   ├── install.sh       # 一键安装脚本
│   └── deploy-critiq.sh # 部署脚本
├── action/              # GitHub Action
└── wrangler.toml        # Cloudflare Workers 配置
```

## License

MIT © DrfterX
