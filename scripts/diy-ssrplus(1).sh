#!/usr/bin/env bash
# Integrate SSR Plus+ v196.19 release IPKs as local no-source-build OpenWrt packages.
# Run after OpenWrt source tree exists and before make defconfig.
set -Eeuo pipefail

RELEASE="v196.19"
ARCH="aarch64_cortex-a53" # fixed as requested
OPENWRT_DIR="${OPENWRT_DIR:-$PWD}"

if [[ ! -f "$OPENWRT_DIR/include/toplevel.mk" || ! -d "$OPENWRT_DIR/package" ]]; then
  echo "[SSRPlus-IPK] ERROR: invalid OpenWrt source directory: $OPENWRT_DIR" >&2
  exit 1
fi
for cmd in curl jq tar awk sed grep tr find sort sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[SSRPlus-IPK] ERROR: missing command: $cmd" >&2; exit 1; }
done

WORK_DIR="$OPENWRT_DIR/tmp/ssrplus-ipk-$RELEASE"
PKG_ROOT="$OPENWRT_DIR/package"
API_JSON="$WORK_DIR/release.json"
mkdir -p "$WORK_DIR"

# Remove only the wrapper directories created by this script.
rm -rf "$PKG_ROOT/ssrplus-prebuilt-xray-core" \
       "$PKG_ROOT/ssrplus-prebuilt-mihomo" \
       "$PKG_ROOT/ssrplus-prebuilt-luci-app-ssr-plus"

echo "[SSRPlus-IPK] Fetching release metadata: $RELEASE"
curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/fw876/helloworld/releases/tags/$RELEASE" -o "$API_JSON"

asset_url() {
  local regex="$1" result
  result="$(jq -r --arg re "$regex" '[.assets[] | select(.name | test($re; "i"))] | first | .browser_download_url // empty' "$API_JSON")"
  if [[ -z "$result" || "$result" == null ]]; then
    echo "[SSRPlus-IPK] ERROR: release asset not found: $regex" >&2
    jq -r '.assets[].name' "$API_JSON" >&2
    exit 1
  fi
  printf '%s' "$result"
}

APP_URL="$(asset_url '^luci-app-ssr-plus_.*_all\.ipk$')"
MIHOMO_URL="$(asset_url "^mihomo_.*_${ARCH//./\\.}\\.ipk$")"
XRAY_URL="$(asset_url "^xray-core_.*_${ARCH//./\\.}\\.ipk$")"

download_ipk() {
  local url="$1" dest="$2"
  echo "[SSRPlus-IPK] Downloading $(basename "$dest")"
  curl -fL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 300 \
    -H 'Accept: application/octet-stream' -o "$dest" "$url"
  [[ -s "$dest" ]] || { echo "[SSRPlus-IPK] ERROR: empty download: $dest" >&2; exit 1; }
  if command -v ar >/dev/null 2>&1 && ar t "$dest" >/dev/null 2>&1; then return 0; fi
  tar -tf "$dest" >/dev/null 2>&1 || { echo "[SSRPlus-IPK] ERROR: invalid IPK: $dest" >&2; exit 1; }
}

unpack_outer() {
  local ipk="$1" out="$2"
  mkdir -p "$out"
  if command -v ar >/dev/null 2>&1 && ar t "$ipk" >/dev/null 2>&1; then
    (cd "$out" && ar x "$ipk")
  else
    tar -xf "$ipk" -C "$out"
  fi
}

wrap_ipk() {
  # Keep the key assignment separate to remain safe with set -u.
  local ipk="$1"
  local wrapper="$2"
  local outer="$WORK_DIR/${wrapper}-outer"
  local control_dir="$WORK_DIR/${wrapper}-control"
  local payload="$WORK_DIR/${wrapper}-payload"
  local control_file data_file control pkg version depends pkgdir

  rm -rf "$outer" "$control_dir" "$payload"
  mkdir -p "$outer" "$control_dir" "$payload"
  unpack_outer "$ipk" "$outer"
  control_file="$(find "$outer" -maxdepth 1 -type f -name 'control.tar.*' -print -quit)"
  data_file="$(find "$outer" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)"
  [[ -n "$control_file" && -n "$data_file" ]] || { echo "[SSRPlus-IPK] ERROR: missing control/data archive in $ipk" >&2; exit 1; }
  tar -xf "$control_file" -C "$control_dir"
  control="$control_dir/control"
  [[ -f "$control" ]] || { echo "[SSRPlus-IPK] ERROR: missing control metadata in $ipk" >&2; exit 1; }
  pkg="$(awk -F': *' 'tolower($1)=="package" {print $2; exit}' "$control")"
  version="$(awk -F': *' 'tolower($1)=="version" {print $2; exit}' "$control")"
  depends="$(awk 'BEGIN{IGNORECASE=1} /^Depends:[[:space:]]*/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$control" | tr ',' '\n' | sed -E 's/[[:space:]]*\([^)]*\)//g; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -Ev '^(|libc|kernel)$' | sort -u | sed 's/^/+/' | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
  [[ -n "$pkg" && -n "$version" ]] || { echo "[SSRPlus-IPK] ERROR: missing Package/Version in $ipk" >&2; exit 1; }
  tar -xf "$data_file" -C "$payload"

  case "$pkg" in
    xray-core) pkgdir="$PKG_ROOT/ssrplus-prebuilt-xray-core" ;;
    mihomo) pkgdir="$PKG_ROOT/ssrplus-prebuilt-mihomo" ;;
    luci-app-ssr-plus) pkgdir="$PKG_ROOT/ssrplus-prebuilt-luci-app-ssr-plus" ;;
    *) echo "[SSRPlus-IPK] ERROR: unexpected package name in IPK: $pkg" >&2; exit 1 ;;
  esac
  mkdir -p "$pkgdir/files"
  cp -a "$payload/." "$pkgdir/files/"

  # Preserve the official package name so other packages can depend on it.
  # PKGARCH must match this target's architecture for the binary core IPKs.
  local pkgarch="all"
  [[ "$pkg" == "xray-core" || "$pkg" == "mihomo" ]] && pkgarch="$ARCH"
  cat > "$pkgdir/Makefile" <<MAKEFILE
