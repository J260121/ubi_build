#!/usr/bin/env bash
set -Eeuo pipefail

# TurboACC integration for J260121/ubi_build ImmortalWrt builds.
# Safe mode: adds the LuCI app and enables built-in flow offloading/BBR options
# when available. It deliberately does NOT replace firewall4/nftables/libnftnl
# or apply SFE/full-cone patches automatically.

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"
TURBOACC_REPO="${TURBOACC_REPO:-https://github.com/chenmozhijin/turboacc.git}"
TURBOACC_BRANCH="${TURBOACC_BRANCH:-luci}"
PKG_DIR="$OPENWRT_DIR/package/turboacc/luci-app-turboacc"
CONFIG_FILE="$OPENWRT_DIR/.config"

log() { printf '[TurboACC] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ -d "$OPENWRT_DIR" ]] || die "OpenWrt source directory not found: $OPENWRT_DIR"
[[ -f "$OPENWRT_DIR/Makefile" ]] || die "Not an OpenWrt source tree: $OPENWRT_DIR"
[[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE; copy the selected device config before running this script."

cd "$OPENWRT_DIR"
mkdir -p "$OPENWRT_DIR/package/turboacc"

if [[ ! -f "$PKG_DIR/Makefile" ]]; then
  log "Cloning TurboACC LuCI package (branch: $TURBOACC_BRANCH)..."
  rm -rf "$PKG_DIR"
  git clone --depth=1 --branch "$TURBOACC_BRANCH" "$TURBOACC_REPO" "$PKG_DIR" \
    || die "Failed to clone TurboACC. Check network access and branch name."
fi

[[ -f "$PKG_DIR/Makefile" ]] || die "luci-app-turboacc/Makefile not found after clone."

append_config() {
  local key="$1"
  if grep -qxF "${key}=y" "$CONFIG_FILE"; then
    log "$key already enabled"
  else
    sed -i "/^${key}=.*/d; /^# ${key} is not set$/d" "$CONFIG_FILE"
    printf '%s=y\n' "$key" >> "$CONFIG_FILE"
    log "Enabled $key"
  fi
}

append_config CONFIG_PACKAGE_luci-app-turboacc

# These packages are part of standard OpenWrt/ImmortalWrt feeds on many builds.
# Enable only if their symbols are recognized by the selected tree.
for key in CONFIG_PACKAGE_kmod-nft-offload CONFIG_PACKAGE_kmod-tcp-bbr; do
  if grep -RqsE "^(config ${key#CONFIG_PACKAGE_}|[[:space:]]+config ${key#CONFIG_PACKAGE_})$" \
      package/kernel/linux/modules package/network/utils package 2>/dev/null; then
    append_config "$key"
  else
    log "Optional package symbol not found in current source; skipping $key"
  fi
done

log "TurboACC LuCI package staged."
log "Run make defconfig after this script."
log "Safe mode does not patch/replace firewall4, nftables, libnftnl, or add Shortcut-FE/full-cone patches."
