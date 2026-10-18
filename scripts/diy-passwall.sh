
#!/usr/bin/env bash
# OpenWrt / ImmortalWrt PassWall integration
set -Eeuo pipefail

ROOT="${OPENWRT_ROOT:-$PWD}"
MODE="${PASSWALL_MODE:-passwall2}"

PKG_URL="https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"
PW_URL="https://github.com/Openwrt-Passwall/openwrt-passwall.git"
PW2_URL="https://github.com/Openwrt-Passwall/openwrt-passwall2.git"

BRANCH="${PASSWALL_BRANCH:-main}"
PKG_BRANCH="${PASSWALL_PACKAGES_BRANCH:-main}"

log() { echo "[PassWall] $*"; }
die() { echo "[PassWall][错误] $*" >&2; exit 1; }

cd "$ROOT"
[[ -f Makefile && -f .config && -d package ]] ||
    die "源码目录或 .config 不存在"
command -v git >/dev/null || die "未安装 git"

export GIT_TERMINAL_PROMPT=0

clone() {
    local url="$1" branch="$2" dest="$3" remote

    log "检查仓库：$url [$branch]"
    git ls-remote --exit-code "$url" "refs/heads/$branch" >/dev/null ||
        die "仓库或分支不可用：$url [$branch]"

    if [[ -e "$dest" ]]; then
        [[ -d "$dest/.git" ]] ||
            die "目标目录存在但不是 Git 仓库：$dest"
        remote="$(git -C "$dest" remote get-url origin)"
        [[ "$remote" == "$url" ]] ||
            die "仓库地址不匹配：$dest"
        git -C "$dest" fetch --depth 1 origin "$branch" ||
            die "更新失败：$url"
        git -C "$dest" checkout -B "$branch" FETCH_HEAD ||
            die "切换分支失败：$url"
    else
        git clone --depth 1 --single-branch --branch "$branch" \
            "$url" "$dest" || die "克隆失败：$url"
    fi
}

case "$MODE" in
    passwall|passwall2|both) ;;
    *) die "PASSWALL_MODE 应为 passwall、passwall2 或 both" ;;
esac

clone "$PKG_URL" "${PASSWALL_PACKAGES_BRANCH:-main}" \
    package/passwall-packages

find package/passwall-packages -name Makefile -type f -print -quit |
    grep -q . || die "依赖仓库中没有 Makefile"

if [[ "$MODE" == passwall || "$MODE" == both ]]; then
    clone "$PW_URL" "$BRANCH" package/passwall-luci
    [[ -f package/passwall-luci/luci-app-passwall/Makefile ]] ||
        die "PassWall 应用 Makefile 不存在"
fi

if [[ "$MODE" == passwall2 || "$MODE" == both ]]; then
    clone "$PW2_URL" "${PASSWALL2_BRANCH:-main}" package/passwall2
    [[ -f package/passwall2/luci-app-passwall2/Makefile ]] ||
        die "PassWall 2 应用 Makefile 不存在"
fi

set_config() {
    local key="$1"
    sed -i "/^${key}=/d; /^# ${key} is not set$/d" .config
    echo "${key}=y" >> .config
}

[[ "$MODE" == passwall || "$MODE" == both ]] &&
    set_config CONFIG_PACKAGE_luci-app-passwall

[[ "$MODE" == passwall2 || "$MODE" == both ]] &&
    set_config CONFIG_PACKAGE_luci-app-passwall2

log "解析依赖：make defconfig"
make defconfig || die "make defconfig 失败，请检查依赖错误"

[[ "$MODE" == passwall || "$MODE" == both ]] &&
    grep -qx 'CONFIG_PACKAGE_luci-app-passwall=y' .config ||
    [[ "$MODE" == passwall2 || "$MODE" == both ]] ||
    die "PassWall 未进入最终配置"

[[ "$MODE" == passwall2 || "$MODE" == both ]] &&
    grep -qx 'CONFIG_PACKAGE_luci-app-passwall2=y' .config ||
    [[ "$MODE" == passwall || "$MODE" == both ]] ||
    die "PassWall 2 未进入最终配置"

log "集成检查通过：$MODE"
