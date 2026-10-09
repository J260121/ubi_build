#!/bin/bash
# PassWall integration script for J260121/ubi_build cloud compilation.
# Put this file in the repository's scripts/ directory and set the workflow's
# plugin_scripts input to: passwall.sh
#
# This is a BUILD-TIME script. It is not intended to run on the router itself.

set -Eeuo pipefail

log() { printf '[PassWall] %s\n' "$*"; }
die() { log "错误：$*"; exit 1; }

# Detect the OpenWrt source root; OPENWRT_DIR can override auto-detection.
if [[ -n "${OPENWRT_DIR:-}" ]]; then
    :
elif [[ -f "$PWD/.config" && -d "$PWD/package" ]]; then
    OPENWRT_DIR="$PWD"
elif [[ -f "/workdir/openwrt/.config" && -d "/workdir/openwrt/package" ]]; then
    OPENWRT_DIR="/workdir/openwrt"
elif [[ -f "${GITHUB_WORKSPACE:-/nonexistent}/openwrt/.config" && -d "${GITHUB_WORKSPACE:-/nonexistent}/openwrt/package" ]]; then
    OPENWRT_DIR="${GITHUB_WORKSPACE}/openwrt"
elif [[ -f "/workdir/.config" && -d "/workdir/package" ]]; then
    OPENWRT_DIR="/workdir"
else
    die "无法自动定位 OpenWrt 源码目录；请设置 OPENWRT_DIR，或从源码根目录执行。"
fi
[[ -d "$OPENWRT_DIR" ]] || die "找不到 OpenWrt 源码目录：$OPENWRT_DIR"
cd "$OPENWRT_DIR"
[[ -d package && -f include/toplevel.mk ]] || die "目录不是有效的 OpenWrt 源码树：$OPENWRT_DIR"

# Official public upstream repositories.
PASSWALL_PACKAGES_REPO="${PASSWALL_PACKAGES_REPO:-https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git}"
PASSWALL_LUCI_REPO="${PASSWALL_LUCI_REPO:-https://github.com/Openwrt-Passwall/openwrt-passwall.git}"
PASSWALL_BRANCH="${PASSWALL_BRANCH:-main}"

# Never let git prompt for credentials in a non-interactive GitHub Actions job.
export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never

log "开始集成 PassWall"
log "OpenWrt 目录：$OPENWRT_DIR"
log "清理可能冲突的旧包..."

# Remove older versions shipped in standard feeds, as recommended by upstream.
# Ignore missing paths: different OpenWrt branches can have different feed layouts.
rm -rf \
  feeds/packages/net/xray-core \
  feeds/packages/net/v2ray-geodata \
  feeds/packages/net/sing-box \
  feeds/packages/net/chinadns-ng \
  feeds/packages/net/dns2socks \
  feeds/packages/net/hysteria \
  feeds/packages/net/ipt2socks \
  feeds/packages/net/microsocks \
  feeds/packages/net/naiveproxy \
  feeds/packages/net/shadowsocks-rust \
  feeds/packages/net/shadowsocksr-libev \
  feeds/packages/net/simple-obfs \
  feeds/packages/net/tcping \
  feeds/packages/net/v2ray-plugin \
  feeds/packages/net/xray-plugin \
  feeds/packages/net/geoview \
  feeds/packages/net/shadow-tls \
  feeds/luci/applications/luci-app-passwall \
  package/passwall-packages \
  package/passwall-luci \
  package/passwall

log "旧包清理完成"
mkdir -p package

clone_repo() {
    local repo="$1"
    local dest="$2"
    local label="$3"

    log "检查 $label 仓库..."
    if ! git ls-remote --exit-code --heads "$repo" "$PASSWALL_BRANCH" >/dev/null 2>&1; then
        die "$label 仓库无法访问或分支不存在：$repo（分支：$PASSWALL_BRANCH）。请检查 URL/网络；不要输入 GitHub 账号密码。"
    fi

    log "克隆 $label ..."
    git clone --depth=1 --single-branch --branch "$PASSWALL_BRANCH" "$repo" "$dest" \
      || die "$label 克隆失败：$repo"
}

clone_repo "$PASSWALL_PACKAGES_REPO" "package/passwall-packages" "passwall-packages"
clone_repo "$PASSWALL_LUCI_REPO" "package/passwall-luci" "luci-app-passwall"

# Confirm that the expected package Makefile exists before editing .config.
[[ -f package/passwall-luci/luci-app-passwall/Makefile ]] \
  || die "源码已克隆，但未找到 package/passwall-luci/luci-app-passwall/Makefile；请检查上游仓库结构。"

# Enable PassWall in the firmware configuration. Keep this idempotent.
touch .config
if grep -q '^CONFIG_PACKAGE_luci-app-passwall=' .config; then
    sed -i 's/^CONFIG_PACKAGE_luci-app-passwall=.*/CONFIG_PACKAGE_luci-app-passwall=y/' .config
else
    printf '%s\n' 'CONFIG_PACKAGE_luci-app-passwall=y' >> .config
fi

# Optional: enable PassWall Chinese translation if this package exists in this checkout.
if find package/passwall-luci/luci-app-passwall -path '*/po/zh-cn/*' -type f -print -quit 2>/dev/null | grep -q .; then
    if grep -q '^CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=' .config; then
        sed -i 's/^CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=.*/CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y/' .config
    else
        printf '%s\n' 'CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y' >> .config
    fi
fi

log "PassWall 源码克隆完成"
log "已启用 CONFIG_PACKAGE_luci-app-passwall=y"
log "后续请继续执行工作流原有的 feeds install / make defconfig 步骤，以解析依赖。"
