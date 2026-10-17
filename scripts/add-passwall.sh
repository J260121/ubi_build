#!/usr/bin/env bash
# 用法：bash add-passwall.sh [OpenWrt/ImmortalWrt源码根目录]
set -Eeuo pipefail

ROOT="$(cd "${1:-$PWD}" && pwd)"
cd "$ROOT"

[[ -f include/toplevel.mk && -f scripts/feeds ]] || {
  echo "[PassWall][错误] 请在 OpenWrt/ImmortalWrt 源码根目录运行。" >&2
  exit 1
}
command -v git >/dev/null || { echo "[PassWall][错误] 未安装 git。" >&2; exit 1; }

clone_repo() {
  local url="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" pull --ff-only || { echo "[PassWall][错误] 更新失败：$dir" >&2; exit 1; }
  elif [[ ! -e "$dir" ]]; then
    git clone --depth 1 "$url" "$dir" || { echo "[PassWall][错误] 克隆失败：$url" >&2; exit 1; }
  else
    echo "[PassWall][错误] $dir 已存在但不是 Git 仓库，请手动检查。" >&2
    exit 1
  fi
}

echo "[PassWall] 清理重复依赖包..."
for p in xray-core v2ray-geodata sing-box chinadns-ng dns2socks hysteria ipt2socks microsocks naiveproxy shadowsocks-rust shadowsocksr-libev simple-obfs tcping v2ray-plugin xray-plugin geoview shadow-tls; do
  rm -rf -- "feeds/packages/net/$p"
done
rm -rf -- feeds/luci/applications/luci-app-passwall

mkdir -p package
clone_repo https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git package/passwall-packages
clone_repo https://github.com/Openwrt-Passwall/openwrt-passwall.git package/passwall-luci

touch .config
sed -i '/^# CONFIG_PACKAGE_luci-app-passwall is not set$/d; /^CONFIG_PACKAGE_luci-app-passwall=/d' .config
echo 'CONFIG_PACKAGE_luci-app-passwall=y' >> .config

make defconfig
if grep -q '^CONFIG_PACKAGE_luci-app-passwall=y$' .config; then
  echo "[PassWall] 完成：luci-app-passwall 已启用。"
else
  echo "[PassWall][警告] defconfig 未保留 PassWall 配置，请检查依赖和目标平台。" >&2
fi
