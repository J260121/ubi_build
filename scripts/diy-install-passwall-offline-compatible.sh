#!/usr/bin/env bash
# Integrate PassWall into an OpenWrt source build so the flashed firmware works offline.
# Designed for J260121/ubi_build workflow:
# Runs from "Run Selected Plugin Scripts", after .config is loaded but before
# the workflow updates/installs feeds and runs make defconfig.
# Workflow input: plugin_scripts=install-passwall-offline.sh
# Optional manual usage: bash install-passwall-offline.sh /path/to/openwrt

set -Eeuo pipefail

XRAY_VERSION="${XRAY_VERSION:-v25.10.15}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.12.12}"
PASSWALL_BRANCH="${PASSWALL_BRANCH:-main}"
PASSWALL_PACKAGES_BRANCH="${PASSWALL_PACKAGES_BRANCH:-main}"

if [[ -n "${1:-}" ]]; then
  OPENWRT_DIR="$1"
elif [[ -n "${OPENWRT_DIR:-}" ]]; then
  :
elif [[ -n "${GITHUB_WORKSPACE:-}" && -d "$GITHUB_WORKSPACE/openwrt" ]]; then
  OPENWRT_DIR="$GITHUB_WORKSPACE/openwrt"
else
  OPENWRT_DIR="$PWD"
fi

OPENWRT_DIR="$(cd "$OPENWRT_DIR" && pwd)"
[[ -x "$OPENWRT_DIR/scripts/feeds" && -f "$OPENWRT_DIR/Makefile" ]] || {
  echo "[ERROR] Not an OpenWrt source directory: $OPENWRT_DIR" >&2; exit 1;
}
[[ -f "$OPENWRT_DIR/.config" ]] || {
  echo "[ERROR] .config not found. Load your device config before running this script." >&2; exit 1;
}

for cmd in git curl unzip tar python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] Missing required command: $cmd" >&2; exit 1; }
done

log() { printf '[PassWall offline] %s\n' "$*"; }
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log "OpenWrt source: $OPENWRT_DIR"
cd "$OPENWRT_DIR"
mkdir -p package

# Official repositories (use the exact public repository names from upstream docs).
log "Downloading official PassWall package sources..."
git clone --depth 1 --branch "$PASSWALL_PACKAGES_BRANCH" \
  https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git \
  "$TMP_DIR/passwall-packages"
git clone --depth 1 --branch "$PASSWALL_BRANCH" \
  https://github.com/Openwrt-Passwall/openwrt-passwall.git \
  "$TMP_DIR/passwall-luci"

# Remove feed copies that would otherwise shadow/conflict with PassWall's package versions.
for pkg in xray-core v2ray-geodata sing-box chinadns-ng dns2socks hysteria ipt2socks \
  microsocks naiveproxy shadowsocks-rust shadowsocksr-libev simple-obfs tcping \
  v2ray-plugin xray-plugin geoview shadow-tls; do
  rm -rf "feeds/packages/net/$pkg"
done
rm -rf feeds/luci/applications/luci-app-passwall

# Replace only the dedicated integration directories, keeping unrelated package sources intact.
rm -rf package/passwall-packages package/passwall-luci
mv "$TMP_DIR/passwall-packages" package/passwall-packages
mv "$TMP_DIR/passwall-luci" package/passwall-luci

# We supply Xray and sing-box as ARM64 release binaries in files/usr/bin. Disable their
# source-package selections, and disable optional geoview (the user's known failing Go build).
python3 - <<'PY'
from pathlib import Path
p = Path('package/passwall-luci/luci-app-passwall/Makefile')
if not p.is_file():
    raise SystemExit(f'[ERROR] PassWall Makefile not found: {p}')
s = p.read_text()

def patch_block(text, start_marker, end_marker, replacements):
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f'[ERROR] Could not find Kconfig block: {start_marker}')
    end = text.find(end_marker, start + len(start_marker))
    if end < 0:
        raise SystemExit(f'[ERROR] Could not find end marker: {end_marker}')
    block = text[start:end]
    for old, new in replacements:
        if old not in block:
            raise SystemExit(f'[ERROR] Expected text not found in {start_marker}: {old!r}')
        block = block.replace(old, new)
    return text[:start] + block + text[end:]

