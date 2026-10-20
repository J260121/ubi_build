#!/usr/bin/env bash
# Integrate prebuilt PassWall + PassWall2 LuCI IPKs and Xray-core into
# an ImmortalWrt/OpenWrt 24.10 source build.
# Based on the user's diy-passwall-ipk-into-firmware.sh template.
# Run after the OpenWrt source tree is prepared and before make defconfig.
set -Eeuo pipefail

log() { printf '[Proxy-Prebuilt] %s\n' "$*"; }
die() { printf '[Proxy-Prebuilt][ERROR] %s\n' "$*" >&2; exit 1; }

# Versions can be overridden from the workflow environment.
PASSWALL_VERSION="${PASSWALL_VERSION:-26.10.16}"
PASSWALL_RELEASE="${PASSWALL_RELEASE:-26.10.16-2}"
PASSWALL2_VERSION="${PASSWALL2_VERSION:-26.10.1}"
PASSWALL2_RELEASE="${PASSWALL2_RELEASE:-26.10.1-2}"
XRAY_VERSION="${XRAY_VERSION:-v25.10.15}"

PASSWALL_BASE="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${PASSWALL_RELEASE}"
PASSWALL2_BASE="https://github.com/Openwrt-Passwall/openwrt-passwall2/releases/download/${PASSWALL2_RELEASE}"

PASSWALL_IPK_URL="${PASSWALL_IPK_URL:-${PASSWALL_BASE}/22.03-_luci-app-passwall_${PASSWALL_VERSION}_all.ipk}"
PASSWALL_ZH_URL="${PASSWALL_ZH_URL:-${PASSWALL_BASE}/23.05-24.10_luci-i18n-passwall-zh-cn_${PASSWALL_VERSION}_all.ipk}"
PASSWALL2_IPK_URL="${PASSWALL2_IPK_URL:-${PASSWALL2_BASE}/luci-app-passwall2_${PASSWALL2_VERSION}-r2_all.ipk}"
PASSWALL2_ZH_URL="${PASSWALL2_ZH_URL:-${PASSWALL2_BASE}/luci-i18n-passwall2-zh-cn_${PASSWALL2_VERSION}_all.ipk}"
XRAY_URL="${XRAY_URL:-https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-arm64-v8a.zip}"

OPENWRT_DIR="${OPENWRT_DIR:-$PWD}"
[[ -f "$OPENWRT_DIR/include/toplevel.mk" && -d "$OPENWRT_DIR/package" ]] || die \
  "$OPENWRT_DIR 不是 OpenWrt/ImmortalWrt 源码根目录。请设置 OPENWRT_DIR。"

for cmd in curl tar awk sed grep tr find file head wc unzip install; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
done
command -v ar >/dev/null 2>&1 || log "未检测到 ar；脚本仍会尝试使用 tar 容器格式。"

WORK_DIR="$OPENWRT_DIR/tmp/proxy-prebuilt-${PASSWALL_VERSION}-${PASSWALL2_VERSION}"
mkdir -p "$WORK_DIR"

# Local OpenWrt package wrappers. Package payloads from upstream IPKs are copied
# into these wrappers so the LuCI apps are included in the firmware image.
PW_APP_DIR="$OPENWRT_DIR/package/luci-app-passwall-prebuilt"
PW_ZH_DIR="$OPENWRT_DIR/package/luci-i18n-passwall-zh-cn-prebuilt"
PW2_APP_DIR="$OPENWRT_DIR/package/luci-app-passwall2-prebuilt"
PW2_ZH_DIR="$OPENWRT_DIR/package/luci-i18n-passwall2-zh-cn-prebuilt"

for d in "$PW_APP_DIR" "$PW_ZH_DIR" "$PW2_APP_DIR" "$PW2_ZH_DIR"; do
  if [[ -e "$d" && ! -f "$d/.proxy-prebuilt-managed" ]]; then
    die "$d 已存在且不是本脚本管理的目录。为避免覆盖源码，停止执行；请手动检查后移走该目录。"
  fi
done
for d in "$PW_APP_DIR" "$PW_ZH_DIR" "$PW2_APP_DIR" "$PW2_ZH_DIR"; do
  rm -rf "$d"
  mkdir -p "$d/files"
  : > "$d/.proxy-prebuilt-managed"
