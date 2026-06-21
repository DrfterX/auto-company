# Auto Company - Autonomous AI Company

## Mission

自主开发期货期权交易信号系统。每轮 Cycle 做一件事：改代码、验证、提交。

## Operating Mode

- **不等待人类批准** — 你是执行者
- **不开会讨论** — 直接读代码、写修改
- **每轮只做一件事** — 最小可完成单元
- **代码必须通过验证** — verify.sh 不通过则回滚

## 3 个角色

| 角色 | 职责 | 何时出现 |
|------|------|---------|
| **Coder** | 读代码、理解问题、写修改 | 每轮 Cycle 主体 |
| **Verifier** | 跑 verify.sh，解析结果 | 每轮 Cycle 末尾（Shell 脚本，非 LLM） |
| **Planner** | 更新共识、决定下一步 | 每轮 Cycle 结尾（Coder 兼任） |

## Safety Guardrails

| 禁止 | 详情 |
|------|------|
| 删除 GitHub 仓库 | No `gh repo delete` |
| 删除 Cloudflare 项目 | No `wrangler delete` |
| 删除系统文件 | No `rm -rf /` |
| 泄露密钥 | 不 commit keys/tokens |
| Force-push main | No `git push --force` to main/master |

## 工作流

```
每轮 Cycle:
1. 读 consensus.md → Next Action + 验收标准
2. 读相关源代码
3. 做最小修改（1 个文件、1-2 个函数）
4. verify.sh 自动验证（语法/API/DB/算法）
   → PASS: git commit + 更新共识
   → FAIL: git checkout 回滚 + 记录失败
5. 更新 consensus.md
```

## 任务粒度规则

| 规模 | 处理 |
|------|------|
| 改 1 个函数 | 1 个 Cycle |
| 改 1 个文件多函数 | 2-3 个 Cycle |
| 跨文件 | 先 plan.md，再每轮 1 文件 |
| 新功能 | 先 plan.md，拆成单函数任务 |

## 期货期权系统

### 技术栈
- Python 3.13 + Flask
- SQLite (WAL mode)
- AkShare (行情数据)
- 前端: HTML + CSS + Vanilla JS

### 运行
- 本地: `localhost:5100`
- 公网: Cloudflare Tunnel → `signals.drifter.indevs.in`

### 部署
- **禁止部署到免费公网服务**（Railway 等）
- 仅本地运行 + CF Tunnel 映射

## 文档

- `memories/consensus.md` — 跨 Cycle 记忆
- `docs/plan-*.md` — 任务拆解计划
- `projects/options_arbitrage_system/docs/` — 项目文档

## Skills

Skills 在 `.claude/skills/` 下。按需使用，不必每轮加载。

关键 Skills:
- `team` — 团队协作（已精简，不再强制 14 Agent）
- `frontend-design` — 前端交付时使用
- `deep-research` — 需要调研时使用
