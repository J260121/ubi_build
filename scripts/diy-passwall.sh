#!/usr/bin/env bash
# OpenWrt / ImmortalWrt PassWall integration
# Target: J260121/ubi_build
# Run after feeds install, before make defconfig.
set -Eeuo pipefail

# passwall | passwall2 | both
PASSWALL_MODE="${PASSWALL_MODE:-passwall}"
BRANCH="${PASSWALL_BRANCH:-main}"
PKG_BRANCH="${PASSWALL_PACKAGES_BRANCH:-main}"
PW_URL="https://github.com/Openwrt-Passwall/openwrt-passwall.git"
PW2_URL="https://github.com/Openwrt-Passwall/openwrt-passwall2.git"
PKG_URL="https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"

log() { echo "[PassWall] $*"; }
die() { echo "[PassWall][错误] $*" >&2; exit 1; }

# Locate the OpenWrt source root.
ROOT="${OPENWRT_ROOT:-$PWD}"
[[ -f "$ROOT/Makefile" && -d "$ROOT/package" ]] ||
    die "未找到 OpenWrt 源码根目录：$ROOT"
cd "$ROOT"

[[ -f .config ]] ||
    die "缺少 .config；请先加载设备配置文件"
command -v git >/dev/null 2>&1 ||
    die "系统未安装 git"
[[ -d scripts ]] ||
    die "缺少 scripts 目录，当前目录可能不是源码根目录"

case "$PASSWALL_MODE" in
    passwall|passwall2|both) ;;
    *) die "PASSWALL_MODE 只能是 passwall、passwall2 或 both" ;;
esac

# Fail early instead of prompting for GitHub credentials in Actions.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

check_remote() {
    local url="$1" branch="$2"
    log "检查仓库：$url [$branch]"
    if ! git ls-remote --exit-code "$url" "refs/heads/$branch" \
        >/dev/null 2>&1; then
        die "无法访问仓库或分支不存在：$url [$branch]。请检查 URL、分支及 GitHub 网络访问。"
    fi
}

clone_repo() {
    local url="$1" branch="$2" dest="$3"

    check_remote "$url" "$branch"
    mkdir -p "$(dirname "$dest")"

    if [[ -e "$dest" ]]; then
        if [[ ! -d "$dest/.git" ]]; then
            die "目标目录已存在但不是 Git 仓库：$dest；请检查后手动处理，脚本不会覆盖它。"
        fi

        local current
        current="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
        [[ "$current" == "$url" ]] ||
            die "目录 $dest 的远程地址不匹配：$current"

        log "更新已有仓库：$dest"
        git -C "$dest" fetch --depth 1 origin "$branch" ||
            die "更新仓库失败：$url"
        git -C "$dest" checkout -B "$branch" FETCH_HEAD ||
            die "切换分支失败：$url"
    else
        log "克隆：$url -> $dest"
        git clone --depth 1 --single-branch \
            --branch "$branch" "$url" "$dest" ||
            die "克隆失败：$url；请查看上方 Git 错误日志。"
    fi

    [[ -f "$dest/README.md" ]] ||
        die "仓库内容不完整，缺少 README.md：$dest"
}

# The dependencies repository is shared by PassWall and PassWall 2.
clone_repo "$PKG_URL" "$PKG_BRANCH" "package/passwall-packages"

if [[ "$PASSWALL_MODE" == "passwall" ||
      "$PASSWALL_MODE" == "both" ]]; then
    # Remove conflicting feed versions as recommended upstream.
    if [[ -d feeds/packages/net ]]; then
        for name in \
            xray-core v2ray-geodata sing-box chinadns-ng dns2socks \
            hysteria ipt2socks microsocks naiveproxy shadowsocks-rust \
            shadowsocksr-libev simple-obfs tcping v2ray-plugin \
            xray-plugin geoview shadow-tls; do
            rm -rf "feeds/packages/net/$name"
        done
    fi

    # Remove the older feed version of luci-app-passwall.
    rm -rf feeds/luci/applications/luci-app-passwall
    rm -f package/feeds/luci/luci-app-passwall

    clone_repo "$PW_URL" "$BRANCH" "package/passwall-luci"
    [[ -f package/passwall-luci/luci-app-passwall/Makefile ]] ||
        die "PassWall 源码目录结构异常，缺少 luci-app-passwall/Makefile"
fi

if [[ "$PASSWALL_MODE" == "passwall2" ||
      "$PASSWALL_MODE" == "both" ]]; then
    clone_repo "$PW2_URL" "$BRANCH" "package/passwall2"
    [[ -f package/passwall2/luci-app-passwall2/Makefile ]] ||
        die "PassWall 2 源码目录结构异常，缺少 luci-app-passwall2/Makefile"
fi

# Ensure the required LuCI application packages are built into firmware.
# Replace existing y/m/n settings instead of accumulating duplicate entries.
set_config() {
    local key="$1" value="$2"
    if grep -q "^${key}=" .config; then
        sed -i "/^${key}=/d" .config
    fi
    if grep -q "^# ${key} is not set$" .config; then
        sed -i "\|^# ${key} is not set$|d" .config
    fi
    printf '%s=%s\n' "$key" "$value" >> .config
}

if [[ "$PASSWALL_MODE" == "passwall" ||
      "$PASSWALL_MODE" == "both" ]]; then
    set_config CONFIG_PACKAGE_luci-app-passwall y
fi

if [[ "$PASSWALL_MODE" == "passwall2" ||
      "$PASSWALL_MODE" == "both" ]]; then
    set_config CONFIG_PACKAGE_luci-app-passwall2 y
fi

# Confirm all required package definitions exist before resolving config.
if [[ "$PASSWALL_MODE" == "passwall" ||
      "$PASSWALL_MODE" == "both" ]]; then
    grep -q '^[[:space:]]*LUCI_TITLE.*PassWall' \
        package/passwall-luci/luci-app-passwall/Makefile ||
        die "PassWall Makefile 检查失败"
fi

log "执行 make defconfig，解析依赖并规范化配置"
make defconfig || die "make defconfig 失败，请检查依赖或配置错误"

# Verify that defconfig did not discard the selected applications.
if [[ "$PASSWALL_MODE" == "passwall" ||
      "$PASSWALL_MODE" == "both" ]]; then
    grep -qx 'CONFIG_PACKAGE_luci-app-passwall=y' .config ||
        die "PassWall 未能进入最终配置；请检查依赖和目标平台"
fi

if [[ "$PASSWALL_MODE" == "passwall2" ||
      "$PASSWALL_MODE" == "both" ]]; then
    grep -qx 'CONFIG_PACKAGE_luci-app-passwall2=y' .config ||
        die "PassWall 2 未能进入最终配置；请检查依赖和目标平台"
fi

log "插件源码及最终配置检查通过"
log "模式：$PASSWALL_MODE"
log "注意：插件依赖的代理核心仍须由软件包配置及目标架构决定"
