# Critiq GitHub Action

将 Critiq AI Code Review 集成到你的 GitHub CI 中，每次 PR 自动获得中文代码审查。

## 快速开始

在仓库 `.github/workflows/` 下创建 `critiq-review.yml`：

```yaml
name: Critiq Code Review

on:
  pull_request:
    types: [opened, synchronize]

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

## 配置参数

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `api-key` | 否* | — | LLM API Key。不填则自动读取 `CRITIQ_API_KEY` 或 `DEEPSEEK_API_KEY` 环境变量 |
| `github-token` | **是** | — | 用于发布评论的 GitHub Token，通常使用 `${{ secrets.GITHUB_TOKEN }}` |
| `fail-on-issues` | 否 | `false` | 设为 `true` 时，发现 critical 问题会 CI 失败 |
| `critiq-path` | 否 | `.` | Critiq 项目的路径（仅在仓库包含多个项目时需要） |

> \* `api-key` 可以不填，但必须设置 `CRITIQ_API_KEY` 或 `DEEPSEEK_API_KEY` 环境变量/Secret。

## 输出参数

| 输出 | 说明 |
|------|------|
| `comment-count` | 审查评论数量 |
| `overall-score` | 代码质量评分 (1–10) |
| `critical-count` | 严重问题数量 |

## 效果

Action 运行后会在 PR 上：

1. **行内评论** — 在每个问题代码行直接标注
2. **总体评论** — 在 PR 中添加一段汇总评分的评论

## 环境变量设置

### GitHub Secret 配置

```bash
# 1. 复制你的 LLM API Key
# DeepSeek: https://platform.deepseek.com/api_keys
# 或使用 ModelScope（国内推荐）: https://modelscope.cn/my/myaccesstoken

# 2. 添加到仓库 Secrets
gh secret set CRITIQ_API_KEY
gh secret set CRITIQ_API_BASE  # 可选, 默认 https://api.deepseek.com/v1
gh secret set CRITIQ_MODEL     # 可选, 默认 deepseek-chat
```

### API 提供商配置

Critiq 兼容任何 OpenAI-compatible API：

| 提供商 | CRITIQ_API_BASE | CRITIQ_MODEL |
|--------|----------------|--------------|
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |
| ModelScope (国内) | `https://api-inference.modelscope.cn/v1` | `deepseek-ai/DeepSeek-V4-Flash` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |

## 高级用法

### 严格模式（fail on critical issues）

```yaml
- name: Critiq Review
  uses: DrfterX/critiq/.github/actions/critiq-review@main
  with:
    api-key: ${{ secrets.CRITIQ_API_KEY }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
    fail-on-issues: 'true'
```

### 仅审查指定路径

```yaml
- name: Critiq Review
  uses: DrfterX/critiq/.github/actions/critiq-review@main
  with:
    api-key: ${{ secrets.CRITIQ_API_KEY }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
    critiq-path: ./my-subproject
```

### 使用 ModelScope（国内开发者首选）

```yaml
- name: Critiq Review
  uses: DrfterX/critiq/.github/actions/critiq-review@main
  env:
    CRITIQ_API_BASE: https://api-inference.modelscope.cn/v1
    CRITIQ_MODEL: deepseek-ai/DeepSeek-V4-Flash
  with:
    api-key: ${{ secrets.CRITIQ_API_KEY }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

## 工作原理

1. Action checkout 代码后，自动安装与构建 Critiq CLI
2. 通过 `git diff` 获取 PR 的代码变更
3. 调用 LLM API 审查 diff，生成结构化审查结果
4. 通过 GitHub API 将行内评论和汇总评论发布到 PR

## 本地测试

```bash
# 在项目中运行 Critiq 审查本地改动
git diff HEAD | npx critiq-cli
```

## 狗食文化

Critiq 的每一行代码都通过 Critiq 自审查。我们在自己的 CI 中集成了 Critiq Self-Review，每次 PR 都会自动审查 Critiq 自己的代码。

> 💡 我们信任到什么程度，就狗食到什么深度。

## 依赖

- Node.js 20+
- 一个 OpenAI-compatible API Key
- GitHub Token (pull-requests: write scope)