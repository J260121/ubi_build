```bash
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

# ------------------------------------------------------------
# 1. Locate OpenWrt source
# ------------------------------------------------------------

ROOT="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"

if [ ! -f "$ROOT/Makefile" ]; then
    ROOT="$PWD"
fi

[ -f "$ROOT/Makefile" ] || die "OpenWrt source directory not found"
[ -x "$ROOT/scripts/feeds" ] || die "OpenWrt feeds script missing"
[ -f "$ROOT/.config" ] || die ".config missing; configure OpenWrt first"

cd "$ROOT"

OUT="${TURBOACC_OUT:-${GITHUB_WORKSPACE:-$ROOT}/turboacc-prebuilt}"
mkdir -p "$OUT"

log "OpenWrt source: $ROOT"
log "IPK output: $OUT"

# ------------------------------------------------------------
# 2. Initialize LuCI feed
# ------------------------------------------------------------

if [ ! -f feeds/luci/luci.mk ]; then
    log "LuCI feed missing; updating feed..."

    ./scripts/feeds update luci \
        || die "Failed to update LuCI feed"
fi

[ -f feeds/luci/luci.mk ] \
    || die "feeds/luci/luci.mk is still missing"

# Install LuCI base package definition.
./scripts/feeds install luci-base \
    || die "Failed to install luci-base"

# ------------------------------------------------------------
# 3. Integrate TurboACC source
# ------------------------------------------------------------

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
    || die "TurboACC LuCI Makefile not found"

[ -f feeds/luci/luci.mk ] \
    || die "LuCI feed makefile missing after integration"

# ------------------------------------------------------------
# 4. Enable TurboACC package
# ------------------------------------------------------------

if grep -q '^CONFIG_PACKAGE_luci-app-turboacc=' .config; then
    sed -i \
        's/^CONFIG_PACKAGE_luci-app-turboacc=.*/CONFIG_PACKAGE_luci-app-turboacc=y/' \
        .config
else
    echo 'CONFIG_PACKAGE_luci-app-turboacc=y' >> .config
fi

log "Resolving package configuration..."
make defconfig || die "make defconfig failed"

if ! grep -q '^CONFIG_PACKAGE_luci-app-turboacc=y$' .config; then
    die "TurboACC was not selected; check package dependencies"
fi

# ------------------------------------------------------------
# 5. Check target toolchain and musl loader
# ------------------------------------------------------------

check_toolchain() {
    local tc
    tc="$(find staging_dir -maxdepth 1 -type d \
        -name 'toolchain-aarch64_cortex-a53_*_musl' -print -quit)"

    [ -n "$tc" ] || return 1
    [ -d "$tc/lib" ] || return 1

    find "$tc/lib" -maxdepth 1 \
        -name 'ld-musl-*.so*' -print -quit 2>/dev/null | grep -q .
}

if ! check_toolchain; then
    log "Toolchain or musl loader missing; rebuilding toolchain..."

    # Remove only the target toolchain build state.
    # Do not fabricate or copy a loader from another build.
    make toolchain/clean \
        || die "Toolchain clean failed"

    make toolchain/install -j1 V=s \
        || die "Toolchain rebuild failed"
fi

check_toolchain \
    || die "musl loader is still missing after toolchain rebuild"

log "Toolchain check passed."

# ------------------------------------------------------------
# 6. Compile TurboACC LuCI IPK
# ------------------------------------------------------------

log "Compiling luci-app-turboacc..."

make package/turboacc/luci-app-turboacc/compile -j1 V=s \
    || die "luci-app-turboacc compilation failed"

# ------------------------------------------------------------
# 7. Collect generated IPKs
# ------------------------------------------------------------

log "Collecting TurboACC IPKs..."

find bin/packages -type f -name '*turboacc*.ipk' \
    -exec cp -f '{}' "$OUT/" \;

# Collect related packages only if they were actually built.
find bin/packages -type f \
    \( -name '*nft-fullcone*.ipk' -o \
       -name '*shortcut-fe*.ipk' \) \
    -exec cp -f '{}' "$OUT/" \;

# ------------------------------------------------------------
# 8. Validate output and write manifest
# ------------------------------------------------------------

if ! find "$OUT" -maxdepth 1 -type f -name '*.ipk' | grep -q .; then
    die "No IPK files collected; inspect bin/packages and build logs"
fi

{
    echo "TurboACC binary precompile"
    echo "Target architecture: aarch64_cortex-a53"
    echo "Source: https://github.com/chenmozhijin/turboacc"
    echo "Branch: luci"
    echo "Build time UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "Generated IPKs:"
    find "$OUT" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sort
} > "$OUT/MANIFEST.txt"

log "Precompile completed."
ls -lh "$OUT"
```
