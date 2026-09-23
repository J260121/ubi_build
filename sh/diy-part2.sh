#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# 临时解决Rust问题
#sed -i 's/ci-llvm=true/ci-llvm=false/g' feeds/packages/lang/rust/Makefile

# add date in output file name
sed -i '/^IMG_PREFIX:=/i BUILD_DATE := $(shell date +%Y%m%d)' include/image.mk 
sed -i 's/^IMG_PREFIX:=.*/IMG_PREFIX:=\\$(BUILD_DATE)-&/' include/image.mk

# set ubi to 122M
# sed -i 's/reg = <0x5c0000 0x7000000>;/reg = <0x5c0000 0x7a40000>;/' target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts

# Enable USB power for Cudy TR3000 by default
#sed -i '/modem-power/,/};/{s/gpio-export,output = <1>;/gpio-export,output = <0>;/}' target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dtsi

# 
#cp target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts
#cp target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dtsi target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dtsi

#sed -i 's|reg = <0x5c0000 0x4000000>;|reg = <0x5c0000 0x1FA40000>;|' target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts

# 
#sed -i -e '/partition@5c0000 {/,/^[ \t]*};/ {
#    s|compatible = "linux,ubi";|reg = <0x5c0000 0x1FA40000>;\n\t\tcompatible = "linux,ubi";|
#}' target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dtsi

# 

# ==================================================
# 添加 QLB-4Pro 设备定义
# ==================================================

FILOGIC_MK="target/linux/mediatek/image/filogic.mk"

if [ ! -f "$FILOGIC_MK" ]; then
    echo "错误：找不到 $FILOGIC_MK"
    exit 1
fi

if grep -q 'define Device/QLB-4Pro' "$FILOGIC_MK"; then
    echo "QLB-4Pro 设备定义已存在，跳过"
else
    echo "正在添加 QLB-4Pro 设备定义..."

    awk '
    /TARGET_DEVICES += cudy_wbr3000uax-v1-ubootmod/ {
        print
        print ""
        print "define Device/QLB-4Pro"
        print "  DEVICE_VENDOR := QLB4Pro"
        print "  DEVICE_MODEL := 4Pro"
        print "  DEVICE_VARIANT := (MTK layout)"
        print "  DEVICE_DTS := mt7981-QLB-4pro"
        print "  DEVICE_DTS_DIR := ../dts"
        print "  DEVICE_PACKAGES := kmod-usb3 f2fsck mkf2fs"
        print "  BLOCKSIZE := 128k"
        print "  PAGESIZE := 2048"
        print "  IMAGE_SIZE := 113408k"
        print "  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata"
        print "endef"
        print "TARGET_DEVICES += QLB-4Pro"
        next
    }
    { print }
    ' "$FILOGIC_MK" > "$FILOGIC_MK.tmp"

    mv "$FILOGIC_MK.tmp" "$FILOGIC_MK"

    echo "QLB-4Pro 设备定义添加成功"
fi

# 网络配置支持匹配新设备名
#sed -i '/cudy,tr3000-v1|\\/a cudy,tr3000-512mb-v1|\\' target/linux/mediatek/filogic/base-files/etc/board.d/02_network
