#!/bin/bash
# ============================================================
# ImmortalWrt DIY Part 3
# 项目：J260121/ubi_build
# 功能：iStore + Aurora + Bandix + 本地兼容包
# 支持从任意工作目录调用
# ============================================================

set -Eeuo pipefail

echo "================================================"
echo " ImmortalWrt DIY: iStore + Aurora + Bandix"
echo "================================================"

# ------------------------------------------------------------
# 1. 自动定位 ImmortalWrt 源码根目录
# 优先级：
#   1. OPENWRT_DIR
#   2. 当前工作目录
#   3. GITHUB_WORKSPACE/openwrt
#   4. 脚本目录及其常见相对目录
# ------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

is_openwrt_dir() {
    [[ -n "${1:-}" ]] &&
    [[ -f "$1/feeds.conf.default" ]] &&
    [[ -d "$1/scripts/feeds" ]]
}

OPENWRT_ROOT=""

if is_openwrt_dir "${OPENWRT_DIR:-}"; then
    OPENWRT_ROOT="$(cd "$OPENWRT_DIR" && pwd -P)"
elif is_openwrt_dir "$PWD"; then
    OPENWRT_ROOT="$(pwd -P)"
else
    CANDIDATES=(
        "${GITHUB_WORKSPACE:-}/openwrt"
        "${GITHUB_WORKSPACE:-}"
        "$SCRIPT_DIR/../openwrt"
        "$SCRIPT_DIR/../../openwrt"
        "$SCRIPT_DIR/../../../openwrt"
        "$SCRIPT_DIR/.."
        "$SCRIPT_DIR/../.."
        "$SCRIPT_DIR/../../.."
    )

    for DIR in "${CANDIDATES[@]}"; do
        if is_openwrt_dir "$DIR"; then
            OPENWRT_ROOT="$(cd "$DIR" && pwd -P)"
            break
        fi
    done
fi

if [[ -z "$OPENWRT_ROOT" ]]; then
    echo "ERROR: 无法自动定位 ImmortalWrt 源码目录。"
    echo "请检查 OPENWRT_DIR 环境变量或源码目录结构。"
    echo "脚本目录：$SCRIPT_DIR"
    echo "当前目录：$PWD"
    exit 1
fi

echo ">>> ImmortalWrt source: $OPENWRT_ROOT"

# 所有相对路径操作均在源码目录执行
cd "$OPENWRT_ROOT"

# ------------------------------------------------------------
# 2. 复制本地兼容包
# ------------------------------------------------------------

echo ">>> Copying luci-compat-keep..."

LOCAL_PACKAGE="${GITHUB_WORKSPACE:-}/package/luci-compat-keep"

if [[ -d "$LOCAL_PACKAGE" ]]; then
    mkdir -p package
    rm -rf package/luci-compat-keep
    cp -a "$LOCAL_PACKAGE" package/
    echo "OK: luci-compat-keep copied"
elif [[ -d "package/luci-compat-keep" ]]; then
    echo "OK: luci-compat-keep already exists"
else
    echo "WARNING: luci-compat-keep not found; skipped"
fi

# ------------------------------------------------------------
# 3. 添加 iStore feed，避免重复
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

    if [[ -d "$dest/.git" ]]; then
        echo "Already cloned: $dest"
        return 0
    fi

    if [[ -e "$dest" ]]; then
        echo "WARNING: $dest exists; skipping clone"
        return 0
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

if [[ -f ".config" ]]; then
    if grep -q '^CONFIG_PACKAGE_luci-theme-aurora=' .config; then
        sed -i \
            's/^CONFIG_PACKAGE_luci-theme-aurora=.*/CONFIG_PACKAGE_luci-theme-aurora=y/' \
            .config
    else
        echo 'CONFIG_PACKAGE_luci-theme-aurora=y' >> .config
    fi
    echo "OK: Aurora theme enabled"
else
    echo "WARNING: .config not found; enable Aurora after config generation"
fi

# ------------------------------------------------------------
# 6. 设置 Aurora 为默认 LuCI 主题
# ------------------------------------------------------------

echo ">>> Setting Aurora as default theme..."

mkdir -p package/base-files/files/etc/uci-defaults

cat > package/base-files/files/etc/uci-defaults/99-default-aurora-theme <<'EOF'
#!/bin/sh

THEME_PATH="/www/luci-static/aurora"

if [ -d "$THEME_PATH" ]; then
    uci -q set luci.main.mediaurlbase="$THEME_PATH"
    uci -q commit luci
    logger -t default-aurora-theme \
        "Aurora set as default LuCI theme"
else
    logger -t default-aurora-theme \
        "Aurora theme directory not found; default unchanged"
fi

exit 0
EOF

chmod +x package/base-files/files/etc/uci-defaults/99-default-aurora-theme

# ------------------------------------------------------------
# 7. 输出检查信息
# ------------------------------------------------------------

echo
echo "=============== DIY CHECK ==============="
echo "Source: $OPENWRT_ROOT"

echo "--- iStore feed ---"
grep -E '^[[:space:]]*src-git[[:space:]]+istore[[:space:]]' \
    feeds.conf.default || true

echo
echo "--- Custom packages ---"

for DIR in \
    package/luci-compat-keep \
    package/luci-theme-aurora \
    package/luci-app-aurora-config \
    package/luci-app-bandix \
    package/openwrt-bandix
do
    if [[ -d "$DIR" ]]; then
        echo "[OK] $DIR"
    else
        echo "[INFO] $DIR not present"
    fi
done

echo
echo "--- Aurora configuration ---"
grep '^CONFIG_PACKAGE_luci-theme-aurora=' .config 2>/dev/null || true

echo
echo "DIY preparation complete."
echo "========================================"
