#!/usr/bin/env bash
# 测试OK 2026-10-21
# Integrate luci-app-turboacc (chenmozhijin fork, with SFE / FullCone / BBR / Flow Offload)
# into an OpenWrt/ImmortalWrt source tree, without relying on `git clone` at build time.
#
# Run from the workflow AFTER the OpenWrt source tree has been prepared (feeds updated),
# BEFORE `make defconfig`. Mirrors the style/contract of diy-passwall.sh.
#
# Options (env vars):
#   OPENWRT_DIR       path to OpenWrt source root (default: $PWD)
#   TURBOACC_REPO     turboacc GitHub repo      (default: chenmozhijin/turboacc)
#   TURBOACC_BRANCH   luci-app-turboacc branch  (default: luci)
#   TURBOACC_PKG_BR   turboacc package branch   (default: package)  [provides nft-fullcone/shortcut-fe/firewall4 patches]
#   TURBOACC_NO_SFE   set to 1 to skip SFE (shortcut-fe) related patches & package
set -Eeuo pipefail

TURBOACC_REPO="${TURBOACC_REPO:-chenmozhijin/turboacc}"
TURBOACC_BRANCH="${TURBOACC_BRANCH:-luci}"
TURBOACC_PKG_BR="${TURBOACC_PKG_BR:-package}"
TURBOACC_NO_SFE="${TURBOACC_NO_SFE:-0}"

LUCI_TARBALL_URL="https://github.com/${TURBOACC_REPO}/archive/refs/heads/${TURBOACC_BRANCH}.tar.gz"
PKG_TARBALL_URL="https://github.com/${TURBOACC_REPO}/archive/refs/heads/${TURBOACC_PKG_BR}.tar.gz"

# ---------- environment checks ----------
OPENWRT_DIR="${OPENWRT_DIR:-$PWD}"
if [[ ! -f "$OPENWRT_DIR/include/toplevel.mk" || ! -d "$OPENWRT_DIR/package" ]]; then
  echo "[TurboACC] ERROR: $OPENWRT_DIR is not an OpenWrt source root." >&2
  echo "[TurboACC] Set OPENWRT_DIR=/path/to/openwrt before running this script." >&2
  exit 1
fi

for cmd in curl tar awk sed grep tr find file head sort mktemp cp rm mkdir cat; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[TurboACC] Missing command: $cmd" >&2; exit 1; }
done

# ---------- kernel version detection ----------
detect_kernel_versions() {
  local vs=""
  if [[ -d "$OPENWRT_DIR/include" ]]; then
    vs="$(find "$OPENWRT_DIR/include" -maxdepth 1 -name 'kernel-[0-9]*' -printf '%f\n' 2>/dev/null | sed 's/^kernel-//' | sort -uV | tr '\n' ' ')"
  fi
  if [[ -z "${vs// }" && -d "$OPENWRT_DIR/target/linux/generic" ]]; then
    vs="$(find "$OPENWRT_DIR/target/linux/generic" -maxdepth 1 -name 'kernel-[0-9]*' -printf '%f\n' 2>/dev/null | sed 's/^kernel-//' | sort -uV | tr '\n' ' ')"
  fi
  echo "${vs% }"
}

KERNEL_VERSIONS="$(detect_kernel_versions)"
if [[ -z "${KERNEL_VERSIONS// }" ]]; then
  echo "[TurboACC] ERROR: unable to detect kernel version from $OPENWRT_DIR" >&2
  exit 1
fi
echo "[TurboACC] Detected kernel versions: ${KERNEL_VERSIONS}; NO_SFE=${TURBOACC_NO_SFE}"

SUPPORTED_KVERS_952_A="6.18 6.12 6.6 6.1 5.15"   # uses 952-add-net-conntrack-events-support-multiple-registrant.patch
SUPPORTED_KVERS_952_B="5.10"                      # uses 952-net-conntrack-events-support-multiple-registrant.patch

check_supported() {
  local kv="$1"
  for s in $SUPPORTED_KVERS_952_A $SUPPORTED_KVERS_952_B; do
    [[ "$kv" == "$s" ]] && return 0
  done
  return 1
}

for kv in $KERNEL_VERSIONS; do
  if ! check_supported "$kv"; then
    echo "[TurboACC] ERROR: unsupported kernel version: $kv" >&2
    echo "[TurboACC] Supported: $SUPPORTED_KVERS_952_A $SUPPORTED_KVERS_952_B" >&2
    exit 1
  fi