s = patch_block(
    s,
    'config PACKAGE_$(PKG_NAME)_INCLUDE_Geoview',
    'config PACKAGE_$(PKG_NAME)_INCLUDE_Haproxy',
    [('select PACKAGE_geoview\n', ''), ('default y if aarch64||arm||i386||x86_64', 'default n')],
)
s = patch_block(
    s,
    'config PACKAGE_$(PKG_NAME)_INCLUDE_SingBox',
    'config PACKAGE_$(PKG_NAME)_INCLUDE_V2ray_Geodata',
    [('select PACKAGE_sing-box\n', ''), ('default y if aarch64||arm||i386||x86_64', 'default n')],
)
s = patch_block(
    s,
    'config PACKAGE_$(PKG_NAME)_INCLUDE_Xray\n',
    'config PACKAGE_$(PKG_NAME)_INCLUDE_Xray_Plugin',
    [('select PACKAGE_xray-core\n', ''), ('select PACKAGE_unzip\n', ''), ('default y if aarch64||arm||i386||x86_64', 'default n')],
)
p.write_text(s)
PY

# Download the proxy cores into the OpenWrt rootfs overlay. These binaries are not
# opkg-managed packages; the PassWall app itself and its normal dependencies are built
# by OpenWrt and included in the image.
OVERLAY="$OPENWRT_DIR/files"
BIN_DIR="$OVERLAY/usr/bin"
mkdir -p "$BIN_DIR"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-arm64-v8a.zip"
SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-arm64.tar.gz"

log "Downloading Xray ${XRAY_VERSION}..."
curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 "$XRAY_URL" -o "$TMP_DIR/xray.zip"
mkdir -p "$TMP_DIR/xray"
unzip -oq "$TMP_DIR/xray.zip" -d "$TMP_DIR/xray"
XRAY_BIN="$(find "$TMP_DIR/xray" -type f -name xray -print -quit)"
[[ -n "$XRAY_BIN" ]] || { echo '[ERROR] xray binary not found in archive.' >&2; exit 1; }
install -m 0755 "$XRAY_BIN" "$BIN_DIR/xray"

log "Downloading sing-box ${SINGBOX_VERSION}..."
curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 "$SINGBOX_URL" -o "$TMP_DIR/sing-box.tar.gz"
tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR"
SINGBOX_BIN="$(find "$TMP_DIR" -type f -path '*/sing-box' -print -quit)"
[[ -n "$SINGBOX_BIN" ]] || { echo '[ERROR] sing-box binary not found in archive.' >&2; exit 1; }
install -m 0755 "$SINGBOX_BIN" "$BIN_DIR/sing-box"

# Select PassWall and Chinese UI. Core binaries are supplied by the overlay above.
# Disable geoview and source-built xray/sing-box package variants to avoid their build failures.
CONFIG="$OPENWRT_DIR/.config"
for key in \
  CONFIG_PACKAGE_luci-app-passwall \
  CONFIG_PACKAGE_luci-i18n-passwall-zh-cn \
  CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Geoview \
  CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray \
  CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox \
  CONFIG_PACKAGE_geoview CONFIG_PACKAGE_xray-core CONFIG_PACKAGE_sing-box; do
  sed -i "/^${key}=\|^# ${key} is not set$/d" "$CONFIG"
done
cat >> "$CONFIG" <<'CONFIG_EOF'
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Geoview=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=n
CONFIG_PACKAGE_geoview=n
CONFIG_PACKAGE_xray-core=n
CONFIG_PACKAGE_sing-box=n
CONFIG_EOF

# Important: the supplied workflow updates/installs feeds and runs make defconfig
# AFTER this script. Do not run make defconfig here or new package options may be
# dropped before their feed/package definitions are available.
log "Integration files prepared. The workflow will update/install feeds and run make defconfig next."
log "Selected: PassWall LuCI + Chinese UI; proxy binaries: Xray and sing-box."
log "Important: ARM64/AArch64 targets only; verify the final image and offline operation."
ls -lh "$BIN_DIR/xray" "$BIN_DIR/sing-box"
