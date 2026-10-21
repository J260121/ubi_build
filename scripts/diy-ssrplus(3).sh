#!/usr/bin/env bash
# Integrate official SSR Plus+ v196.19 IPKs as local no-source-build packages.
# Structure follows scripts/diy-passwall.sh. Run after OpenWrt source is prepared,
# before `make defconfig`.
set -Eeuo pipefail

RELEASE="v196.19"
ARCH="aarch64_cortex-a53" # fixed target architecture
OPENWRT_DIR="${OPENWRT_DIR:-$PWD}"

if [[ ! -f "$OPENWRT_DIR/include/toplevel.mk" || ! -d "$OPENWRT_DIR/package" ]]; then
  echo "[SSRPlus-IPK] ERROR: $OPENWRT_DIR is not an OpenWrt source root." >&2
  echo "[SSRPlus-IPK] Set OPENWRT_DIR=/path/to/openwrt." >&2
  exit 1
fi
for cmd in curl jq tar awk sed grep tr find sort head wc file; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[SSRPlus-IPK] Missing command: $cmd" >&2; exit 1; }
done

WORK_DIR="$OPENWRT_DIR/tmp/ssrplus-ipk-$RELEASE"
PKG_ROOT="$OPENWRT_DIR/package"
API_JSON="$WORK_DIR/release.json"
APP_DIR="$PKG_ROOT/ssrplus-prebuilt-luci-app-ssr-plus"
XRAY_DIR="$PKG_ROOT/ssrplus-prebuilt-xray-core"
MIHOMO_DIR="$PKG_ROOT/ssrplus-prebuilt-mihomo"
mkdir -p "$WORK_DIR"
rm -rf "$APP_DIR" "$XRAY_DIR" "$MIHOMO_DIR"

package_format() {
  local f="$1"
  if command -v ar >/dev/null 2>&1 && ar t "$f" >/dev/null 2>&1; then
    echo ar
  elif tar -tf "$f" >/dev/null 2>&1; then
    echo tar
  else
    return 1
  fi
}

echo "[SSRPlus-IPK] Fetching release metadata: $RELEASE"
curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -o "$API_JSON" "https://api.github.com/repos/fw876/helloworld/releases/tags/$RELEASE"

asset_url() {
  local regex="$1" result
  result="$(jq -r --arg re "$regex" '[.assets[] | select(.name | test($re; "i"))] | first | .browser_download_url // empty' "$API_JSON")"
  if [[ -z "$result" || "$result" == null ]]; then
    echo "[SSRPlus-IPK] ERROR: release asset not found: $regex" >&2
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
    -H 'Accept: application/octet-stream' -w '%{http_code}' -o "$output" "$url")" || {
      echo "[SSRPlus-IPK] ERROR: download failed: $url" >&2; exit 1;
    }
  [[ "$code" == 200 && -s "$output" ]] || {
    echo "[SSRPlus-IPK] ERROR: HTTP $code or empty file: $output" >&2; exit 1;
  }
  if ! package_format "$output" >/dev/null; then
    echo "[SSRPlus-IPK] ERROR: response is not a valid IPK/container: $output" >&2
    echo "[SSRPlus-IPK] Size: $(wc -c < "$output") bytes; type: $(file -b "$output" 2>/dev/null || echo unknown)" >&2
    head -c 160 "$output" >&2 || true; echo >&2
    exit 1
  fi
  echo "[SSRPlus-IPK] Validated $(basename "$output") ($(wc -c < "$output") bytes)"
}

unpack_outer() {
  local ipk="$1" dest="$2" fmt
  rm -rf "$dest"; mkdir -p "$dest"
  fmt="$(package_format "$ipk")" || { echo "[SSRPlus-IPK] ERROR: invalid container $ipk" >&2; exit 1; }
  case "$fmt" in
    ar) (cd "$dest" && ar x "$ipk") ;;
    tar) tar -xf "$ipk" -C "$dest" ;;
  esac
}

extract_payload() {
  local archive="$1" dest="$2"
  case "$archive" in
    *.tar|*.tar.gz|*.tgz|*.tar.xz|*.tar.zst|*.tar.bz2)
      tar -xf "$archive" -C "$dest" ;;
    *) echo "[SSRPlus-IPK] ERROR: unsupported archive: $archive" >&2; exit 1 ;;
  esac
}

