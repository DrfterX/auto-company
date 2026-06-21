#!/bin/bash
# Auto Company 自主代理系统启动脚本
# 使用 SenseNova DeepSeek V4 Flash — 直接 Anthropic 协议，无 proxy

set -e

PROJECT_DIR="/Users/ayong/projects/auto-company_test"
cd "$PROJECT_DIR"

# 加载环境变量
source .env

# 设置 Claude CLI 环境变量 (直接连接 SenseNova Anthropic 端点)
export ANTHROPIC_AUTH_TOKEN="${SENSE_NOVA_API_KEY:-sk-placeholder}"
export ANTHROPIC_BASE_URL="https://token.sensenova.cn"
export ANTHROPIC_MODEL="deepseek-v4-flash"

echo "=========================================="
echo "  Auto Company 自主代理系统 - 启动"
echo "=========================================="
echo "API Base: ${ANTHROPIC_BASE_URL}"
echo "模型: ${ANTHROPIC_MODEL}"
echo "工作目录: ${PROJECT_DIR}"
echo "=========================================="

# 启动 Claude CLI 循环
# 使用 --allow-dangerously-skip-permissions 跳过权限检查
# 使用 --allowedTools 限制可用工具
claude \
  --allow-dangerously-skip-permissions \
  --allowedTools "Bash,Edit,Read,Write,Delete,Glob,LS,Find" \
  -p "你正在运行 Auto Company 自主代理系统。当前任务是：

1. 开发和完善期权期货交易系统（位于 ~/options_arbitrage_system/）
2. 了解现有代码架构，确定下一步优化方向
3. 每次改动必须 git commit（cd ~/options_arbitrage_system && git add -A && git commit -m 'msg'）
4. 考虑调用 critiq 审查代码改动（CRITIQ_API_KEY=sk-0b20340b98e24c43a2ca3d10e808c83c git diff | npx critiq-cli）
5. 每完成一个子任务更新共识文件 memoreis/consensus.md

运行时状态和操作结果记录到日志，等待下一个指令。

请开始执行第一个子任务。"
