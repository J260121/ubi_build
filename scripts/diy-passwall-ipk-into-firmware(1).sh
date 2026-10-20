#!/usr/bin/env bash
# Integrate the two official PassWall IPKs into an OpenWrt/ImmortalWrt source build.
# Run from the workflow after the OpenWrt source tree has been prepared, before make defconfig.
set -Eeuo pipefail

PASSWALL_VERSION="26.10.16"
PASSWALL_RELEASE="26.10.16-2"
PASSWALL_IPK_URL="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${PASSWALL_RELEASE}/22.03-_luci-app-passwall_${PASSWALL_VERSION}_all.ipk"
PASSWALL_ZH_URL="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${PASSWALL_RELEASE}/23.05-24.10_luci-i18n-passwall-zh-cn_${PASSWALL_VERSION}_all.ipk"

# Set OPENWRT_DIR if the source tree is not the current directory.
OPENWRT_DIR="${OPENWRT_DIR:-$PWD}"
if [[ ! -f "$OPENWRT_DIR/include/toplevel.mk" || ! -d "$OPENWRT_DIR/package" ]]; then
  echo "[PassWall-IPK] ERROR: $OPENWRT_DIR is not an OpenWrt source root." >&2
  echo "[PassWall-IPK] Set OPENWRT_DIR=/path/to/openwrt before running this script." >&2
  exit 1
fi

for cmd in curl tar awk sed grep tr find file head; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[PassWall-IPK] Missing command: $cmd" >&2; exit 1; }
done

WORK_DIR="$OPENWRT_DIR/tmp/passwall-ipk-${PASSWALL_RELEASE}"
APP_DIR="$OPENWRT_DIR/package/luci-app-passwall-prebuilt"
ZH_DIR="$OPENWRT_DIR/package/luci-i18n-passwall-zh-cn-prebuilt"
mkdir -p "$WORK_DIR"
rm -rf "$APP_DIR" "$ZH_DIR"
mkdir -p "$APP_DIR/files" "$ZH_DIR/files"

# Some mirrors/proxies can return an HTML error page with HTTP 200. Do not
# feed such a response to ar. A valid legacy OpenWrt IPK normally starts with
# the ar magic "!<arch>\\n"; accept tar-based containers too, but validate them.
package_format() {
  local f="$1"
  if command -v ar >/dev/null 2>&1 && ar t "$f" >/dev/null 2>&1; then
    echo "ar"
  elif tar -tf "$f" >/dev/null 2>&1; then
    echo "tar"
  elif gzip -t "$f" >/dev/null 2>&1 && tar -tzf "$f" >/dev/null 2>&1; then
    echo "gzip-tar"
  else
    return 1
  fi
}

download_ipk() {
  local url="$1" output="$2" http_code content_type
  echo "[PassWall-IPK] Downloading $(basename "$output")"
  http_code="$(curl --fail --location --retry 3 --retry-all-errors --retry-delay 2 \
       --connect-timeout 20 --max-time 300 \
       -A 'Mozilla/5.0 OpenWrt-PassWall-build' \
       -H 'Accept: application/octet-stream' \
       -w '%{http_code}' -o "$output" "$url")" || {
    echo "[PassWall-IPK] ERROR: download failed: $url" >&2
    exit 1
  }
  [[ "$http_code" == "200" && -s "$output" ]] || {
    echo "[PassWall-IPK] ERROR: HTTP $http_code or empty file: $url" >&2
    exit 1
  }

  if ! package_format "$output" >/dev/null; then
    echo "[PassWall-IPK] ERROR: downloaded file is not a recognized IPK/container." >&2
    echo "[PassWall-IPK] URL: $url" >&2
    echo "[PassWall-IPK] Size: $(wc -c < "$output") bytes" >&2
    echo "[PassWall-IPK] Detected type: $(file -b "$output" 2>/dev/null || echo unknown)" >&2
    echo "[PassWall-IPK] First 160 bytes:" >&2
    head -c 160 "$output" | tr '\\r' ' ' >&2 || true
    echo >&2
    echo "[PassWall-IPK] This usually means the URL returned an HTML/error page, not the IPK." >&2
    exit 1
  fi
  echo "[PassWall-IPK] Validated container: $(package_format "$output") ($(wc -c < "$output") bytes)"
}

