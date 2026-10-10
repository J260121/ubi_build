#!/bin/bash
# ============================================================
# ImmortalWrt PassWall DIY Script
# 项目：J260121/ubi_build
# 功能：
#   1. 自动定位 ImmortalWrt 源码目录
#   2. 添加 PassWall 软件源
#   3. 更新 PassWall feed
#   4. 安装 luci-app-passwall
#   5. 配置 PassWall 及常用依赖
#   6. 避免重复添加 feed 和配置
#
# 支持从任意目录调用
# ============================================================

set -Eeuo pipefail

echo "================================================"
echo " ImmortalWrt PassWall Installer"
echo "================================================"

# Copy custom local packages into OpenWrt tree so they are available during build
if [ -d "$GITHUB_WORKSPACE/package/luci-compat-keep" ]; then
  mkdir -p package
  cp -r "$GITHUB_WORKSPACE/package/luci-compat-keep" package/
fi
echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default

echo
echo "PassWall preparation completed."
echo "源码目录：$OPENWRT_ROOT"
echo "=============================================="
