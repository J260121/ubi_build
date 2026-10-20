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

for cmd in curl tar awk sed grep tr find; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[PassWall-IPK] Missing command: $cmd" >&2; exit 1; }
done
if ! command -v ar >/dev/null 2>&1; then
  echo "[PassWall-IPK] ERROR: 'ar' is required to unpack IPK files." >&2
  exit 1
fi

WORK_DIR="$OPENWRT_DIR/tmp/passwall-ipk-${PASSWALL_RELEASE}"
APP_DIR="$OPENWRT_DIR/package/luci-app-passwall-prebuilt"
ZH_DIR="$OPENWRT_DIR/package/luci-i18n-passwall-zh-cn-prebuilt"
mkdir -p "$WORK_DIR"
rm -rf "$APP_DIR" "$ZH_DIR"
mkdir -p "$APP_DIR/files" "$ZH_DIR/files"

download_ipk() {
  local url="$1" output="$2"
  echo "[PassWall-IPK] Downloading $(basename "$output")"
  curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 \
       --output "$output" "$url"
  [[ -s "$output" ]] || { echo "[PassWall-IPK] Download failed: $url" >&2; exit 1; }
  # IPKs are ar archives; reject HTML/error pages or malformed downloads.
  ar t "$output" >/dev/null
}

extract_ipk() {
  local ipk="$1" dest="$2" temp="$3"
  mkdir -p "$temp" "$dest"
  rm -f "$temp"/*
  (cd "$temp" && ar x "$ipk")
  local data_file=""
  for candidate in data.tar.gz data.tar.xz data.tar.zst data.tar; do
    if [[ -f "$temp/$candidate" ]]; then data_file="$temp/$candidate"; break; fi
  done
  [[ -n "$data_file" ]] || {
    echo "[PassWall-IPK] No supported data archive found in $ipk" >&2
    exit 1
  }
  tar -xf "$data_file" -C "$dest"
  [[ -n "$(find "$dest" -mindepth 1 -print -quit 2>/dev/null || true)" ]] || {
    echo "[PassWall-IPK] Empty data archive: $ipk" >&2
    exit 1
  }
}

# Read package dependency names from an IPK control archive, keeping OpenWrt's
# dependency resolver involved. Xray packages are intentionally excluded.
read_dependencies() {
  local ipk="$1" temp="$2" control=""
  mkdir -p "$temp"
  rm -f "$temp"/*
  (cd "$temp" && ar x "$ipk")
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
