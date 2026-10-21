#!/usr/bin/env bash
# Integrate official SSR Plus+ and architecture-matched prebuilt proxy cores
# into an OpenWrt/ImmortalWrt source build. Run before `make defconfig`.
set -Eeuo pipefail

RELEASE="v196.19"
RELEASE_API="https://api.github.com/repos/fw876/helloworld/releases/tags/${RELEASE}"
OPENWRT_DIR="${OPENWRT_DIR:-$PWD}"

if [[ ! -f "$OPENWRT_DIR/include/toplevel.mk" || ! -d "$OPENWRT_DIR/package" ]]; then
  echo "[SSRPlus-IPK] ERROR: $OPENWRT_DIR is not an OpenWrt source root." >&2
  echo "[SSRPlus-IPK] Set OPENWRT_DIR=/path/to/openwrt before running." >&2
  exit 1
fi
for cmd in curl jq tar awk sed grep tr find head sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[SSRPlus-IPK] Missing command: $cmd" >&2; exit 1; }
done

# Fixed package architecture as requested for this firmware target.
# This intentionally does not depend on .config being generated yet.
ARCH="aarch64_cortex-a53"
echo "[SSRPlus-IPK] Fixed package architecture: ${ARCH}"

WORK_DIR="$OPENWRT_DIR/tmp/ssrplus-ipk-${RELEASE}"
WRAPPER_PREFIX="$OPENWRT_DIR/package/ssrplus-prebuilt-"
mkdir -p "$WORK_DIR"
rm -rf "${WRAPPER_PREFIX}luci-app-ssr-plus" "${WRAPPER_PREFIX}mihomo" "${WRAPPER_PREFIX}xray-core"

API_JSON="$WORK_DIR/release.json"
echo "[SSRPlus-IPK] Fetching release asset list: $RELEASE"
curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 \
  -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
  -o "$API_JSON" "$RELEASE_API"

# Resolve asset URLs from the release API instead of hard-coding core version numbers.
asset_url() {
  local regex="$1" result
  result="$(jq -r --arg re "$regex" '[.assets[] | select(.name | test($re; "i"))] | first | .browser_download_url // empty' "$API_JSON")"
  if [[ -z "$result" || "$result" == "null" ]]; then
    echo "[SSRPlus-IPK] ERROR: no release asset matched: $regex" >&2
    echo "[SSRPlus-IPK] Available IPK assets:" >&2
    jq -r '.assets[].name | select(endswith(".ipk"))' "$API_JSON" >&2
    exit 1
  fi
  printf '%s' "$result"
}

APP_URL="$(asset_url '^luci-app-ssr-plus_.*_all\.ipk$')"
MIHOMO_URL="$(asset_url "^mihomo_.*_${ARCH//./\\.}\\.ipk$")"
XRAY_URL="$(asset_url "^xray-core_.*_${ARCH//./\\.}\\.ipk$")"

download_ipk() {
  local url="$1" output="$2" code
  echo "[SSRPlus-IPK] Downloading $(basename "$output")"
  code="$(curl --fail --location --retry 3 --retry-all-errors --retry-delay 2 \
    --connect-timeout 20 --max-time 300 -A 'Mozilla/5.0 SSRPlus-build' \
    -H 'Accept: application/octet-stream' -w '%{http_code}' -o "$output" "$url")"
  [[ "$code" == "200" && -s "$output" ]] || { echo "[SSRPlus-IPK] ERROR: HTTP $code downloading $url" >&2; exit 1; }
  if command -v ar >/dev/null 2>&1 && ar t "$output" >/dev/null 2>&1; then return 0; fi
  tar -tf "$output" >/dev/null 2>&1 || { echo "[SSRPlus-IPK] ERROR: invalid IPK container: $output" >&2; exit 1; }
}

unpack_outer() {
  local ipk="$1" dest="$2"
  mkdir -p "$dest"
  if command -v ar >/dev/null 2>&1 && ar t "$ipk" >/dev/null 2>&1; then
    (cd "$dest" && ar x "$ipk")
  else
    tar -xf "$ipk" -C "$dest"
  fi
}

# Read metadata and payload, then repack as a local no-compile package.
wrap_ipk() {
  local ipk="$1" key="$2" outer="$WORK_DIR/${key}-outer" payload="$WORK_DIR/${key}-payload"
  local control_file data_file pkg version depends pkgdir
  rm -rf "$outer" "$payload"
  mkdir -p "$outer" "$payload"
  unpack_outer "$ipk" "$outer"
  control_file="$(find "$outer" -maxdepth 1 -type f -name 'control.tar.*' -print -quit)"
  data_file="$(find "$outer" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)"
  [[ -n "$control_file" && -n "$data_file" ]] || { echo "[SSRPlus-IPK] ERROR: missing control/data archive in $ipk" >&2; exit 1; }
  local control_tmp="$WORK_DIR/${key}-control"
  rm -rf "$control_tmp"; mkdir -p "$control_tmp"
  tar -xf "$control_file" -C "$control_tmp"
  local control="$control_tmp/control"
  [[ -f "$control" ]] || control="$control_tmp/./control"
  [[ -f "$control" ]] || { echo "[SSRPlus-IPK] ERROR: missing package control metadata in $ipk" >&2; exit 1; }
  pkg="$(awk -F': ' 'tolower($1)=="package" {print $2; exit}' "$control")"
  version="$(awk -F': ' 'tolower($1)=="version" {print $2; exit}' "$control")"
  depends="$(awk 'BEGIN{IGNORECASE=1} /^Depends:[[:space:]]*/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$control" | tr ',' '\n' | sed -E 's/[[:space:]]*\([^)]*\)//g; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -Ev '^(|libc|kernel)$' | sort -u | sed 's/^/+/' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  [[ -n "$pkg" && -n "$version" ]] || { echo "[SSRPlus-IPK] ERROR: missing package name/version in $ipk" >&2; exit 1; }
  tar -xf "$data_file" -C "$payload"
  pkgdir="${WRAPPER_PREFIX}${pkg}"
  mkdir -p "$pkgdir/files"
  cp -a "$payload/." "$pkgdir/files/"
  cat > "$pkgdir/Makefile" <<MAKEFILE
include \$(TOPDIR)/rules.mk

PKG_NAME:=${pkg}
PKG_VERSION:=${version}
PKG_RELEASE:=1
PKGARCH:=all

include \$(INCLUDE_DIR)/package.mk

define Package/${pkg}
  SECTION:=net
  CATEGORY:=Network
  TITLE:=${pkg} (prebuilt release payload)
  DEPENDS:=${depends}
endef

define Package/${pkg}/description
 Prebuilt ${pkg} payload extracted from the official ${RELEASE} release IPK.
endef

define Build/Compile
endef

define Package/${pkg}/install
 \$(INSTALL_DIR) \$(1)
 \$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,${pkg}))
MAKEFILE
  echo "[SSRPlus-IPK] Wrapped $pkg version $version"
}

# Download the LuCI package and the two common prebuilt cores for this target architecture.
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

echo "[SSRPlus-IPK] Integrated SSR Plus+ with prebuilt cores for architecture: $ARCH"
echo "[SSRPlus-IPK] Next run from source root: make defconfig"
echo "[SSRPlus-IPK] Check that CONFIG_PACKAGE_luci-app-ssr-plus=y, CONFIG_PACKAGE_mihomo=y and CONFIG_PACKAGE_xray-core=y remain enabled."
echo "[SSRPlus-IPK] Note: do not also install package/helloworld or a helloworld feed, as it would duplicate package names."
