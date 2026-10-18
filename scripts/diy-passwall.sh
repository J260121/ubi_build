
#!/usr/bin/env bash
# ============================================================
# OpenWrt / ImmortalWrt PassWall integration
# Repository: J260121/ubi_build
# File: scripts/diy-PassWall.sh
# Run after loading device .config and installing feeds.
# ============================================================

set -Eeuo pipefail

# Modes: passwall | passwall2 | both
PASSWALL_MODE="${PASSWALL_MODE:-passwall}"

PW_BRANCH="${PASSWALL_BRANCH:-main}"
PW2_BRANCH="${PASSWALL2_BRANCH:-main}"
PKG_BRANCH="${PASSWALL_PACKAGES_BRANCH:-main}"

PW_URL="https://github.com/Openwrt-Passwall/openwrt-passwall.git"
PW2_URL="https://github.com/Openwrt-Passwall/openwrt-passwall2.git"
PKG_URL="https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"

ROOT="${OPENWRT_ROOT:-$PWD}"

log() { printf '[PassWall] %s\n' "$*"; }
die() {
    printf '[PassWall][错误] %s\n' "$*" >&2
    exit 1
}

# 1. Check the OpenWrt source tree.
[[ -f "$ROOT/Makefile" && -d "$ROOT/package" ]] ||
    die "不是有效的 OpenWrt 源码目录：$ROOT"

cd "$ROOT"

[[ -f .config ]] ||
    die "缺少 .config，请先加载设备配置文件"

command -v git >/dev/null 2>&1 ||
    die "未安装 git"

[[ -x scripts/feeds ]] ||
    die "缺少 scripts/feeds，请确认源码完整"

case "$PASSWALL_MODE" in
    passwall|passwall2|both) ;;
    *) die "PASSWALL_MODE 必须为 passwall、passwall2 或 both" ;;
esac

export GIT_TERMINAL_PROMPT=0

# 2. Clone or update a repository.
# README.md is deliberately NOT required.
clone_repo() {
    local url="$1"
    local branch="$2"
    local dest="$3"
    local remote=""

    log "检查仓库：$url [$branch]"

    if ! git ls-remote --exit-code "$url" \
        "refs/heads/$branch" >/dev/null 2>&1; then
        die "仓库访问失败或分支不存在：$url [$branch]；请检查网络、URL 和分支。"
    fi

    if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
        die "目标目录存在但不是 Git 仓库：$dest；请检查后手动清理。"
    fi

    if [[ -d "$dest/.git" ]]; then
        remote="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
        [[ "$remote" == "$url" ]] ||
            die "目录 $dest 的远程地址不匹配：$remote"

        log "更新仓库：$dest"
        git -C "$dest" fetch --depth 1 origin "$branch" ||
            die "更新失败：$url"

        git -C "$dest" checkout -B "$branch" FETCH_HEAD ||
            die "切换分支失败：$url"
    else
        log "克隆：$url -> $dest"
        git clone --depth 1 --single-branch \
            --branch "$branch" "$url" "$dest" ||
            die "克隆失败：$url"
    fi

    [[ -d "$dest/.git" ]] ||
        die "克隆后 Git 元数据不存在：$dest"

    log "仓库检查通过：$dest"
}

# 3. Remove conflicting packages from the standard feeds.
# Follow the official PassWall integration instructions.
clean_conflicts() {
    local p
    local packages=(
        xray-core
        v2ray-geodata
        sing-box
        chinadns-ng
        dns2socks
        hysteria
        ipt2socks
        microsocks
        naiveproxy
        shadowsocks-rust
        shadowsocksr-libev
        simple-obfs
        tcping
        v2ray-plugin
        xray-plugin
        geoview
        shadow-tls
    )

    log "清理 feeds 中可能冲突的旧软件包"

    for p in "${packages[@]}"; do
        rm -rf "feeds/packages/net/$p"
    done

    rm -rf feeds/luci/applications/luci-app-passwall
    rm -f package/feeds/luci/luci-app-passwall

    log "旧包清理完成"
}

# 4. Integrate PassWall dependency packages.
clone_repo "$PKG_URL" "$PKG_BRANCH" \
    package/passwall-packages

# Ensure the dependency repository contains package definitions.
find package/passwall-packages -name Makefile -type f \
    -print -quit | grep -q . ||
    die "PassWall 依赖仓库中没有找到任何 Makefile"

clean_conflicts

# 5. Integrate selected LuCI applications.
if [[ "$PASSWALL_MODE" == "passwall" ||
      "$PASSWALL_MODE" == "both" ]]; then

    clone_repo "$PW_URL" "$PW_BRANCH" package/passwall-luci

    [[ -f package/passwall-luci/luci-app-passwall/Makefile ]] ||
        die "PassWall 主程序 Makefile 不存在，源码目录结构不匹配"
fi

if [[ "$PASSWALL_MODE" == "passwall2" ||
      "$PASSWALL_MODE" == "both" ]]; then

    clone_repo "$PW2_URL" "$PW2_BRANCH" package/passwall2

    [[ -f package/passwall2/luci-app-passwall2/Makefile ]] ||
        die "PassWall 2 主程序 Makefile 不存在，源码目录结构不匹配"
fi

# 6. Update .config without using menuconfig.
set_config() {
    local key="$1"
    local value="$2"

    sed -i \
        -e "/^${key}=/d" \
        -e "/^# ${key} is not set$/d" \
        .config

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

# 7. Resolve dependencies and normalize configuration.
log "执行 make defconfig，自动解析依赖"
make defconfig || die "make defconfig 失败，请检查上方依赖错误"

# 8. Verify selected packages survived defconfig.
if [[ "$PASSWALL_MODE" == "passwall" ||
      "$PASSWALL_MODE" == "both" ]]; then
    grep -qx 'CONFIG_PACKAGE_luci-app-passwall=y' .config ||
        die "PassWall 没有进入最终 .config，可能是依赖或平台不兼容"
fi

if [[ "$PASSWALL_MODE" == "passwall2" ||
      "$PASSWALL_MODE" == "both" ]]; then
    grep -qx 'CONFIG_PACKAGE_luci-app-passwall2=y' .config ||
        die "PassWall 2 没有进入最终 .config，可能是依赖或平台不兼容"
fi

log "集成成功：$PASSWALL_MODE"
log "源码及配置检查通过，可以继续编译固件"