include \$(TOPDIR)/rules.mk

PKG_NAME:=${pkg}
PKG_VERSION:=${version}
PKG_RELEASE:=1
PKGARCH:=${pkgarch}

include \$(INCLUDE_DIR)/package.mk

define Package/${pkg}
  SECTION:=net
  CATEGORY:=Network
  TITLE:=${pkg} (prebuilt ${RELEASE} payload)
  DEPENDS:=${depends}
endef

define Package/${pkg}/description
  Prebuilt payload from the official ${RELEASE} release IPK.
endef

define Build/Compile
endef

define Package/${pkg}/install
  \$(INSTALL_DIR) \$(1)
  \$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,${pkg}))
MAKEFILE
  echo "[SSRPlus-IPK] Prepared $pkg $version (PKGARCH=$pkgarch) in $pkgdir"
}

download_ipk "$APP_URL" "$WORK_DIR/luci-app-ssr-plus.ipk"
download_ipk "$MIHOMO_URL" "$WORK_DIR/mihomo.ipk"
download_ipk "$XRAY_URL" "$WORK_DIR/xray-core.ipk"
wrap_ipk "$WORK_DIR/luci-app-ssr-plus.ipk" "ssrplus-app"
wrap_ipk "$WORK_DIR/mihomo.ipk" "ssrplus-mihomo"
wrap_ipk "$WORK_DIR/xray-core.ipk" "ssrplus-xray"

CONFIG_FILE="$OPENWRT_DIR/.config"
touch "$CONFIG_FILE"
for symbol in CONFIG_PACKAGE_luci-app-ssr-plus CONFIG_PACKAGE_mihomo CONFIG_PACKAGE_xray-core; do
  sed -i "/^${symbol}=y$/d; /^# ${symbol} is not set$/d" "$CONFIG_FILE"
  printf '%s=y\n' "$symbol" >> "$CONFIG_FILE"
done

echo "[SSRPlus-IPK] Done. Architecture fixed to $ARCH."
echo "[SSRPlus-IPK] Run make defconfig, then build."
echo "[SSRPlus-IPK] Do not also add helloworld feed/source packages with the same package names."