done

# ---------- workspace ----------
WORK_DIR="$OPENWRT_DIR/tmp/turboacc-prebuilt"
PKG_BASE="$OPENWRT_DIR/package/turboacc"
rm -rf "$WORK_DIR" "$PKG_BASE"
mkdir -p "$WORK_DIR" "$PKG_BASE"

# ---------- download helpers ----------
download_tarball() {
  local url="$1" out="$2" http_code
  echo "[TurboACC] Downloading $(basename "$out") from $url"
  http_code="$(curl --fail --location --retry 3 --retry-all-errors --retry-delay 2 \
       --connect-timeout 20 --max-time 300 \
       -A 'Mozilla/5.0 OpenWrt-TurboACC-build' \
       -H 'Accept: application/gzip' \
       -w '%{http_code}' -o "$out" "$url")" || {
    echo "[TurboACC] ERROR: download failed: $url" >&2
    exit 1
  }
  [[ "$http_code" == "200" && -s "$out" ]] || {
    echo "[TurboACC] ERROR: HTTP $http_code or empty file: $url" >&2
    exit 1
  }
  if ! gzip -t "$out" >/dev/null 2>&1 || ! tar -tzf "$out" >/dev/null 2>&1; then
    echo "[TurboACC] ERROR: downloaded file is not a valid tar.gz archive." >&2
    echo "[TurboACC] URL: $url" >&2
    echo "[TurboACC] Size: $(wc -c < "$out") bytes" >&2
    echo "[TurboACC] First 160 bytes:" >&2
    head -c 160 "$out" | tr '\r' ' ' >&2 || true
    echo >&2
    exit 1
  fi
  echo "[TurboACC] OK: $(basename "$out") ($(wc -c < "$out") bytes)"
}

LUCI_TARBALL="$WORK_DIR/turboacc-luci.tar.gz"
PKG_TARBALL="$WORK_DIR/turboacc-pkg.tar.gz"
download_tarball "$LUCI_TARBALL_URL" "$LUCI_TARBALL"
download_tarball "$PKG_TARBALL_URL"  "$PKG_TARBALL"

# ---------- extract ----------
LUCI_EXTRACT="$WORK_DIR/luci-extracted"
PKG_EXTRACT="$WORK_DIR/pkg-extracted"
mkdir -p "$LUCI_EXTRACT" "$PKG_EXTRACT"
tar -xzf "$LUCI_TARBALL" -C "$LUCI_EXTRACT"
tar -xzf "$PKG_TARBALL"  -C "$PKG_EXTRACT"

# GitHub archives extract to <repo>-<branch>/; locate it.
LUCI_ROOT="$(find "$LUCI_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n1)"
PKG_ROOT="$(find  "$PKG_EXTRACT"  -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -n "$LUCI_ROOT" && -d "$LUCI_ROOT/luci-app-turboacc" ]] || {
  echo "[TurboACC] ERROR: luci-app-turboacc not found in luci tarball" >&2; exit 1;
}
[[ -n "$PKG_ROOT" ]] || { echo "[TurboACC] ERROR: failed to locate package tree root" >&2; exit 1; }

# ---------- stage packages ----------
cp -r "$LUCI_ROOT/luci-app-turboacc"  "$PKG_BASE/luci-app-turboacc"
if [[ -d "$PKG_ROOT/nft-fullcone" ]]; then
  cp -r "$PKG_ROOT/nft-fullcone" "$PKG_BASE/nft-fullcone"
fi
if [[ "$TURBOACC_NO_SFE" != "1" && -d "$PKG_ROOT/shortcut-fe" ]]; then
  cp -r "$PKG_ROOT/shortcut-fe" "$PKG_BASE/shortcut-fe"
fi

# ---------- replace firewall4 / libnftnl / nftables with patched versions ----------
# Strategy: if tarball ships version-suffixed dirs (e.g. firewall4-2024xxxx), match against
# the PKG_SOURCE_VERSION / PKG_VERSION currently declared in the source tree; else fall back
# to the FIREWALL4_VERSION / NFTABLES_VERSION / LIBNFTNL_VERSION pinned in the tarball's `version` file.
get_makefile_var() {
  local path="$1" var="$2"
  [[ -f "$path" ]] || { echo ""; return 0; }
  grep -E "^${var}:=" "$path" | head -n1 | cut -d= -f2- | tr -d '[:space:]'
}

