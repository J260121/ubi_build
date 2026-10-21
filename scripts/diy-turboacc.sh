#!/usr/bin/env bash
# TurboACC LuCI integration for OpenWrt/ImmortalWrt cloud builds.
# Safe/minimal mode: adds the LuCI package only; does NOT replace firewall4,
# nftables, libnftnl, or apply kernel patches.

set -Eeuo pipefail

log() { printf '[TurboACC] %s\n' "$*"; }
die() { printf '[TurboACC] ERROR: %s\n' "$*" >&2; exit 1; }

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"
REPO_URL="${TURBOACC_REPO_URL:-https://github.com/chenmozhijin/turboacc.git}"
BRANCH="${TURBOACC_BRANCH:-luci}"
PKG_PARENT="$OPENWRT_DIR/package/turboacc"
PKG_DIR="$PKG_PARENT/luci-app-turboacc"
TMP_DIR="${RUNNER_TEMP:-/tmp}/turboacc-src-${GITHUB_RUN_ID:-$$}"

[[ -d "$OPENWRT_DIR" ]] || die "OpenWrt source directory not found: $OPENWRT_DIR"
[[ -f "$OPENWRT_DIR/Makefile" && -x "$OPENWRT_DIR/scripts/feeds" ]] || \
  die "OPENWRT_DIR does not look like an OpenWrt source tree: $OPENWRT_DIR"

command -v git >/dev/null 2>&1 || die "git is required"
command -v grep >/dev/null 2>&1 || die "grep is required"

log "OpenWrt source: $OPENWRT_DIR"
log "Cloning TurboACC repository branch '$BRANCH'..."
rm -rf "$TMP_DIR"
mkdir -p "$(dirname "$TMP_DIR")"
git clone --depth 1 --single-branch --branch "$BRANCH" "$REPO_URL" "$TMP_DIR" ||
  die "Could not clone $REPO_URL branch $BRANCH"

# On the upstream 'luci' branch the package is nested in the repository root:
# <repo>/luci-app-turboacc/Makefile. Do not expect Makefile at the repo root.
SOURCE_PKG="$TMP_DIR/luci-app-turboacc"
[[ -f "$SOURCE_PKG/Makefile" ]] || {
  log "Expected package path not found; checking repository layout..."
  FOUND_MAKEFILE="$(find "$TMP_DIR" -type f -path '*/luci-app-turboacc/Makefile' -print -quit || true)"
  [[ -n "$FOUND_MAKEFILE" ]] || die "No luci-app-turboacc/Makefile found in cloned branch '$BRANCH'"
  SOURCE_PKG="${FOUND_MAKEFILE%/Makefile}"
}

mkdir -p "$PKG_PARENT"
rm -rf "$PKG_DIR"
cp -a "$SOURCE_PKG" "$PKG_DIR"
[[ -f "$PKG_DIR/Makefile" ]] || die "Package copy failed: $PKG_DIR/Makefile missing"

# Enable the LuCI package in .config if available. If .config is generated later,
# set TURBOACC_CONFIG_FILE to a config fragment/file used by the workflow instead.
CONFIG_FILE="${TURBOACC_CONFIG_FILE:-$OPENWRT_DIR/.config}"
if [[ -f "$CONFIG_FILE" ]]; then
  if grep -q '^CONFIG_PACKAGE_luci-app-turboacc=' "$CONFIG_FILE"; then
    sed -i 's/^CONFIG_PACKAGE_luci-app-turboacc=.*/CONFIG_PACKAGE_luci-app-turboacc=y/' "$CONFIG_FILE"
  else
    printf '\nCONFIG_PACKAGE_luci-app-turboacc=y\n' >> "$CONFIG_FILE"
  fi
  log "Enabled CONFIG_PACKAGE_luci-app-turboacc=y in $CONFIG_FILE"
else
  log "No config file yet; add CONFIG_PACKAGE_luci-app-turboacc=y to your config fragment, or run this script after .config is generated."
fi

# Request stable, source-tree-supported acceleration packages when their Kconfig
# symbols exist in this tree. Do not force Shortcut-FE/full-cone patches.
if [[ -f "$CONFIG_FILE" ]]; then
  for symbol in kmod-nft-offload kmod-tcp-bbr; do
    if grep -Rqs --include='Makefile' --include='Config.in' --include='*.mk' \
      -E "Package[[:space:]]*:[[:space:]]*${symbol}|config[[:space:]]+PACKAGE_${symbol}" \
      "$OPENWRT_DIR/package" "$OPENWRT_DIR/target" 2>/dev/null; then
      if grep -q "^CONFIG_PACKAGE_${symbol}=" "$CONFIG_FILE"; then
        sed -i "s/^CONFIG_PACKAGE_${symbol}=.*/CONFIG_PACKAGE_${symbol}=y/" "$CONFIG_FILE"
      else
        printf 'CONFIG_PACKAGE_%s=y\n' "$symbol" >> "$CONFIG_FILE"
      fi
      log "Requested $symbol (available in source tree)"
    else
      log "Skipping $symbol: package definition not found in source tree"
    fi
  done
fi

rm -rf "$TMP_DIR"
log "TurboACC LuCI package integrated: $PKG_DIR"
log "This script intentionally does not patch/replace firewall4, nftables, or kernel sources."
log "Run make defconfig after this step, then compile as usual."
