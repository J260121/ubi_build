#!/bin/bash
# ============================================================
# TurboACC binary precompile
# Repository: J260121/ubi_build
# Target: aarch64_cortex-a53
# File: scripts/diy-turboacc.sh
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

# 1. Locate OpenWrt source
ROOT="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"

if [ ! -f "$ROOT/Makefile" ]; then
    ROOT="$PWD"
fi

[ -f "$ROOT/Makefile" ] || die "OpenWrt source directory not found"
[ -x "$ROOT/scripts/feeds" ] || die "scripts/feeds not found"
[ -f "$ROOT/.config" ] || die ".config missing; configure OpenWrt first"

cd "$ROOT"

OUT="${TURBOACC_OUT:-${GITHUB_WORKSPACE:-$ROOT}/turboacc-prebuilt}"
mkdir -p "$OUT"

log "OpenWrt source: $ROOT"
log "IPK output: $OUT"

# 2. Ensure LuCI feed exists
if [ ! -f feeds/luci/luci.mk ]; then
    log "Updating LuCI feed..."
    ./scripts/feeds update luci \
        || die "Failed to update LuCI feed"
fi

[ -f feeds/luci/luci.mk ] \
    || die "feeds/luci/luci.mk is missing"

# 3. Install LuCI dependency definitions
./scripts/feeds install luci-base \
    || die "Failed to install luci-base"

# 4. Integrate TurboACC source
TURBOACC_MAKEFILE="package/turboacc/luci-app-turboacc/Makefile"

if [ ! -f "$TURBOACC_MAKEFILE" ]; then
    log "Downloading TurboACC integration script..."

    curl -fL --retry 3 \
        https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh \
        -o /tmp/add_turboacc.sh \
        || die "Failed to download TurboACC integration script"

    bash /tmp/add_turboacc.sh --no-sfe \
        || die "TurboACC integration failed"
fi

[ -f "$TURBOACC_MAKEFILE" ] \
    || die "TurboACC LuCI package Makefile not found"

# 5. Enable LuCI package
if grep -q '^CONFIG_PACKAGE_luci-app-turboacc=' .config; then
    sed -i \
        's/^CONFIG_PACKAGE_luci-app-turboacc=.*/CONFIG_PACKAGE_luci-app-turboacc=y/' \
        .config
else
    echo 'CONFIG_PACKAGE_luci-app-turboacc=y' >> .config
fi

# 6. Resolve package configuration
log "Running make defconfig..."
make defconfig || die "make defconfig failed"

if ! grep -q '^CONFIG_PACKAGE_luci-app-turboacc=y$' .config; then
    die "luci-app-turboacc is not enabled; check package dependencies"
fi

# 7. Compile TurboACC IPK
# Toolchain is not checked, cleaned or rebuilt here.
log "Compiling luci-app-turboacc..."

make package/turboacc/luci-app-turboacc/compile -j1 V=s \
    || die "luci-app-turboacc compilation failed"

# 8. Collect generated IPKs
log "Collecting generated IPKs..."

find bin/packages -type f -name '*turboacc*.ipk' \
    -exec cp -f '{}' "$OUT/" \;

find bin/packages -type f \
    \( -name '*nft-fullcone*.ipk' -o \
       -name '*shortcut-fe*.ipk' \) \
    -exec cp -f '{}' "$OUT/" \;

# 9. Validate output
if ! find "$OUT" -maxdepth 1 -type f -name '*.ipk' | grep -q .; then
    die "No IPK files collected; check bin/packages"
fi

# 10. Generate manifest
{
    echo "TurboACC binary precompile"
    echo "Target: aarch64_cortex-a53"
    echo "Repository: https://github.com/chenmozhijin/turboacc"
    echo "Branch: luci"
    echo "Build time UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "Generated IPKs:"
    find "$OUT" -maxdepth 1 -type f -name '*.ipk' \
        -printf '%f\n' | sort
} > "$OUT/MANIFEST.txt"

log "Precompile completed."
ls -lh "$OUT"
