#!/usr/bin/env bash
set -e

OPENWRT_DIR="${OPENWRT_DIR:-$GITHUB_WORKSPACE/openwrt}"
cd "$OPENWRT_DIR"

echo "[HelloWorld] 开始集成..."

# 添加 HelloWorld 软件源
grep -qF 'helloworld' feeds.conf.default || \
  echo 'src-git helloworld https://github.com/fw876/helloworld.git' >> feeds.conf.default

# 更新并安装 HelloWorld
./scripts/feeds update helloworld
./scripts/feeds install -a -p helloworld

# 启用 LuCI 插件
cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-ssr-plus=y
EOF

make defconfig

echo "[HelloWorld] 集成完成"