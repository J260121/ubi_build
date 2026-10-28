#!/bin/sh
# 双射频拆分生成32个随机独立SSID 适配ImmortalWrt MT798x 6.6
# 2.4G射频生成16个SSID
for i in {1..16}
do
  SSID_2G="2G_Rand_$(head -c 4 /dev/urandom | xxd -p)"
  VLAN=$((200+i))
  uci add wireless wifi-iface
  uci set wireless.@wifi-iface[-1].device=radio0
  uci set wireless.@wifi-iface[-1].ssid="$SSID_2G"
  uci set wireless.@wifi-iface[-1].encryption=psk2
  uci set wireless.@wifi-iface[-1].key="2g_${SSID_2G: -6}"
  uci set wireless.@wifi-iface[-1].network="vlan${VLAN}"
  echo "2.4G频段生成SSID：$SSID_2G"
done

# 5G射频生成16个SSID
for i in {1..16}
do
  SSID_5G="5G_Rand_$(head -c 4 /dev/urandom | xxd -p)"
  VLAN=$((300+i))
  uci add wireless wifi-iface
  uci set wireless.@wifi-iface[-1].device=radio1
  uci set wireless.@wifi-iface[-1].ssid="$SSID_5G"
  uci set wireless.@wifi-iface[-1].encryption=psk2
  uci set wireless.@wifi-iface[-1].key="5g_${SSID_5G: -6}"
  uci set wireless.@wifi-iface[-1].network="vlan${VLAN}"
  echo "5G频段生成SSID：$SSID_5G"
done

uci commit wireless && wifi reload
echo "32个双射频拆分随机SSID全部配置完成"