done

package_format() {
  local f="$1"
  if command -v ar >/dev/null 2>&1 && ar t "$f" >/dev/null 2>&1; then
    echo ar
  elif tar -tf "$f" >/dev/null 2>&1; then
    echo tar
  elif gzip -t "$f" >/dev/null 2>&1 && tar -tzf "$f" >/dev/null 2>&1; then
    echo gzip-tar
  else
    return 1
  fi
}

download_ipk() {
  local url="$1" output="$2" http_code
  log "下载 $(basename "$output")"
  http_code="$(curl --fail --location --retry 3 --retry-all-errors --retry-delay 2 \
    --connect-timeout 20 --max-time 300 \
    -A 'Mozilla/5.0 OpenWrt-PassWall-build' \
    -H 'Accept: application/octet-stream' \
    -w '%{http_code}' -o "$output" "$url")" || {
      die "下载失败：$url"
    }
  [[ "$http_code" == 200 && -s "$output" ]] || die "HTTP $http_code 或文件为空：$url"
  if ! package_format "$output" >/dev/null; then
    echo "[Proxy-Prebuilt] 无效 IPK：$url" >&2
    echo "[Proxy-Prebuilt] 文件大小：$(wc -c < "$output") bytes" >&2
    echo "[Proxy-Prebuilt] 文件类型：$(file -b "$output" 2>/dev/null || echo unknown)" >&2
    echo "[Proxy-Prebuilt] 前 160 字节：" >&2
    head -c 160 "$output" | tr '\r' ' ' >&2 || true
    echo >&2
    die "下载内容不是有效 IPK 容器，可能是错误页或资源地址已变更。"
  fi
  log "已验证 $(basename "$output")：$(package_format "$output")，$(wc -c < "$output") bytes"
}

unpack_container() {
  local input="$1" dest="$2" fmt
  mkdir -p "$dest"
  fmt="$(package_format "$input")" || die "无效容器：$input"
  case "$fmt" in
    ar) (cd "$dest" && ar x "$input") ;;
    tar) tar -xf "$input" -C "$dest" ;;
    gzip-tar) tar -xzf "$input" -C "$dest" ;;
  esac
}

extract_ipk() {
  local ipk="$1" dest="$2" temp="$3" data_file=""
  rm -rf "$temp"
  mkdir -p "$temp" "$dest"
  unpack_container "$ipk" "$temp"
  for candidate in data.tar.gz data.tar.xz data.tar.zst data.tar; do
    if [[ -f "$temp/$candidate" ]]; then data_file="$temp/$candidate"; break; fi
  done
  if [[ -n "$data_file" ]]; then
    tar -xf "$data_file" -C "$dest"
  elif [[ -d "$temp/usr" || -d "$temp/etc" || -d "$temp/www" || -d "$temp/lib" ]]; then
    cp -a "$temp/." "$dest/"
  else
    find "$temp" -maxdepth 2 -type f -print >&2
    die "IPK 内未找到 data.tar.*：$ipk"
  fi
  [[ -n "$(find "$dest" -mindepth 1 -print -quit 2>/dev/null || true)" ]] || die "IPK payload 为空：$ipk"
}

# Register the PassWall dependency feed so normal runtime dependencies can be resolved.
# geoview and xray-core are excluded from wrapper dependencies below: geoview previously
# failed in this user's build, while Xray is provided as a binary overlay by this script.
FEEDS_FILE="$OPENWRT_DIR/feeds.conf.default"
if [[ -f "$FEEDS_FILE" ]]; then
  if ! grep -Eq '^[[:space:]]*src-git[[:space:]]+passwall_packages[[:space:]]' "$FEEDS_FILE"; then
    tmp_feed="$(mktemp)"
    printf '%s\n' 'src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main' > "$tmp_feed"
    cat "$FEEDS_FILE" >> "$tmp_feed"
    cat "$tmp_feed" > "$FEEDS_FILE"
    rm -f "$tmp_feed"
  fi
  log "更新 PassWall 依赖 feed ..."
  "$OPENWRT_DIR/scripts/feeds" update passwall_packages
  "$OPENWRT_DIR/scripts/feeds" install -a -p passwall_packages
else
  log "未找到 feeds.conf.default，跳过依赖 feed 注册。"
