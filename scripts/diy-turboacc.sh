
#!/usr/bin/env bash
# TurboACC hybrid integration for ImmortalWrt / OpenWrt
# Fix missing kernel-module dependencies in luci-app-turboacc.
# Run after feeds installation and before make defconfig.

set -Eeuo pipefail

log() { printf '[TurboACC] %s\n' "$*"; }
die() { printf '[TurboACC] ERROR: %s\n' "$*" >&2; exit 1; }

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"
REPO_URL="${TURBOACC_REPO_URL:-https://github.com/chenmozhijin/turboacc.git}"
BRANCH="${TURBOACC_BRANCH:-luci}"
DEST_ROOT="$OPENWRT_DIR/package/turboacc"
DEST="$DEST_ROOT/luci-app-turboacc"
TMP="${RUNNER_TEMP:-/tmp}/turboacc-src-$$"
CONFIG="$OPENWRT_DIR/.config"

[[ -f "$OPENWRT_DIR/Makefile" ]] ||
  die "OpenWrt source not found: $OPENWRT_DIR"

command -v git >/dev/null 2>&1 || die "git is required"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# 1. Reuse an existing package, otherwise clone upstream.
if [[ -f "$DEST/Makefile" ]]; then
  log "Using existing package: $DEST"
else
  log "Cloning TurboACC branch: $BRANCH"
  mkdir -p "$(dirname "$TMP")"

  git clone --depth 1 --single-branch \
    --branch "$BRANCH" "$REPO_URL" "$TMP" ||
    die "TurboACC clone failed"

  SRC_MAKEFILE="$(find "$TMP" -type f \
    -path '*/luci-app-turboacc/Makefile' -print -quit)"

  [[ -n "$SRC_MAKEFILE" && -f "$SRC_MAKEFILE" ]] ||
    die "Cannot find luci-app-turboacc/Makefile in upstream branch"

  SRC_DIR="$(dirname "$SRC_MAKEFILE")"
  mkdir -p "$DEST_ROOT"
  rm -rf "$DEST"
  cp -a "$SRC_DIR" "$DEST"
fi

[[ -f "$DEST/Makefile" ]] ||
  die "Package Makefile missing: $DEST/Makefile"

# 2. Identify dependencies that are unavailable in this source tree.
# Check package Makefiles instead of assuming every branch has these modules.
package_exists() {
  local pkg="$1"
  local base="${pkg#kmod-}"

  grep -Rqs \
    --include='Makefile' \
    --include='*.mk' \
    -E "Package[[:space:]]*:[[:space:]]*${pkg}([[:space:]]|$)|define KernelPackage/${base}([[:space:]]|$)|define Package/${pkg}([[:space:]]|$)" \
    "$OPENWRT_DIR/package" \
    "$OPENWRT_DIR/target" \
    "$OPENWRT_DIR/feeds" 2>/dev/null
}

MISSING=()
for pkg in \
  kmod-fast-classifier \
  kmod-shortcut-fe-cm \
  kmod-shortcut-fe-drv \
  kmod-nft-fullcone
do
  if package_exists "$pkg"; then
    log "Dependency available: $pkg"
  else
    log "Dependency missing: $pkg"
    MISSING+=("$pkg")
  fi
done

# 3. Remove only dependencies proven missing.
# Preserve other dependencies and all unrelated Makefile settings.
if ((${#MISSING[@]} > 0)); then
  command -v perl >/dev/null 2>&1 ||
    die "Perl is required to safely edit the package dependency list"

  for pkg in "${MISSING[@]}"; do
    perl -i -pe '
      BEGIN { $p = $ARGV }
      s/(?<!\S)\+?\Q'"$pkg"'\E(?=\s|$)//g;
      s/[ \t]{2,}/ /g;
      s/[ \t]+$//;
    ' "$DEST/Makefile"
  done
fi

# 4. Verify no known missing dependency remains in DEPENDS declarations.
for pkg in \
  kmod-fast-classifier \
  kmod-shortcut-fe-cm \
  kmod-shortcut-fe-drv \
  kmod-nft-fullcone
do
  if ! package_exists "$pkg" &&
     grep -qE "DEPENDS.*${pkg}|^[[:space:]]*\+${pkg}([[:space:]]|$)" \
       "$DEST/Makefile"; then
    die "Missing dependency remains in Makefile: $pkg"
  fi
done

log "Final package dependency declarations:"
grep -nE 'DEPENDS|LUCI_DEPENDS' "$DEST/Makefile" || true

# 5. Enable only the LuCI package.
# Do not force unavailable kernel modules or stale prebuilt IPKs.
if [[ -f "$CONFIG" ]]; then
  if grep -q '^CONFIG_PACKAGE_luci-app-turboacc=' "$CONFIG"; then
    sed -i \
      's/^CONFIG_PACKAGE_luci-app-turboacc=.*/CONFIG_PACKAGE_luci-app-turboacc=y/' \
      "$CONFIG"
  else
    printf '\nCONFIG_PACKAGE_luci-app-turboacc=y\n' >> "$CONFIG"
  fi
  log "Enabled luci-app-turboacc"
else
  log "No .config yet; ensure CONFIG_PACKAGE_luci-app-turboacc=y is set before defconfig"
fi

log "TurboACC integration completed."
log "Run make defconfig, then compile normally."
log "Note: removed dependencies may represent unavailable acceleration features."
