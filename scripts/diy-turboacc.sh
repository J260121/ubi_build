#!/bin/bash
# ============================================================
# TurboACC binary precompile for J260121/ubi_build
# Target: aarch64_cortex-a53
# Script: scripts/diy-turboacc.sh
# ============================================================

set -Eeuo pipefail

log() {
    echo "[TurboACC-IPK] $*"
}

warn() {
    echo "[TurboACC-IPK] WARNING: $*" >&2
}

die() {
    echo "[TurboACC-IPK] ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# 1. Locate OpenWrt source directory
# ------------------------------------------------------------

ROOT="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"

if [ ! -f "$ROOT/Makefile" ]; then
    ROOT="$PWD"
fi

[ -f "$ROOT/Makefile" ] || die "OpenWrt source directory not found"

cd "$ROOT"

[ -x scripts/feeds ] || die "scripts/feeds not found"
[ -f feeds.conf.default ] || [ -f feeds.conf ] \
    || die "feeds.conf.default and feeds.conf are missing"

OUT="${TURBOACC_OUT:-${GITHUB_WORKSPACE:-$ROOT}/turboacc-prebuilt}"
mkdir -p "$OUT"

log "OpenWrt source: $ROOT"
log "Output directory: $OUT"

# ------------------------------------------------------------
# 2. Initialize LuCI feed
# ------------------------------------------------------------

if [ ! -f feeds/luci/luci.mk ]; then
    log "LuCI feed missing; updating..."

    ./scripts/feeds update luci \
        || die "Failed to update LuCI feed"

    [ -f feeds/luci/luci.mk ] \
        || die "feeds/luci/luci.mk is still missing"
fi

# Install only the required LuCI package definitions.
# Avoid installing every package in every feed unnecessarily.
if [ ! -e package/feeds/luci/luci-base ]; then
    ./scripts/feeds install luci-base \
        || warn "Could not install luci-base explicitly"
fi

# ------------------------------------------------------------
# 3. Integrate official TurboACC source
# ------------------------------------------------------------

TURBOACC_DIR="package/turboacc"
APP_MAKEFILE="$TURBOACC_DIR/luci-app-turboacc/Makefile"

if [ ! -f "$APP_MAKEFILE" ]; then
    log "Downloading official TurboACC integration script..."

    curl -fL --retry 3 \
        https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh \
        -o /tmp/add_turboacc.sh \
        || die "Failed to download TurboACC integration script"

    # Disable SFE to avoid the additional SFE kernel patch set.
    bash /tmp/add_turboacc.sh --no-sfe \
        || die "Official TurboACC integration failed"
fi

[ -f "$APP_MAKEFILE" ] \
    || die "TurboACC LuCI package Makefile not found"

# Verify the build system can see the LuCI makefile.
[ -f feeds/luci/luci.mk ] \
    || die "LuCI feed disappeared after integration"

# ------------------------------------------------------------
# 4. Install LuCI dependencies and package definitions
# ------------------------------------------------------------

./scripts/feeds install luci-base \
    || die "Failed to install luci-base"

# ------------------------------------------------------------
# 5. Enable TurboACC in configuration
# ------------------------------------------------------------

[ -f .config ] || die ".config is missing; generate configuration first"

if grep -q '^CONFIG_PACKAGE_luci-app-turboacc=' .config; then
    sed -i \
        's/^CONFIG_PACKAGE_luci-app-turboacc=.*/CONFIG_PACKAGE_luci-app-turboacc=y/' \
        .config
else
    echo 'CONFIG_PACKAGE_luci-app-turboacc=y' >> .config
fi

# Resolve dependencies and validate configuration.
log "Resolving package configuration..."
make defconfig || die "make defconfig failed"

if ! grep -q '^CONFIG_PACKAGE_luci-app-turboacc=y$' .config; then
    die "TurboACC was not selected by Kconfig; check package dependencies"
fi

# ------------------------------------------------------------
# 6. Build TurboACC LuCI binary package
# ------------------------------------------------------------

log "Building luci-app-turboacc..."

make package/turboacc/luci-app-turboacc/compile -j1 V=s \
    || die "luci-app-turboacc compilation failed"

# ------------------------------------------------------------
# 7. Collect generated IPK files
# ------------------------------------------------------------

log "Collecting generated IPK files..."

find bin/packages -type f -name '*turboacc*.ipk' \
    -exec cp -f '{}' "$OUT/" \;

# Optional related packages, only if built by this source tree.
find bin/packages -type f \
    \( -name '*nft-fullcone*.ipk' -o \
       -name '*shortcut-fe*.ipk' \) \
    -exec cp -f '{}' "$OUT/" \;

# ------------------------------------------------------------
# 8. Validate output
# ------------------------------------------------------------

if ! find "$OUT" -maxdepth 1 -type f -name '*.ipk' | grep -q .; then
    die "No IPK files collected; inspect bin/packages and build logs"
fi

# Record build information.
{
    echo "TurboACC binary precompile"
    echo "Target: aarch64_cortex-a53"
    echo "Repository: https://github.com/chenmozhijin/turboacc"
    echo "Branch: luci"
    echo "Build date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "IPK files:"
    find "$OUT" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sort
} > "$OUT/MANIFEST.txt"

log "Precompile completed."
ls -lh "$OUT"