fi

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
    grep -Ev '^(|libc|kernel|xray-core|xray-plugin|geoview|luci-app-passwall|luci-app-passwall2)$' |
    sort -u |
    sed 's/^/+/' |
    tr '\n' ' ' |
    sed 's/[[:space:]]*$//'
}

# Use the original IPK dependency metadata for available runtime packages, while
# excluding geoview (known to fail in this user's build) and xray-core (binary overlay).
write_wrapper() {
  local dir="$1" pkg="$2" version="$3" title="$4" depends="$5" description="$6"
  cat > "$dir/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=${pkg}
PKG_VERSION:=${version}
PKG_RELEASE:=1
PKGARCH:=all

include \$(INCLUDE_DIR)/package.mk

define Package/${pkg}
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=${title}
  DEPENDS:=${depends}
endef

define Package/${pkg}/description
 ${description}
endef

define Build/Compile
endef

define Package/${pkg}/install
	\$(INSTALL_DIR) \$(1)
	\$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,${pkg}))
EOF
}

# Download the four official LuCI IPKs and validate their containers before extraction.
download_ipk "$PASSWALL_IPK_URL" "$WORK_DIR/luci-app-passwall.ipk"
download_ipk "$PASSWALL_ZH_URL" "$WORK_DIR/luci-i18n-passwall-zh-cn.ipk"
download_ipk "$PASSWALL2_IPK_URL" "$WORK_DIR/luci-app-passwall2.ipk"
download_ipk "$PASSWALL2_ZH_URL" "$WORK_DIR/luci-i18n-passwall2-zh-cn.ipk"

extract_ipk "$WORK_DIR/luci-app-passwall.ipk" "$PW_APP_DIR/files" "$WORK_DIR/pw-app-unpack"
extract_ipk "$WORK_DIR/luci-i18n-passwall-zh-cn.ipk" "$PW_ZH_DIR/files" "$WORK_DIR/pw-zh-unpack"
extract_ipk "$WORK_DIR/luci-app-passwall2.ipk" "$PW2_APP_DIR/files" "$WORK_DIR/pw2-app-unpack"
extract_ipk "$WORK_DIR/luci-i18n-passwall2-zh-cn.ipk" "$PW2_ZH_DIR/files" "$WORK_DIR/pw2-zh-unpack"

PW_APP_DEPENDS="$(read_dependencies "$WORK_DIR/luci-app-passwall.ipk" "$WORK_DIR/pw-app-control")"
PW_ZH_DEPENDS="$(read_dependencies "$WORK_DIR/luci-i18n-passwall-zh-cn.ipk" "$WORK_DIR/pw-zh-control")"
PW2_APP_DEPENDS="$(read_dependencies "$WORK_DIR/luci-app-passwall2.ipk" "$WORK_DIR/pw2-app-control")"
PW2_ZH_DEPENDS="$(read_dependencies "$WORK_DIR/luci-i18n-passwall2-zh-cn.ipk" "$WORK_DIR/pw2-zh-control")"

# Keep required LuCI base dependencies; translations depend on the local wrapper names.
PW_APP_DEPENDS="${PW_APP_DEPENDS:+$PW_APP_DEPENDS }+luci-base +luci-compat"
PW2_APP_DEPENDS="${PW2_APP_DEPENDS:+$PW2_APP_DEPENDS }+luci-base +luci-compat"
PW_ZH_DEPENDS="$(printf '%s' "$PW_ZH_DEPENDS" | sed -E 's/(^|[[:space:]])\+luci-app-passwall([[:space:]]|$)/ /g' | tr -s ' ' | sed 's/^ //; s/ $//')"
PW2_ZH_DEPENDS="$(printf '%s' "$PW2_ZH_DEPENDS" | sed -E 's/(^|[[:space:]])\+luci-app-passwall2([[:space:]]|$)/ /g' | tr -s ' ' | sed 's/^ //; s/ $//')"
PW_ZH_DEPENDS="${PW_ZH_DEPENDS:+$PW_ZH_DEPENDS }+luci-base +luci-app-passwall-prebuilt"
PW2_ZH_DEPENDS="${PW2_ZH_DEPENDS:+$PW2_ZH_DEPENDS }+luci-base +luci-app-passwall2-prebuilt"

