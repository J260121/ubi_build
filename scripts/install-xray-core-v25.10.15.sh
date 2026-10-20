#!/usr/bin/env bash
# Xray-core ARM64 integration for J260121/ubi_build
# Add this file to scripts/ and select its filename in plugin_scripts.
# The workflow invokes plugin scripts from the OpenWrt source tree, before
# feeds install / make defconfig. This script must NOT run make defconfig.

set -Eeuo pipefail

log() { printf '[Xray] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# The workflow's plugin hook runs from OPENWRT_DIR. Fall back to the current
# directory so the script can also be run manually from the OpenWrt source.
OPENWRT_DIR="${OPENWRT_DIR:-$PWD}"
[[ -d "$OPENWRT_DIR/package" && -d "$OPENWRT_DIR/target" ]] \
  || die "OpenWrt source tree not detected at: $OPENWRT_DIR"
[[ -n "${GITHUB_WORKSPACE:-}" ]] || die "GITHUB_WORKSPACE is not set."

command -v curl >/dev/null 2>&1 || die "curl is required."
command -v unzip >/dev/null 2>&1 || die "unzip is required."

VERSION="25.10.15"
URL="https://github.com/XTLS/Xray-core/releases/download/v${VERSION}/Xray-linux-arm64-v8a.zip"
BIN_DIR="$OPENWRT_DIR/files/usr/bin"
ETC_DIR="$OPENWRT_DIR/files/etc/xray"
INIT_DIR="$OPENWRT_DIR/files/etc/init.d"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$BIN_DIR" "$ETC_DIR" "$INIT_DIR"

log "Downloading Xray-core v${VERSION} ARM64..."
curl --fail --location --retry 3 --retry-delay 2 \
  --connect-timeout 20 --max-time 600 \
  "$URL" -o "$TMP_DIR/xray.zip" \
  || die "Download failed: $URL"

unzip -oq "$TMP_DIR/xray.zip" -d "$TMP_DIR/extracted" \
  || die "Could not extract Xray archive."
[[ -s "$TMP_DIR/extracted/xray" ]] \
  || die "The downloaded archive does not contain an xray executable."

install -m 0755 "$TMP_DIR/extracted/xray" "$BIN_DIR/xray"

# Add a procd init script so Xray can be started with /etc/init.d/xray.
# A working proxy configuration is intentionally not fabricated; Xray needs
# the user's own /etc/xray/config.json before it can provide a proxy service.
cat > "$INIT_DIR/xray" <<'INIT'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

start_service() {
    local config="/etc/xray/config.json"

    if [ ! -s "$config" ]; then
        logger -t xray "Not starting: $config is missing or empty"
        echo "Xray: missing $config; install a valid Xray configuration first." >&2
        return 1
    fi

    procd_open_instance
    procd_set_param command /usr/bin/xray run -config "$config"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INIT
chmod 0755 "$INIT_DIR/xray"

# Enable the service at boot in the rootfs overlay.
mkdir -p "$OPENWRT_DIR/files/etc/rc.d"
ln -snf ../init.d/xray "$OPENWRT_DIR/files/etc/rc.d/S99xray"

log "Xray binary installed: files/usr/bin/xray"
log "procd service added and enabled for boot."
log "After flashing, place a valid config at /etc/xray/config.json."
log "Then start with: /etc/init.d/xray start"
log "The workflow will continue with feeds install and make defconfig."
