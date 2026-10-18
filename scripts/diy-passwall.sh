#!/bin/bash
# ImmortalWrt DIY - PassWall 2
set -e

OPENWRT_ROOT="${OPENWRT_ROOT:-/workdir/openwrt}"
cd "$OPENWRT_ROOT"

echo "[PassWall] 开始集成 PassWall 2..."

clone_repo() {
    local url="$1"
    local dir="$2"

    if [ -d "$dir/.git" ]; then
        echo "[PassWall] 已存在：$dir"
        return
    fi

    if [ -e "$dir" ]; then
        echo "[PassWall] 错误：目录已存在但不是 Git 仓库：$dir"
        exit 1
    fi

    git clone --depth=1 "$url" "$dir"
}

# PassWall 依赖包
clone_repo \
    https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git \
    package/passwall-packages

# PassWall 2
clone_repo \
    https://github.com/Openwrt-Passwall/openwrt-passwall2.git \
    package/passwall2

# 启用 PassWall 2
touch .config
sed -i \
    '/^CONFIG_PACKAGE_luci-app-passwall2=/d; /^# CONFIG_PACKAGE_luci-app-passwall2 is not set$/d' \
    .config
echo 'CONFIG_PACKAGE_luci-app-passwall2=y' >> .config

echo "[PassWall] 执行配置解析..."
make defconfig

if ! grep -qx 'CONFIG_PACKAGE_luci-app-passwall2=y' .config; then
    echo "[PassWall] 错误：PassWall 2 未进入最终配置，请检查依赖和源码兼容性"
    exit 1
fi

echo "[PassWall] 集成完成"
