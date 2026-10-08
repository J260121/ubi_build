#!/bin/bash

set -e

echo "=============================================="
echo " QLB-4Pro PassWall"
echo "=============================================="

# --------------------------------------------------
# OpenWrt directory
# --------------------------------------------------

if [ -z "$OPENWRT_DIR" ]; then
    OPENWRT_DIR="$GITHUB_WORKSPACE/openwrt"
fi

if [ ! -d "$OPENWRT_DIR" ]; then
    echo "ERROR: OpenWrt directory not found:"
    echo "$OPENWRT_DIR"
    exit 1
fi

cd "$OPENWRT_DIR"

echo "OpenWrt: $PWD"

# --------------------------------------------------
# Check .config
# --------------------------------------------------

if [ ! -f ".config" ]; then
    echo "WARNING: .config does not exist."
    echo "PassWall packages will be added to feeds first."
    echo "The final .config must be copied before make defconfig."
else
    echo ".config found."
fi

# --------------------------------------------------
# PassWall feeds
# --------------------------------------------------

echo
echo ">>> Adding PassWall feeds..."

if ! grep -q '^src-git passwall_packages ' feeds.conf.default 2>/dev/null; then
    echo 'src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main' >> feeds.conf.default
fi

if ! grep -q '^src-git passwall_luci ' feeds.conf.default 2>/dev/null; then
    echo 'src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main' >> feeds.conf.default
fi

# --------------------------------------------------
# Update feeds
# --------------------------------------------------

echo
echo ">>> Updating PassWall feeds..."

./scripts/feeds update passwall_packages
./scripts/feeds update passwall_luci

# --------------------------------------------------
# Install PassWall
# --------------------------------------------------

echo
echo ">>> Installing PassWall..."

./scripts/feeds install -p passwall_packages -a
./scripts/feeds install -p passwall_luci -a

# --------------------------------------------------
# Verify PassWall
# --------------------------------------------------

echo
echo ">>> Checking PassWall..."

if [ ! -d "feeds/luci/applications/luci-app-passwall" ]; then
    echo "ERROR: PassWall LuCI package not found!"
    exit 1
fi

echo "PassWall LuCI found."

# --------------------------------------------------
# Enable PassWall
# --------------------------------------------------

echo
echo ">>> Enabling PassWall..."

cat >> .config <<'EOF'

# ==============================================
# QLB-4Pro PassWall
# ==============================================

CONFIG_PACKAGE_luci-app-passwall=y

# Xray
CONFIG_PACKAGE_xray-core=y

# PassWall dependencies
CONFIG_PACKAGE_tcping=y
CONFIG_PACKAGE_geoview=y
CONFIG_PACKAGE_v2ray-geodata=y
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_ipt2socks=y

EOF

# --------------------------------------------------
# Verify config
# --------------------------------------------------

echo
echo ">>> PassWall configuration:"

grep -E \
'^CONFIG_PACKAGE_(luci-app-passwall|xray-core|tcping|geoview|v2ray-geodata|dns2socks|ipt2socks)=' \
.config || true

echo
echo "=============================================="
echo " PassWall configuration completed"
echo "=============================================="