FIREWALL4_SRC_VER="$(get_makefile_var "$OPENWRT_DIR/package/network/config/firewall4/Makefile" PKG_SOURCE_VERSION)"
NFTABLES_VER="$(get_makefile_var    "$OPENWRT_DIR/package/network/utils/nftables/Makefile" PKG_VERSION)"
LIBNFTNL_VER="$(get_makefile_var    "$OPENWRT_DIR/package/libs/libnftnl/Makefile"     PKG_VERSION)"

pick_ver_dir() {
  local name="$1" cur_ver="$2" ver_file_key="$3"
  local exact="" latest="" fallback=""
  if [[ -d "$PKG_ROOT/${name}-${cur_ver}/${name}" ]]; then
    echo "$PKG_ROOT/${name}-${cur_ver}/${name}"
    return 0
  fi
  # fallback to version pinned in tarball's `version` file
  if [[ -f "$PKG_ROOT/version" ]]; then
    fallback="$(grep -E "^${ver_file_key}=" "$PKG_ROOT/version" | head -n1 | cut -d= -f2- | tr -d '[:space:]')"
    if [[ -n "$fallback" && -d "$PKG_ROOT/${name}-${fallback}/${name}" ]]; then
      echo "$PKG_ROOT/${name}-${fallback}/${name}"
      return 0
    fi
  fi
  # last resort: pick the lexicographically-latest version dir
  latest="$(find "$PKG_ROOT" -maxdepth 1 -type d -name "${name}-*" | sort -V | tail -n1)"
  if [[ -n "$latest" && -d "$latest/$name" ]]; then
    echo "$latest/$name"
    return 0
  fi
  return 1
}

FW4_DIR="$(pick_ver_dir firewall4 "$FIREWALL4_SRC_VER" FIREWALL4_VERSION || true)"
NFT_DIR="$(pick_ver_dir nftables  "$NFTABLES_VER"     NFTABLES_VERSION  || true)"
LNL_DIR="$(pick_ver_dir libnftnl  "$LIBNFTNL_VER"     LIBNFTNL_VERSION  || true)"

if [[ -z "$FW4_DIR" || -z "$NFT_DIR" || -z "$LNL_DIR" ]]; then
  echo "[TurboACC] ERROR: cannot locate patched firewall4/libnftnl/nftables in package tarball." >&2
  echo "[TurboACC] firewall4 dir: ${FW4_DIR:-<missing>}" >&2
  echo "[TurboACC] nftables  dir: ${NFT_DIR:-<missing>}" >&2
  echo "[TurboACC] libnftnl  dir: ${LNL_DIR:-<missing>}" >&2
  exit 1
fi

echo "[TurboACC] Replacing firewall4 -> $FW4_DIR"
echo "[TurboACC] Replacing nftables  -> $NFT_DIR"
echo "[TurboACC] Replacing libnftnl  -> $LNL_DIR"
rm -rf "$OPENWRT_DIR/package/network/config/firewall4" \
       "$OPENWRT_DIR/package/network/utils/nftables"  \
       "$OPENWRT_DIR/package/libs/libnftnl"
cp -RT "$FW4_DIR" "$OPENWRT_DIR/package/network/config/firewall4"
cp -RT "$NFT_DIR" "$OPENWRT_DIR/package/network/utils/nftables"
cp -RT "$LNL_DIR" "$OPENWRT_DIR/package/libs/libnftnl"