unpack_container() {
  local input="$1" dest="$2" fmt
  mkdir -p "$dest"
  fmt="$(package_format "$input")" || {
    echo "[PassWall-IPK] ERROR: invalid package container: $input" >&2
    exit 1
  }
  case "$fmt" in
    ar) (cd "$dest" && ar x "$input") ;;
    tar) tar -xf "$input" -C "$dest" ;;
    gzip-tar) tar -xzf "$input" -C "$dest" ;;
  esac
}

extract_ipk() {
  local ipk="$1" dest="$2" temp="$3"
  rm -rf "$temp"
  mkdir -p "$temp" "$dest"
  unpack_container "$ipk" "$temp"

  local data_file=""
  for candidate in data.tar.gz data.tar.xz data.tar.zst data.tar; do
    if [[ -f "$temp/$candidate" ]]; then data_file="$temp/$candidate"; break; fi
  done

  if [[ -n "$data_file" ]]; then
    tar -xf "$data_file" -C "$dest"
  elif [[ -d "$temp/usr" || -d "$temp/etc" || -d "$temp/www" || -d "$temp/lib" ]]; then
    # Fallback for a tar container that already contains the root filesystem payload.
    cp -a "$temp/." "$dest/"
  else
    echo "[PassWall-IPK] ERROR: no data.tar.* payload found inside $ipk" >&2
    echo "[PassWall-IPK] Container contents:" >&2
    find "$temp" -maxdepth 2 -type f -print >&2
    exit 1
  fi

  [[ -n "$(find "$dest" -mindepth 1 -print -quit 2>/dev/null || true)" ]] || {
    echo "[PassWall-IPK] ERROR: empty payload: $ipk" >&2
    exit 1
  }
}

# Read package dependency names from an IPK control archive, keeping OpenWrt's
# dependency resolver involved. Xray packages are intentionally excluded.
read_dependencies() {
  local ipk="$1" temp="$2" control=""
  rm -rf "$temp"
  mkdir -p "$temp"
  unpack_container "$ipk" "$temp"

  for candidate in control.tar.gz control.tar.xz control.tar.zst control.tar; do
    [[ -f "$temp/$candidate" ]] && { control="$temp/$candidate"; break; }
  done
  [[ -n "$control" ]] || { echo ""; return 0; }

  (tar -xOf "$control" ./control 2>/dev/null || tar -xOf "$control" control 2>/dev/null) |
    awk 'BEGIN{IGNORECASE=1} /^Depends:[[:space:]]*/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' |
    tr ',' '\n' |
    sed -E 's/[[:space:]]*\([^)]*\)//g; s/^[[:space:]]+//; s/[[:space:]]+$//' |
    grep -Ev '^(|libc|kernel|xray-core|xray-plugin)$' |
    sort -u |
    sed 's/^/+/' |
    tr '\n' ' ' |
    sed 's/[[:space:]]*$//'
}

download_ipk "$PASSWALL_IPK_URL" "$WORK_DIR/luci-app-passwall.ipk"
download_ipk "$PASSWALL_ZH_URL" "$WORK_DIR/luci-i18n-passwall-zh-cn.ipk"

extract_ipk "$WORK_DIR/luci-app-passwall.ipk" "$APP_DIR/files" "$WORK_DIR/app-unpack"
extract_ipk "$WORK_DIR/luci-i18n-passwall-zh-cn.ipk" "$ZH_DIR/files" "$WORK_DIR/zh-unpack"

