# 最终审查报告

## 发现并修复了 3 个问题

### 🔴 「会在运行时炸」— Bash 3.2 兼容性
macOS 自带的 bash 是 3.2 版本，不支持两个特性：

| 问题 | 位置 | 影响 |
|------|------|------|
| `local backoff_seconds` 在函数外 | auto-loop.sh:909 | ⚠️ 运行时报错 `local: can only be used in a function` |
| `$(( a > b ? c : d ))` 三元运算 | auto-loop.sh:587, 782 | ⚠️ bash 3.2 不支持该语法，运行时报错 |

均已修复为 if-else 写法。`bash -n` 不检查这两种错误（只在执行时抛），所以之前没发现。

### 🟡 新状态文件未 gitignore
`.quota-state.json` `.last-cycle-head` `.idle-skip-count` `.quota-wait-sec` `.next-action-history` 已加入 `.gitignore`。

---

## 架构一致性确认 ✅

| 组件 | 状态 |
|------|------|
| sensenova-proxy.py | 使用 SenseNova Key（sk-ygTf...），不转发请求 Key |
| auto-loop.sh | health check 查询 /health 端点，支持 QUOTA 三态 |
| start-dual-api.sh | 自动提取 SENSE_NOVA_API_KEY，无硬编码密钥 |
| 额度检测 | 三层：API 响应 + Token 计数 + 5h 窗口 |
| 闲置跳过 | git HEAD 对比，无变更跳过 LLM |
| 退避/死锁 | 指数退避 + 3 轮 stuck 自动 pivot |

## 已知取舍
- **控制台抓取未实现** — platform.sensenova.cn 是 SPA，API 响应检测已覆盖核心场景
- **流式响应不计数 Token** — 默认非流式模式走计数路径
- **proxy 重启乐观清空额度状态** — 自我修复（一次 API 调用后重检测）
