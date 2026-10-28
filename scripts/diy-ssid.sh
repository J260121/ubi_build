#!/bin/bash
# 编译阶段修改 ImmortalWrt 默认 Wi-Fi 名称
set -euo pipefail

SSID_2G="277221866-2.4G"
SSID_5G="277221866-5G"

# 自动定位 OpenWrt 源码目录
OPENWRT_DIR=""
for dir in \
    "${GITHUB_WORKSPACE:-}/openwrt" \
    /workdir/openwrt \
    "$(pwd)/openwrt" \
    "$(pwd)"
do
    if [ -n "$dir" ] && [ -f "$dir/.config" ] && [ -d "$dir/package" ]; then
        OPENWRT_DIR="$dir"
        break
    fi
done

if [ -z "$OPENWRT_DIR" ]; then
    echo "ERROR: 找不到 OpenWrt 源码目录"
    echo "GITHUB_WORKSPACE=${GITHUB_WORKSPACE:-未设置}"
    echo "当前目录=$(pwd)"
    exit 1
fi

echo "OpenWrt 源码目录：$OPENWRT_DIR"

# 查找实际配置文件
CANDIDATES=(
    "$OPENWRT_DIR/package/base-files/files/bin/config_generate"
    "$OPENWRT_DIR/package/kernel/mac80211/files/lib/wifi/mac80211.sh"
    "$OPENWRT_DIR/target/linux/mediatek/base-files/etc/board.d/01_leds"
)

FOUND=0

for file in "${CANDIDATES[@]}"; do
    if [ -f "$file" ]; then
        echo "检查文件：$file"
        grep -nE 'ssid|OpenWrt' "$file" || true
        FOUND=1
    fi
done

if [ "$FOUND" -eq 0 ]; then
    echo "ERROR: 未找到候选配置文件"
    find "$OPENWRT_DIR/package" "$OPENWRT_DIR/target/linux/mediatek" \
        -type f \( -name 'config_generate' -o -name 'mac80211.sh' \) \
        -print 2>/dev/null | head -n 80
    exit 1
fi

echo "请根据上面的实际命中位置确认 SSID 模板，再进行定向修改。"
echo "本次未修改源码，避免误改 MediaTek 专有无线配置。"