APP_DEPENDS="$(read_dependencies "$WORK_DIR/luci-app-passwall.ipk" "$WORK_DIR/app-control")"
ZH_DEPENDS="$(read_dependencies "$WORK_DIR/luci-i18n-passwall-zh-cn.ipk" "$WORK_DIR/zh-control")"
# The translation IPK may depend on the original package name; this build uses
# a wrapper package name, so replace that dependency with the wrapper below.
ZH_DEPENDS="$(printf '%s' "$ZH_DEPENDS" | sed -E 's/(^|[[:space:]])\+luci-app-passwall([[:space:]]|$)/ /g' | tr -s ' ' | sed 's/^ //; s/ $//')"

# Keep the base LuCI requirements even if the IPK's metadata omits them.
APP_DEPENDS="${APP_DEPENDS:+$APP_DEPENDS }+luci-base +luci-compat"
ZH_DEPENDS="${ZH_DEPENDS:+$ZH_DEPENDS }+luci-base +luci-app-passwall-prebuilt"

cat > "$APP_DIR/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=luci-app-passwall-prebuilt
PKG_VERSION:=${PASSWALL_VERSION}
PKG_RELEASE:=1
PKGARCH:=all

include \$(INCLUDE_DIR)/package.mk

define Package/luci-app-passwall-prebuilt
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=PassWall LuCI app (prebuilt payload)
  DEPENDS:=${APP_DEPENDS}
endef

define Package/luci-app-passwall-prebuilt/description
 PassWall LuCI application payload from the official ${PASSWALL_RELEASE} IPK.
 Xray packages are intentionally not selected or bundled by this wrapper.
endef

define Build/Compile
endef

define Package/luci-app-passwall-prebuilt/install
	\$(INSTALL_DIR) \$(1)
	\$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,luci-app-passwall-prebuilt))
EOF

cat > "$ZH_DIR/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-passwall-zh-cn-prebuilt
PKG_VERSION:=${PASSWALL_VERSION}
PKG_RELEASE:=1
PKGARCH:=all

include \$(INCLUDE_DIR)/package.mk

define Package/luci-i18n-passwall-zh-cn-prebuilt
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=PassWall Simplified Chinese translation (prebuilt payload)
  DEPENDS:=${ZH_DEPENDS}
endef

define Package/luci-i18n-passwall-zh-cn-prebuilt/description
 Simplified Chinese translation payload from the official ${PASSWALL_RELEASE} IPK.
endef

define Build/Compile
endef

define Package/luci-i18n-passwall-zh-cn-prebuilt/install
	\$(INSTALL_DIR) \$(1)
	\$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,luci-i18n-passwall-zh-cn-prebuilt))
EOF

# Select only the two wrapper packages. Do not modify any existing Xray setting.
CONFIG_FILE="$OPENWRT_DIR/.config"
touch "$CONFIG_FILE"
for symbol in \
  CONFIG_PACKAGE_luci-app-passwall-prebuilt \
  CONFIG_PACKAGE_luci-i18n-passwall-zh-cn-prebuilt; do
  sed -i "/^${symbol}=y$/d; /^# ${symbol} is not set$/d" "$CONFIG_FILE"
  printf '%s=y\n' "$symbol" >> "$CONFIG_FILE"
done

echo "[PassWall-IPK] Integrated downloaded IPK payloads as local OpenWrt packages."
echo "[PassWall-IPK] App wrapper dependencies: ${APP_DEPENDS:-none}"
echo "[PassWall-IPK] Chinese wrapper dependencies: ${ZH_DEPENDS:-none}"
echo "[PassWall-IPK] Existing Xray selections/files are left unchanged; Xray is not downloaded by this script."
echo "[PassWall-IPK] Next, run from source root:"
echo "  make defconfig"
echo "  make package/luci-app-passwall-prebuilt/compile V=s"
echo "  make package/luci-i18n-passwall-zh-cn-prebuilt/compile V=s"
echo "  make -j\$(nproc) || make -j1 V=s"
echo "[PassWall-IPK] IMPORTANT: verify the two CONFIG_PACKAGE_*_prebuilt=y lines remain after make defconfig."