read_dependencies() {
  local ipk="$1" tmp="$2" control_file control deps
  unpack_outer "$ipk" "$tmp"
  control_file="$(find "$tmp" -maxdepth 1 -type f -name 'control.tar.*' -print -quit)"
  [[ -n "$control_file" ]] || { echo ""; return 0; }
  local cdir="$tmp/control-data"
  mkdir -p "$cdir"
  tar -xf "$control_file" -C "$cdir"
  control="$cdir/control"
  [[ -f "$control" ]] || control="$cdir/./control"
  [[ -f "$control" ]] || { echo ""; return 0; }
  deps="$(awk 'BEGIN{IGNORECASE=1} /^Depends:[[:space:]]*/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$control" \
    | tr ',' '\n' \
    | sed -E 's/[[:space:]]*\([^)]*\)//g; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -Ev '^(|libc|kernel|xray-core|mihomo)$' || true)"
  printf '%s\n' "$deps" | sort -u | sed '/^$/d; s/^/+/' | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

wrap_ipk() {
  local ipk="$1" wrapper_name="$2" pkgarch="$3" target_dir="$4"
  local outer="$WORK_DIR/${wrapper_name}-outer" payload="$WORK_DIR/${wrapper_name}-payload"
  local cdir="$WORK_DIR/${wrapper_name}-control" control_file data_file control original_pkg version pkg_version pkg_release depends
  rm -rf "$outer" "$payload" "$cdir"
  mkdir -p "$outer" "$payload" "$cdir"
  unpack_outer "$ipk" "$outer"
  control_file="$(find "$outer" -maxdepth 1 -type f -name 'control.tar.*' -print -quit)"
  data_file="$(find "$outer" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)"
  [[ -n "$control_file" && -n "$data_file" ]] || {
    echo "[SSRPlus-IPK] ERROR: missing control/data archive in $ipk" >&2; exit 1;
  }
  extract_payload "$control_file" "$cdir"
  control="$cdir/control"
  [[ -f "$control" ]] || control="$cdir/./control"
  [[ -f "$control" ]] || { echo "[SSRPlus-IPK] ERROR: missing control metadata in $ipk" >&2; exit 1; }
  original_pkg="$(awk -F': *' 'tolower($1)=="package" {print $2; exit}' "$control")"
  version="$(awk -F': *' 'tolower($1)=="version" {print $2; exit}' "$control")"
  [[ -n "$original_pkg" && -n "$version" ]] || { echo "[SSRPlus-IPK] ERROR: missing Package/Version in $ipk" >&2; exit 1; }
  # Convert OpenWrt control version such as 196-r19 / 26.9.30-r5 into
  # PKG_VERSION and PKG_RELEASE separately, avoiding a duplicated release suffix.
  if [[ "$version" =~ ^(.+)-r([0-9]+)$ ]]; then
    pkg_version="${BASH_REMATCH[1]}"
    pkg_release="${BASH_REMATCH[2]}"
  else
    pkg_version="$version"
    pkg_release=1
  fi
  extract_payload "$data_file" "$payload"
  mkdir -p "$target_dir/files"
  cp -a "$payload/." "$target_dir/files/"

  depends="$(read_dependencies "$ipk" "$WORK_DIR/${wrapper_name}-deps" | sed \
    -e 's/\(^\|[[:space:]]\)+xray-core\([[:space:]]\|$\)/\1+ssrplus-prebuilt-xray-core\2/g' \
    -e 's/\(^\|[[:space:]]\)+mihomo\([[:space:]]\|$\)/\1+ssrplus-prebuilt-mihomo\2/g')"
  # Keep the LuCI package connected to its local core wrappers.
  if [[ "$wrapper_name" == "ssrplus-prebuilt-luci-app-ssr-plus" ]]; then
    depends="${depends:+$depends }+ssrplus-prebuilt-xray-core +ssrplus-prebuilt-mihomo"
  fi

  local category="Network"
  [[ "$wrapper_name" == "ssrplus-prebuilt-luci-app-ssr-plus" ]] && category="LuCI"

  cat > "$target_dir/Makefile" <<MAKEFILE
include \$(TOPDIR)/rules.mk

PKG_NAME:=${wrapper_name}
PKG_VERSION:=${pkg_version}
PKG_RELEASE:=${pkg_release}
PKGARCH:=${pkgarch}

include \$(INCLUDE_DIR)/package.mk

define Package/${wrapper_name}
  SECTION:=net
  CATEGORY:=${category}
  TITLE:=${original_pkg} (prebuilt ${RELEASE} payload)
  DEPENDS:=${depends}
endef

define Package/${wrapper_name}/description
  Official ${original_pkg} payload from helloworld ${RELEASE}; no source compilation.
endef

define Build/Compile
endef

define Package/${wrapper_name}/install
	\$(INSTALL_DIR) \$(1)
	\$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,${wrapper_name}))
MAKEFILE
  echo "[SSRPlus-IPK] Prepared $original_pkg $version as $wrapper_name (PKGARCH=$pkgarch)"
}

download_ipk "$APP_URL" "$WORK_DIR/luci-app-ssr-plus.ipk"
download_ipk "$MIHOMO_URL" "$WORK_DIR/mihomo.ipk"
download_ipk "$XRAY_URL" "$WORK_DIR/xray-core.ipk"
wrap_ipk "$WORK_DIR/luci-app-ssr-plus.ipk" "ssrplus-prebuilt-luci-app-ssr-plus" all "$APP_DIR"
wrap_ipk "$WORK_DIR/mihomo.ipk" "ssrplus-prebuilt-mihomo" "$ARCH" "$MIHOMO_DIR"
wrap_ipk "$WORK_DIR/xray-core.ipk" "ssrplus-prebuilt-xray-core" "$ARCH" "$XRAY_DIR"

CONFIG_FILE="$OPENWRT_DIR/.config"
touch "$CONFIG_FILE"
for symbol in CONFIG_PACKAGE_ssrplus-prebuilt-luci-app-ssr-plus CONFIG_PACKAGE_ssrplus-prebuilt-mihomo CONFIG_PACKAGE_ssrplus-prebuilt-xray-core; do
  sed -i "/^${symbol}=y$/d; /^# ${symbol} is not set$/d" "$CONFIG_FILE"
  printf '%s=y\n' "$symbol" >> "$CONFIG_FILE"
done

echo "[SSRPlus-IPK] Integrated official SSR Plus+ payloads; architecture fixed to $ARCH."
echo "[SSRPlus-IPK] Run make defconfig, then verify these symbols remain enabled:"
echo "  CONFIG_PACKAGE_ssrplus-prebuilt-luci-app-ssr-plus=y"
echo "  CONFIG_PACKAGE_ssrplus-prebuilt-mihomo=y"
echo "  CONFIG_PACKAGE_ssrplus-prebuilt-xray-core=y"
echo "[SSRPlus-IPK] Do not also enable helloworld source packages with the same payloads."
