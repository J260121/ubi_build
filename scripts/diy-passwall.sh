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

# ------------------------------------------------------------
# 1. 自动定位 ImmortalWrt 源码目录
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OPENWRT_ROOT=""

is_openwrt_dir() {
    [[ -n "${1:-}" ]] &&
    [[ -d "$1" ]] &&
    [[ -f "$1/include/toplevel.mk" ]] &&
    [[ -d "$1/scripts/feeds" ]]
}

if is_openwrt_dir "${OPENWRT_DIR:-}"; then
    OPENWRT_ROOT="$(cd "$OPENWRT_DIR" && pwd -P)"
elif is_openwrt_dir "${WORKDIR:-}/openwrt"; then
    OPENWRT_ROOT="$(cd "${WORKDIR}/openwrt" && pwd -P)"
elif is_openwrt_dir "${GITHUB_WORKSPACE:-}/openwrt"; then
    OPENWRT_ROOT="$(cd "${GITHUB_WORKSPACE}/openwrt" && pwd -P)"
else
    SEARCH_DIR="$SCRIPT_DIR"

    while :; do
        if is_openwrt_dir "$SEARCH_DIR"; then
            OPENWRT_ROOT="$SEARCH_DIR"
            break
        fi

        [[ "$SEARCH_DIR" == "/" ]] && break
        SEARCH_DIR="$(dirname "$SEARCH_DIR")"
    done
fi

if [[ -z "$OPENWRT_ROOT" ]]; then
    echo "ERROR: 无法定位 ImmortalWrt 源码目录"
    echo "当前目录：$PWD"
    echo "脚本目录：$SCRIPT_DIR"
    echo "OPENWRT_DIR：${OPENWRT_DIR:-未设置}"
    exit 1
fi

echo ">>> 源码目录：$OPENWRT_ROOT"
cd "$OPENWRT_ROOT"

# ------------------------------------------------------------
# 2. 检查设备配置文件
# ------------------------------------------------------------

if [[ ! -f .config ]]; then
    echo "ERROR: .config 不存在"
    echo "请先复制设备配置文件，再运行 PassWall 脚本"
    exit 1
fi

# ------------------------------------------------------------
# 3. 添加 PassWall 软件源
# ------------------------------------------------------------

echo ">>> Adding PassWall feed..."

touch feeds.conf.default

PASSWALL_FEED='src-git passwall https://github.com/xiaorouji/openwrt-passwall'

if ! grep -Eq \
    '^[[:space:]]*src-git[[:space:]]+passwall[[:space:]]' \
    feeds.conf.default; then
    echo "$PASSWALL_FEED" >> feeds.conf.default
    echo "OK: PassWall feed added"
else
    echo "PassWall feed already exists"
fi

# ------------------------------------------------------------
# 4. 更新 PassWall feed
# ------------------------------------------------------------

echo ">>> Updating PassWall feed..."

./scripts/feeds update passwall

# ------------------------------------------------------------
# 5. 安装 PassWall LuCI 软件包
# ------------------------------------------------------------

echo ">>> Installing PassWall packages..."

./scripts/feeds install -p passwall luci-app-passwall

# ------------------------------------------------------------
# 6. 写入 .config
# ------------------------------------------------------------

echo ">>> Updating .config..."

enable_package() {
    local package="$1"

    if grep -q "^${package}=" .config; then
        sed -i "s/^${package}=.*/${package}=y/" .config
    elif grep -q "^# ${package} is not set$" .config; then
        sed -i "s|^# ${package} is not set$|${package}=y|" .config
    else
        echo "${package}=y" >> .config
    fi

    echo "[CONFIG] ${package}=y"
}

# PassWall 主程序
enable_package "CONFIG_PACKAGE_luci-app-passwall"

# 常用代理组件
# 这些包必须已由相应 feeds 提供
OPTIONAL_PACKAGES=(
    "xray-core"
    "tcping"
    "geoview"
    "v2ray-geodata"
    "dns2socks"
    "ipt2socks"
)

for PACKAGE_NAME in "${OPTIONAL_PACKAGES[@]}"; do
    # 检查软件包是否已进入源码树
    if [[ -d "package/feeds" ]] &&
       find package/feeds -type f -name Makefile -print0 2>/dev/null |
       xargs -0 -r grep -lE \
           "^[[:space:]]*define Package/${PACKAGE_NAME}([[:space:]]|$)" \
           >/dev/null 2>&1; then

        enable_package "CONFIG_PACKAGE_${PACKAGE_NAME}"
    else
        echo "[INFO] 未检测到 ${PACKAGE_NAME} 的软件包定义，跳过"
    fi
done

# ------------------------------------------------------------
# 7. 输出配置检查结果
# ------------------------------------------------------------

echo
echo "=============== PASSWALL CHECK ==============="

echo "--- PassWall feed ---"
grep -E \
    '^[[:space:]]*src-git[[:space:]]+passwall[[:space:]]' \
    feeds.conf.default || true

echo
echo "--- PassWall configuration ---"
grep -E \
    '^CONFIG_PACKAGE_(luci-app-passwall|xray-core|tcping|geoview|v2ray-geodata|dns2socks|ipt2socks)=' \
    .config || true

echo
echo "PassWall preparation completed."
echo "源码目录：$OPENWRT_ROOT"
echo "=============================================="
