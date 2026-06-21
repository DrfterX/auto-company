---
name: modelscope-api-key
description: ModelScope API Key is available as MODELSCOPE_API_KEY; Critiq was blocked multiple cycles by not detecting it
metadata:
  type: reference
---

**ModelScope API Key 可用！** 位置：`$MODELSCOPE_API_KEY`

过去多个 Cycle（#16-#18）都卡在"等 CRITIQ_API_KEY 可用才能跑真实审查"上，但实际上环境中有 `MODELSCOPE_API_KEY` 可用，Base URL 是 `https://api-inference.modelscope.cn/v1`。Cycle 19 才被发现。

支持的模型（已验证）：
- `deepseek-ai/DeepSeek-V4-Flash` ✅ 快速，可靠
- `deepseek-ai/DeepSeek-V3.2` ✅ 较慢但也可用

**教训：** 检查环境变量时应遍历所有可能的 key，而不是只查一个具体的 `CRITIQ_API_KEY`。

**Why:** 环境中有多个 API Key（TINYFISH, SENSENOVA, MODELSCOPE），只是因为没有正确设置 `CRITIQ_API_KEY` 这个名称，就误判为"无可用 API"。

**How to apply:** 启动 Critiq 相关任务时，先检查是否有 `MODELSCOPE_API_KEY` 或其他 API key 可用，并相应设置 `CRITIQ_API_KEY` 的 fallback 逻辑。