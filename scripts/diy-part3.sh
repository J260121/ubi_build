#!/bin/bash
# ============================================================
# ImmortalWrt DIY Part 3
# 项目：J260121/ubi_build
# 功能：iStore、Aurora、Bandix、本地兼容包
# 执行：支持从任意目录调用
# ============================================================

set -Eeuo pipefail

echo "================================================"
echo " ImmortalWrt DIY: iStore + Aurora + Bandix"
echo "================================================"

# ------------------------------------------------------------
# 1. 自动定位 ImmortalWrt 源码目录
# ------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
OPENWRT_ROOT=""

is_openwrt_dir() {
    [[ -d "$1" ]] &&
    [[ -f "$1/feeds.conf.default" ]] &&
    [[ -d "$1/scripts/feeds" ]]
}

# 优先使用工作流明确指定的源码目录
if is_openwrt_dir "${OPENWRT_DIR:-}"; then
    OPENWRT_ROOT="$(cd "$OPENWRT_DIR" && pwd -P)"
elif is_openwrt_dir "${WORKDIR:-}/openwrt"; then
    OPENWRT_ROOT="$(cd "${WORKDIR}/openwrt" && pwd -P)"
elif is_openwrt_dir "${GITHUB_WORKSPACE:-}/openwrt"; then
    OPENWRT_ROOT="$(cd "${GITHUB_WORKSPACE}/openwrt" && pwd -P)"
else
    # 从脚本目录及其上级目录查找
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
    echo "ERROR: 无法自动定位 ImmortalWrt 源码目录"
    echo "当前目录：$PWD"
    echo "脚本目录：$SCRIPT_DIR"
    echo "OPENWRT_DIR：${OPENWRT_DIR:-未设置}"
    echo "WORKDIR：${WORKDIR:-未设置}"
    exit 1
fi

echo ">>> ImmortalWrt 源码目录：$OPENWRT_ROOT"

# 从这里开始，所有源码相对路径操作均以源码目录为基准
cd "$OPENWRT_ROOT"

# ------------------------------------------------------------
# 2. 复制本地兼容包
# ------------------------------------------------------------

echo ">>> Copying luci-compat-keep..."

LOCAL_PACKAGE=""

# 兼容不同仓库布局
for CANDIDATE in \
    "${GITHUB_WORKSPACE:-}/package/luci-compat-keep" \
    "${GITHUB_WORKSPACE:-}/cudy/package/luci-compat-keep" \
    "$SCRIPT_DIR/../package/luci-compat-keep" \
    "$SCRIPT_DIR/../../package/luci-compat-keep" \
    "$OPENWRT_ROOT/package/luci-compat-keep"
do
    if [[ -d "$CANDIDATE" ]]; then
        CANDIDATE="$(cd "$CANDIDATE" && pwd -P)"

        # 不要把源码目录中的包复制到自身
        if [[ "$CANDIDATE" != "$OPENWRT_ROOT/package/luci-compat-keep" ]]; then
            LOCAL_PACKAGE="$CANDIDATE"
            break
        fi
    fi
done

if [[ -n "$LOCAL_PACKAGE" ]]; then
    mkdir -p package
    rm -rf package/luci-compat-keep
    cp -a "$LOCAL_PACKAGE" package/
    echo "OK: luci-compat-keep copied"
elif [[ -d package/luci-compat-keep ]]; then
    echo "OK: luci-compat-keep already exists"
else
    echo "WARNING: luci-compat-keep not found; skipped"
fi

# ------------------------------------------------------------
# 3. 添加 iStore 软件源，避免重复
# ------------------------------------------------------------

echo ">>> Adding iStore feed..."

if ! grep -Eq \
    '^[[:space:]]*src-git[[:space:]]+istore[[:space:]]' \
    feeds.conf.default; then

    echo 'src-git istore https://github.com/linkease/istore;main' \
        >> feeds.conf.default
else
    echo "iStore feed already exists"
fi

# ------------------------------------------------------------
# 4. 克隆 Aurora 和 Bandix 软件包
# ------------------------------------------------------------

clone_package() {
    local repo="$1"
    local dest="$2"

    if [[ -d "$dest/.git" ]]; then
        echo "Already cloned: $dest"
        return 0
    fi

    if [[ -e "$dest" ]]; then
        echo "ERROR: $dest exists but is not a Git repository"
        echo "请检查该目录，避免覆盖现有文件。"
        exit 1
    fi

    echo ">>> Cloning $repo"
    git clone --depth=1 "$repo" "$dest"
}

mkdir -p package

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

if [[ -f .config ]]; then
    if grep -q '^CONFIG_PACKAGE_luci-theme-aurora=' .config; then
        sed -i \
            's/^CONFIG_PACKAGE_luci-theme-aurora=.*/CONFIG_PACKAGE_luci-theme-aurora=y/' \
            .config
    else
        echo 'CONFIG_PACKAGE_luci-theme-aurora=y' >> .config
    fi

    echo "OK: Aurora theme enabled"
else
    echo "WARNING: .config not found."
    echo "请在生成最终 .config 后启用："
    echo "CONFIG_PACKAGE_luci-theme-aurora=y"
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

chmod +x \
    package/base-files/files/etc/uci-defaults/99-default-aurora-theme

# ------------------------------------------------------------
# 7. 输出检查信息
# ------------------------------------------------------------

echo
echo "=============== DIY CHECK ==============="
echo "源码目录：$OPENWRT_ROOT"

echo
echo "--- iStore feed ---"
grep -E \
    '^[[:space:]]*src-git[[:space:]]+istore[[:space:]]' \
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
