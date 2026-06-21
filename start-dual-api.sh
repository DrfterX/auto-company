#!/bin/bash
# Auto Company 一键启动（纯 SenseNova 版）
# 主力: SenseNova DeepSeek V4 Flash (免费)

cd "$(dirname "$0")"

echo "=========================================="
echo "  Auto Company - SenseNova 纯主力版"
echo "=========================================="
echo "  💚 主力: SenseNova (free, 5h刷新)"
echo "  策略: 不可用时等待退避，不切备用"
echo ""
echo "  启动命令:"
echo "    ./scripts/core/start-dual-api.sh"
echo "=========================================="

exec ./scripts/core/start-dual-api.sh