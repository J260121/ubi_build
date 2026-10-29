#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: ikuai-q6000
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
WIFI_FILE="./package/mtk/applications/mtwifi-cfg/files/mtwifi.sh"
WRT_SSID="ikq6000-nd"
WRT_WORD="12345678"
if [ -f "$WIFI_FILE" ]; then
	#修改WIFI名称
	sed -i "s/ImmortalWrt/$WRT_SSID/g" $WIFI_FILE
	#修改WIFI加密
	sed -i "s/encryption=.*/encryption='psk2+ccmp'/g" $WIFI_FILE
	#修改WIFI密码
	sed -i "/set wireless.default_\${dev}.encryption='psk2+ccmp'/a \\\t\t\t\t\t\set wireless.default_\${dev}.key='$WRT_WORD'" $WIFI_FILE
fi
# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# add date in output file name
sed -i -e '/^IMG_PREFIX:=/i BUILD_DATE := $(shell date +%Y%m%d)' \
       -e '/^IMG_PREFIX:=/ s/\($(SUBTARGET)\)/\1-$(BUILD_DATE)/' include/image.mk

# 修改板载网口
sed -i '/netis,nx31|\\/a\\'$'\t''ikuai,q6000|\\' target/linux/mediatek/filogic/base-files/etc/board.d/02_network
	
grep -q "define Device/ikuai-q6000-nand" target/linux/mediatek/image/filogic.mk || sed -i '/TARGET_DEVICES += cudy_wbr3000uax-v1-ubootmod/ a \
define Device/ikuai-q6000-nand\
  DEVICE_VENDOR := ikuai\
  DEVICE_MODEL := q6000\
  DEVICE_VARIANT := nand\
  DEVICE_DTS := mt7986a-ikuai-q6000-nand\
  DEVICE_DTS_DIR := ../dts\
  BLOCKSIZE := 128k\
  PAGESIZE := 2048\
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata\
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware automount\
endef\
TARGET_DEVICES += ikuai-q6000-nand\
' target/linux/mediatek/image/filogic.mk
