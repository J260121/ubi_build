#!/bin/bash
# ============================================================
# ImmortalWrt DIY Part 1
# 项目：J260121/ubi_build
# 功能：
#   1. 添加 iStore 软件源
#   2. 复制本地 luci-compat-keep 兼容包
#   3. 添加 Aurora 主题及配置插件
#   4. 添加 Bandix 流量监控
#   5. 启用 Aurora 主题（如果 .config 已存在）
#   6. 设置 Aurora 为默认 LuCI 主题
#
# 执行位置：ImmortalWrt 源码根目录
# 执行时机：更新 feeds 之前
# ============================================================

set -Eeuo pipefail

echo "================================================"
echo " ImmortalWrt DIY: iStore + Aurora + Bandix"
echo "================================================"

# ------------------------------------------------------------
# 1. 检查源码目录
# ------------------------------------------------------------

if [ ! -f "feeds.conf.default" ] || [ ! -d "scripts/feeds" ]; then
    echo "ERROR: 请在 ImmortalWrt 源码根目录运行！"
    exit 1
fi

# ------------------------------------------------------------
# 2. 复制本地兼容包
# ------------------------------------------------------------

echo ">>> Copying luci-compat-keep..."

LOCAL_PACKAGE="${GITHUB_WORKSPACE:-}/package/luci-compat-keep"

if [ -d "$LOCAL_PACKAGE" ]; then
    rm -rf package/luci-compat-keep
    mkdir -p package
    cp -a "$LOCAL_PACKAGE" package/
    echo "OK: luci-compat-keep copied"
elif [ -d "package/luci-compat-keep" ]; then
    echo "OK: luci-compat-keep already exists"
else
    echo "WARNING: luci-compat-keep not found; skipped"
fi

# ------------------------------------------------------------
# 3. 添加 iStore feed，防止重复添加
# ------------------------------------------------------------

echo ">>> Adding iStore feed..."

if ! grep -Eq '^[[:space:]]*src-git[[:space:]]+istore[[:space:]]' feeds.conf.default; then
    echo 'src-git istore https://github.com/linkease/istore;main' \
        >> feeds.conf.default
else
    echo "iStore feed already exists"
fi

# ------------------------------------------------------------
# 4. 克隆第三方软件包
# ------------------------------------------------------------

clone_package() {
    local repo="$1"
    local dest="$2"

    if [ -d "$dest/.git" ]; then
        echo "Already cloned: $dest"
        return 0
    fi

    if [ -e "$dest" ]; then
        echo "ERROR: $dest exists but is not a Git repository"
        exit 1
    fi

    echo ">>> Cloning $repo"
    git clone --depth=1 "$repo" "$dest"
}

clone_package \
    "https://github.com/eamonxg/luci-theme-aurora" \
    "package/luci-theme-aurora"

clone_package \
    "https://github.com/eamonxg/luci-app-aurora-config" \
    "package/luci-app-aurora-config"

clone_package \
    "https://github.com/timsaya/luci-app-bandix" \
    "package/luci-app-bandix"

clone_package \
    "https://github.com/timsaya/openwrt-bandix" \
    "package/openwrt-bandix"

# ------------------------------------------------------------
# 5. 配置 Aurora 主题
# ------------------------------------------------------------

echo ">>> Enabling Aurora theme..."

if [ -f ".config" ]; then
    if grep -q '^CONFIG_PACKAGE_luci-theme-aurora=' .config; then
        sed -i \
            's/^CONFIG_PACKAGE_luci-theme-aurora=.*/CONFIG_PACKAGE_luci-theme-aurora=y/' \
            .config
    else
        echo 'CONFIG_PACKAGE_luci-theme-aurora=y' >> .config
    fi
    echo "OK: Aurora theme enabled in .config"
else
    echo "WARNING: .config not found."
    echo "请在最终 .config 生成后添加："
    echo "CONFIG_PACKAGE_luci-theme-aurora=y"
fi

# ------------------------------------------------------------
# 6. 设置 Aurora 为默认 LuCI 主题
# ------------------------------------------------------------

echo ">>> Setting Aurora as default theme..."

mkdir -p package/base-files/files/etc/uci-defaults

cat > package/base-files/files/etc/uci-defaults/99-default-aurora-theme <<'EOF'
#!/bin/sh

# 首次启动时设置 LuCI 默认主题。
# 仅在 Aurora 主题目录存在时切换，避免主题缺失导致界面异常。

THEME_PATH="/www/luci-static/aurora"

if [ -d "$THEME_PATH" ]; then
    uci -q set luci.main.mediaurlbase="$THEME_PATH"
    uci -q commit luci
    logger -t default-aurora-theme \
        "Aurora set as default LuCI theme"
else
    logger -t default-aurora-theme \
        "Aurora theme directory not found; default theme unchanged"
fi

exit 0
EOF

chmod +x \
    package/base-files/files/etc/uci-defaults/99-default-aurora-theme

# ------------------------------------------------------------
# 7. 输出检查信息
# ------------------------------------------------------------

echo
echo "=============== DIY CHECK ==============="

echo "--- iStore feed ---"
grep -E '^[[:space:]]*src-git[[:space:]]+istore[[:space:]]' \
    feeds.conf.default || true

echo
echo "--- Custom packages ---"
for dir in \
    package/luci-compat-keep \
    package/luci-theme-aurora \
    package/luci-app-aurora-config \
    package/luci-app-bandix \
    package/openwrt-bandix
do
    if [ -d "$dir" ]; then
        echo "[OK] $dir"
    else
        echo "[INFO] $dir not present"
    fi
done

echo
echo "--- Aurora configuration ---"
grep '^CONFIG_PACKAGE_luci-theme-aurora=' .config 2>/dev/null || true

echo
echo "DIY preparation complete."
echo "========================================"
