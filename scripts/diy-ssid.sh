#!/bin/bash
# SPDX-License-Identifier: MIT
WIFI_FILE="./package/mtk/applications/mtwifi-cfg/files/mtwifi.sh"
WRT_SSID="sfsk"
WRT_WORD="12345678"
if [ -f "$WIFI_FILE" ]; then
	#修改WIFI名称
	sed -i "s/ImmortalWrt/$WRT_SSID/g" $WIFI_FILE
	#修改WIFI加密
	sed -i "s/encryption=.*/encryption='psk2+ccmp'/g" $WIFI_FILE
	#修改WIFI密码
	sed -i "/set wireless.default_\${dev}.encryption='psk2+ccmp'/a \\\t\t\t\t\t\set wireless.default_\${dev}.key='$WRT_WORD'" $WIFI_FILE
fi
