#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-qlb.sh
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
sed -i 's/ci-llvm=true/ci-llvm=false/g' feeds/packages/lang/rust/Makefile

# add date in output file name
sed -i -e '/^IMG_PREFIX:=/i BUILD_DATE := $(shell date +%Y%m%d)' \
       -e '/^IMG_PREFIX:=/ s/\($(SUBTARGET)\)/\1-$(BUILD_DATE)/' include/image.mk

# set ubi to 122M
# sed -i 's/reg = <0x5c0000 0x7000000>;/reg = <0x5c0000 0x7a40000>;/' target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts

# Enable USB power for Cudy TR3000 by default
#sed -i '/modem-power/,/};/{s/gpio-export,output = <1>;/gpio-export,output = <0>;/}' target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dtsi

# 
#cp target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts
#cp target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dtsi target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dtsi

#sed -i 's|reg = <0x5c0000 0x4000000>;|reg = <0x5c0000 0x1FA40000>;|' target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts

# 
grep -q "define Device/QLB-4Pro" target/linux/mediatek/image/filogic.mk || sed -i '/TARGET_DEVICES += cudy_wbr3000uax-v1-ubootmod/ a \
define Device/QLB-4Pro\
  DEVICE_VENDOR := QLB\
  DEVICE_MODEL := 4Pro\
  DEVICE_VARIANT := v1\
  DEVICE_DTS := mt7981b-QLB-4Pro\
  DEVICE_DTS_DIR := ../dts\
  SUPPORTED_DEVICES += R47\
  BLOCKSIZE := 128k\
  PAGESIZE := 2048\
  IMAGE_SIZE := 113408k\
  KERNEL_IN_UBI := 1\
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata\
  DEVICE_PACKAGES := kmod-usb3 f2fsck mkf2fs\
endef\
TARGET_DEVICES += QLB-4Pro\
' target/linux/mediatek/image/filogic.mk

# 网络配置支持匹配新设备名
#sed -i '/cudy,tr3000-v1|\\/a cudy,tr3000-512mb-v1|\\' target/linux/mediatek/filogic/base-files/etc/board.d/02_network
