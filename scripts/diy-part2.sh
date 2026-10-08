#!/bin/bash

set -e

OPENWRT_DIR="/workdir/openwrt"

echo "=============================================="
echo " QLB-4Pro DIY Package Configuration"
echo " iStore + Aurora + Bandix + PassWall"
echo "=============================================="

# --------------------------------------------------
# 0. 检查 OpenWrt
# --------------------------------------------------

if [ ! -d "$OPENWRT_DIR" ]; then
    echo "ERROR: OpenWrt directory not found:"
    echo "$OPENWRT_DIR"
    exit 1
fi

cd "$OPENWRT_DIR"

echo
echo "OpenWrt directory: $PWD"

# --------------------------------------------------
# 1. iStore
# --------------------------------------------------

echo
echo ">>> Adding iStore..."

if ! grep -q '^src-git istore ' feeds.conf.default 2>/dev/null; then
    echo 'src-git istore https://github.com/linkease/istore;main' >> feeds.conf.default
fi

./scripts/feeds update istore
./scripts/feeds install -d y -p istore luci-app-store

# --------------------------------------------------
# 2. Aurora Theme
# --------------------------------------------------

echo
echo ">>> Installing Aurora Theme..."

rm -rf package/luci-theme-aurora

git clone \
    --depth=1 \
    https://github.com/eamonxg/luci-theme-aurora \
    package/luci-theme-aurora

# --------------------------------------------------
# 3. Aurora Config
# --------------------------------------------------

echo
echo ">>> Installing Aurora Config..."

rm -rf package/luci-app-aurora-config

git clone \
    --depth=1 \
    https://github.com/eamonxg/luci-app-aurora-config \
    package/luci-app-aurora-config

# --------------------------------------------------
# 4. Bandix Frontend
# --------------------------------------------------

echo
echo ">>> Installing Bandix LuCI..."

rm -rf package/luci-app-bandix

git clone \
    --depth=1 \
    https://github.com/timsaya/luci-app-bandix \
    package/luci-app-bandix

# --------------------------------------------------
# 5. Bandix Backend
# --------------------------------------------------

echo
echo ">>> Installing Bandix Backend..."

rm -rf package/openwrt-bandix

git clone \
    --depth=1 \
    https://github.com/timsaya/openwrt-bandix \
    package/openwrt-bandix

# --------------------------------------------------
# 6. PassWall feeds
# --------------------------------------------------

echo
echo ">>> Adding PassWall feeds..."

if ! grep -q 'openwrt-passwall-packages' feeds.conf.default 2>/dev/null; then

cat >> feeds.conf.default <<'EOF'

# PassWall
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main
EOF

fi

# --------------------------------------------------
# 7. Update PassWall feeds
# --------------------------------------------------

echo
echo ">>> Updating PassWall feeds..."

./scripts/feeds update passwall_packages
./scripts/feeds update passwall_luci

# --------------------------------------------------
# 8. Install PassWall feed packages
# --------------------------------------------------

echo
echo ">>> Installing PassWall feed packages..."

./scripts/feeds install -p passwall_packages -a
./scripts/feeds install -p passwall_luci -a

# --------------------------------------------------
# 9. Check PassWall
# --------------------------------------------------

echo
echo ">>> Checking PassWall..."

if [ ! -d "feeds/luci/applications/luci-app-passwall" ]; then
    echo "ERROR: luci-app-passwall not found!"
    exit 1
fi

echo "PassWall LuCI found."

# --------------------------------------------------
# 10. Remove old configuration
# --------------------------------------------------

echo
echo ">>> Cleaning old package selections..."

sed -i '/^CONFIG_PACKAGE_luci-app-store=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-theme-aurora=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-app-aurora-config=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-app-bandix=/d' .config
sed -i '/^CONFIG_PACKAGE_openwrt-bandix=/d' .config

sed -i '/^CONFIG_PACKAGE_luci-app-passwall=/d' .config
sed -i '/^CONFIG_PACKAGE_xray-core=/d' .config
sed -i '/^CONFIG_PACKAGE_tcping=/d' .config
sed -i '/^CONFIG_PACKAGE_geoview=/d' .config
sed -i '/^CONFIG_PACKAGE_v2ray-geodata=/d' .config
sed -i '/^CONFIG_PACKAGE_dns2socks=/d' .config
sed -i '/^CONFIG_PACKAGE_ipt2socks=/d' .config

# --------------------------------------------------
# 11. Enable packages
# --------------------------------------------------

echo
echo ">>> Enabling QLB-4Pro packages..."

cat >> .config <<'EOF'

# ==============================================
# QLB-4Pro Custom Packages
# ==============================================

# iStore
CONFIG_PACKAGE_luci-app-store=y

# Aurora
CONFIG_PACKAGE_luci-theme-aurora=y
CONFIG_PACKAGE_luci-app-aurora-config=y

# Bandix
CONFIG_PACKAGE_luci-app-bandix=y
CONFIG_PACKAGE_openwrt-bandix=y

# ==============================================
# PassWall
# ==============================================

CONFIG_PACKAGE_luci-app-passwall=y

# PassWall Core
CONFIG_PACKAGE_xray-core=y

# PassWall Dependencies
CONFIG_PACKAGE_tcping=y
CONFIG_PACKAGE_geoview=y
CONFIG_PACKAGE_v2ray-geodata=y
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_ipt2socks=y

EOF

# --------------------------------------------------
# 12. Refresh feeds
# --------------------------------------------------

echo
echo ">>> Refreshing package indexes..."

./scripts/feeds update -a

# --------------------------------------------------
# 13. Install custom local package
# --------------------------------------------------

if [ -d "$GITHUB_WORKSPACE/package/luci-compat-keep" ]; then

    echo
    echo ">>> Installing luci-compat-keep..."

    rm -rf package/luci-compat-keep

    cp -a \
        "$GITHUB_WORKSPACE/package/luci-compat-keep" \
        package/

fi

# --------------------------------------------------
# 14. Verify configuration
# --------------------------------------------------

echo
echo "=============================================="
echo " Enabled Packages"
echo "=============================================="

grep -E \
'CONFIG_PACKAGE_(luci-app-store|luci-theme-aurora|luci-app-aurora-config|luci-app-bandix|openwrt-bandix|luci-app-passwall|xray-core|tcping|geoview|v2ray-geodata|dns2socks|ipt2socks)=' \
.config || true

echo
echo "=============================================="
echo " QLB-4Pro package configuration completed"
echo "=============================================="