write_wrapper "$PW_APP_DIR" "luci-app-passwall-prebuilt" "$PASSWALL_VERSION" \
  "PassWall LuCI app (prebuilt)" "$PW_APP_DEPENDS" \
  "PassWall LuCI payload from the official IPK; xray-core is provided as an overlay binary."
write_wrapper "$PW_ZH_DIR" "luci-i18n-passwall-zh-cn-prebuilt" "$PASSWALL_VERSION" \
  "PassWall Simplified Chinese translation (prebuilt)" "$PW_ZH_DEPENDS" \
  "PassWall Simplified Chinese translation payload from the official IPK."
write_wrapper "$PW2_APP_DIR" "luci-app-passwall2-prebuilt" "$PASSWALL2_VERSION" \
  "PassWall2 LuCI app (prebuilt)" "$PW2_APP_DEPENDS" \
  "PassWall2 LuCI payload from the official IPK; geoview and xray-core are not package dependencies here."
write_wrapper "$PW2_ZH_DIR" "luci-i18n-passwall2-zh-cn-prebuilt" "$PASSWALL2_VERSION" \
  "PassWall2 Simplified Chinese translation (prebuilt)" "$PW2_ZH_DEPENDS" \
  "PassWall2 Simplified Chinese translation payload from the official IPK."

# Keep the user's existing Xray if present; otherwise download the pinned ARM64 binary.
XRAY_BIN_DIR="$OPENWRT_DIR/files/usr/bin"
XRAY_BIN="$XRAY_BIN_DIR/xray"
if [[ -s "$XRAY_BIN" ]]; then
  chmod 0755 "$XRAY_BIN"
  log "检测到现有 Xray 二进制，保留不覆盖：$XRAY_BIN"
else
  XRAY_TMP="$WORK_DIR/xray"
  rm -rf "$XRAY_TMP"
  mkdir -p "$XRAY_TMP/unpacked" "$XRAY_BIN_DIR"
  log "下载 Xray-core ${XRAY_VERSION} ARM64 ..."
  curl --fail --location --retry 3 --retry-all-errors --retry-delay 2 \
    --connect-timeout 20 --max-time 300 "$XRAY_URL" -o "$XRAY_TMP/xray.zip" ||
      die "Xray 下载失败：$XRAY_URL"
  unzip -oq "$XRAY_TMP/xray.zip" -d "$XRAY_TMP/unpacked" ||
      die "Xray ZIP 解压失败，检查下载链接或文件格式。"
  XRAY_SOURCE="$(find "$XRAY_TMP/unpacked" -type f -name xray -print -quit)"
  [[ -n "$XRAY_SOURCE" && -s "$XRAY_SOURCE" ]] || die "Xray ZIP 中没有找到 xray 可执行文件。"
  install -m 0755 "$XRAY_SOURCE" "$XRAY_BIN"
  log "已安装 Xray 二进制：$XRAY_BIN"
fi

# Select wrapper packages in the final firmware configuration.
CONFIG_FILE="${CONFIG_FILE:-$OPENWRT_DIR/.config}"
mkdir -p "$(dirname "$CONFIG_FILE")"
touch "$CONFIG_FILE"
set_config() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
  else
    sed -i "/^# ${key} is not set$/d" "$CONFIG_FILE"
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}

set_config CONFIG_PACKAGE_luci-app-passwall-prebuilt y
set_config CONFIG_PACKAGE_luci-i18n-passwall-zh-cn-prebuilt y
set_config CONFIG_PACKAGE_luci-app-passwall2-prebuilt y
set_config CONFIG_PACKAGE_luci-i18n-passwall2-zh-cn-prebuilt y

log "PassWall、PassWall2、中文 LuCI 包和 Xray overlay 已集成。"
log "未添加 PassWall feeds，因此不会主动编译 passwall-packages/geoview。"
log "注意：Xray 以 files/usr/bin/xray 二进制形式提供；未单独打包 geoview，相关地理信息功能可能不可用。"
log "在源码根目录继续执行：make defconfig"
log "然后确认 .config 中四个 CONFIG_PACKAGE_*_prebuilt=y 项仍然存在。"
log "若 make defconfig 删除这些配置，需检查对应 wrapper Makefile 是否被源码包索引识别。"
