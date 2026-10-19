#!/bin/bash

set -e

OPENWRT_DIR="/workdir/openwrt"

echo "========================================"
echo " DIY Part 3 - Install PassWall"
echo "========================================"

# 检查 OpenWrt 目录
if [ ! -d "$OPENWRT_DIR" ]; then
    echo "ERROR: OpenWrt directory not found:"
    echo "$OPENWRT_DIR"
    exit 1
fi

cd "$OPENWRT_DIR"

echo "OpenWrt directory: $PWD"

# --------------------------------------------------
# 1. 添加 PassWall feeds
# --------------------------------------------------

echo
echo ">>> Adding PassWall feeds..."

if ! grep -q "openwrt-passwall-packages" feeds.conf.default 2>/dev/null; then
    cat >> feeds.conf.default <<'EOF'

# PassWall
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main
EOF
fi


# --------------------------------------------------
# 5. 启用 PassWall
# --------------------------------------------------

echo
echo ">>> Enabling PassWall..."

cat >> .config <<'EOF'

# ========================================
# PassWall
# ========================================

CONFIG_PACKAGE_luci-app-passwall=y

# PassWall Core
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_sing-box=y

# PassWall dependencies
CONFIG_PACKAGE_tcping=y
CONFIG_PACKAGE_geoview=y
CONFIG_PACKAGE_v2ray-geodata=y
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_ipt2socks=y

EOF

# --------------------------------------------------
# 6. 检查配置
# --------------------------------------------------

echo
echo ">>> PassWall configuration:"

grep -E \
'CONFIG_PACKAGE_(luci-app-passwall|xray-core|sing-box|tcping|geoview|v2ray-geodata|dns2socks|ipt2socks)=' \
.config || true

echo
echo "========================================"
echo " PassWall installation completed"
echo "========================================"
