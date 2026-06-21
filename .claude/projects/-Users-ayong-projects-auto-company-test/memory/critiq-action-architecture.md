---
name: critiq-action-architecture
description: Critiq GitHub Action 的架构决策和技术选型
metadata:
  type: project
---

# Critiq GitHub Action 架构

## 架构决策

- **复合 Action (composite action)** — 使用 GitHub Actions composite run steps，不需要额外的 Docker 镜像
- **预编译 CLI** — 审查逻辑在 `node dist/cli.js` 中预编译打包，不需要运行时编译
- **review.sh** 在 action 目录内，解析 `github.action_path` 找到自身路径
- **支持 ModelScope API** — 国内开发者可以通过 `CRITIQ_API_BASE` 和 `CRITIQ_MODEL` 环境变量配置

## 为什么不是 TypeScript Action

- Composite action 不需要发布到 npm，直接引用仓库路径即可
- 不需要编译和打包 action 代码
- 审查脚本 (shell) + CLI (Node) 分离更清晰

## 关键文件

- `.github/actions/critiq-review/action.yml` — Action 入口，定义 inputs/outputs
- `.github/actions/critiq-review/review.sh` — 审查脚本，处理 diff 获取、API 调用、评论发布
- `src/cli.ts` — CLI 入口，读取 diff 调用 LLM API
- `scripts/install.sh` — 安装脚本，包含 Action 使用说明

## 狗食验证

自己的 CI (`ci.yml`) 集成了 `critiq-self-review` job：
1. checkout + 构建
2. git diff 获取 PR 变更
3. `node dist/cli.js --json` 运行自审查
4. 结果输出到 CI logs

**Why:** 我们信任到什么程度，就狗食到什么深度。每个 PR 自动审查 Critiq 自己的代码。

**How to apply:**
- 添加新功能时，确保 ci.yml 中能跑通自审查
- 修改 review.sh 时测试复合 Action 的路径解析逻辑