# ---------- kernel patches ----------
apply_kver() {
  local kv="$1"
  local patch_952_name patch_952_src
  local hack_dir="$OPENWRT_DIR/target/linux/generic/hack-$kv"
  local pend_dir="$OPENWRT_DIR/target/linux/generic/pending-$kv"
  local cfg_file="$OPENWRT_DIR/target/linux/generic/config-$kv"
  mkdir -p "$hack_dir" "$pend_dir"

  case " $SUPPORTED_KVERS_952_A " in
    *" $kv "*) patch_952_name="952-add-net-conntrack-events-support-multiple-registrant.patch" ;;
    *)         patch_952_name="952-net-conntrack-events-support-multiple-registrant.patch" ;;
  esac

  patch_952_src="$PKG_ROOT/hack-$kv/$patch_952_name"
  local patch_953_src="$PKG_ROOT/hack-$kv/953-net-patch-linux-kernel-to-support-shortcut-fe.patch"
  local patch_613_src="$PKG_ROOT/pending-$kv/613-netfilter_optional_tcp_window_check.patch"

  # remove pre-existing copies to avoid duplicate-patch failures
  rm -f "$hack_dir"/952-*.patch "$hack_dir"/953-net-patch-linux-kernel-to-support-shortcut-fe.patch \
        "$pend_dir"/613-netfilter_optional_tcp_window_check.patch

  [[ -f "$patch_952_src" ]] || { echo "[TurboACC] ERROR: missing $patch_952_src" >&2; exit 1; }
  cp -f "$patch_952_src" "$hack_dir/$patch_952_name"
  echo "[TurboACC]   + hack-$kv/$patch_952_name"

  if [[ "$TURBOACC_NO_SFE" != "1" ]]; then
    [[ -f "$patch_953_src" ]] || { echo "[TurboACC] ERROR: missing $patch_953_src" >&2; exit 1; }
    [[ -f "$patch_613_src" ]] || { echo "[TurboACC] ERROR: missing $patch_613_src" >&2; exit 1; }
    cp -f "$patch_953_src" "$hack_dir/953-net-patch-linux-kernel-to-support-shortcut-fe.patch"
    cp -f "$patch_613_src" "$pend_dir/613-netfilter_optional_tcp_window_check.patch"
    echo "[TurboACC]   + hack-$kv/953-net-patch-linux-kernel-to-support-shortcut-fe.patch"
    echo "[TurboACC]   + pending-$kv/613-netfilter_optional_tcp_window_check.patch"
  fi

  # kernel config symbols (left as "not set" so menuconfig/user choice decides)
  touch "$cfg_file"
  if ! grep -q "^CONFIG_NF_CONNTRACK_CHAIN_EVENTS" "$cfg_file"; then
    echo "# CONFIG_NF_CONNTRACK_CHAIN_EVENTS is not set" >> "$cfg_file"
  fi
  if [[ "$TURBOACC_NO_SFE" != "1" ]] && ! grep -q "^CONFIG_SHORTCUT_FE" "$cfg_file"; then
    echo "# CONFIG_SHORTCUT_FE is not set" >> "$cfg_file"
  fi
}

for kv in $KERNEL_VERSIONS; do
  echo "[TurboACC] Applying kernel patches for $kv"
  apply_kver "$kv"
done

# ---------- append .config symbols ----------
CONFIG_FILE="$OPENWRT_DIR/.config"
touch "$CONFIG_FILE"

set_config() {
  local sym="$1"
  sed -i "/^${sym}=y$/d; /^# ${sym} is not set$/d" "$CONFIG_FILE"
  printf '%s=y\n' "$sym" >> "$CONFIG_FILE"
}

set_config CONFIG_PACKAGE_luci-app-turboacc
set_config CONFIG_PACKAGE_nft-fullcone
set_config CONFIG_PACKAGE_kmod-tcp-bbr
if [[ "$TURBOACC_NO_SFE" != "1" ]]; then
  set_config CONFIG_PACKAGE_shortcut-fe
  set_config CONFIG_PACKAGE_kmod-shortcut-fe
  set_config CONFIG_PACKAGE_kmod-shortcut-fe-cm
fi
# nftables offloading chain events are required by fullcone/nft-fullcone
sed -i "/^CONFIG_NF_CONNTRACK_CHAIN_EVENTS=/d; /^# CONFIG_NF_CONNTRACK_CHAIN_EVENTS is not set$/d" "$CONFIG_FILE"
printf 'CONFIG_NF_CONNTRACK_CHAIN_EVENTS=y\n' >> "$CONFIG_FILE"

# ---------- cleanup & report ----------
rm -rf "$WORK_DIR"

echo "[TurboACC] Integrated luci-app-turboacc + nft-fullcone (patches pre-downloaded, no git clone at build time)."
echo "[TurboACC] Kernel versions patched : ${KERNEL_VERSIONS}"
echo "[TurboACC] SFE (shortcut-fe)        : $([[ "$TURBOACC_NO_SFE" == "1" ]] && echo disabled || echo enabled)"
echo "[TurboACC] Patched components       : firewall4, libnftnl, nftables (replaced with turboacc fork)"
echo "[TurboACC] Local package directory  : package/turboacc/"
echo "[TurboACC] Next, run from source root:"
echo "  make defconfig"
echo "  make menuconfig   # verify LuCI -> Applications -> luci-app-turboacc is selected"
echo "  make -j\$(nproc) || make -j1 V=s"
echo "[TurboACC] IMPORTANT: if you don't want SFE, re-run with TURBOACC_NO_SFE=1."
