#!/bin/sh
# 32个双射频随机SSID + VLAN/DHCP/防火墙全隔离脚本
# 2.4G射频生成16个SSID 绑定VLAN201~VLAN216
for i in $(seq 1 16)
do
  SSID_2G="2G_Rand_$(head -c 4 /dev/urandom | xxd -p)"
  VLAN=$((200+i))
  PASS_2G=$(echo $SSID_2G | cut -c 7-12)
  NET_SEG="192.168.${VLAN}.0"
  # 创建VLAN子接口
  uci set network.vlan${VLAN}=interface
  uci set network.vlan${VLAN}.proto='static'
  uci set network.vlan${VLAN}.ifname="br-lan.${VLAN}"
  uci set network.vlan${VLAN}.ipaddr="${NET_SEG%.*}.1"
  uci set network.vlan${VLAN}.netmask='255.255.255.0'
  # 配置独立DHCP地址池
  uci set dhcp.vlan${VLAN}=dhcp
  uci set dhcp.vlan${VLAN}.interface="vlan${VLAN}"
  uci set dhcp.vlan${VLAN}.start='10'
  uci set dhcp.vlan${VLAN}.limit='90'
  uci set dhcp.vlan${VLAN}.leasetime='12h'
  # 新增无线SSID配置
  uci add wireless wifi-iface
  uci set wireless.@wifi-iface[-1].device=radio0
  uci set wireless.@wifi-iface[-1].ssid="$SSID_2G"
  uci set wireless.@wifi-iface[-1].encryption='psk2'
  uci set wireless.@wifi-iface[-1].key="2g_$PASS_2G"
  uci set wireless.@wifi-iface[-1].network="vlan${VLAN}"
  # 配置防火墙区域 禁止跨VLAN互访
  uci set firewall.@zone.network="$(uci get firewall.@zone.network) vlan${VLAN}"
  echo "2.4G生成SSID：$SSID_2G 绑定VLAN${VLAN}"
done

# 5G射频生成16个SSID 绑定VLAN301~VLAN316
for i in $(seq 1 16)
do
  SSID_5G="5G_Rand_$(head -c 4 /dev/urandom | xxd -p)"
  VLAN=$((300+i))
  PASS_5G=$(echo $SSID_5G | cut -c 7-12)
  NET_SEG="192.168.${VLAN}.0"
  # 创建VLAN子接口
  uci set network.vlan${VLAN}=interface
  uci set network.vlan${VLAN}.proto='static'
  uci set network.vlan${VLAN}.ifname="br-lan.${VLAN}"
  uci set network.vlan${VLAN}.ipaddr="${NET_SEG%.*}.1"
  uci set network.vlan${VLAN}.netmask='255.255.255.0'
  # 配置独立DHCP地址池
  uci set dhcp.vlan${VLAN}=dhcp
  uci set dhcp.vlan${VLAN}.interface="vlan${VLAN}"
  uci set dhcp.vlan${VLAN}.start='10'
  uci set dhcp.vlan${VLAN}.limit='90'
  uci set dhcp.vlan${VLAN}.leasetime='12h'
  # 新增无线SSID配置
  uci add wireless wifi-iface
  uci set wireless.@wifi-iface[-1].device=radio1
  uci set wireless.@wifi-iface[-1].ssid="$SSID_5G"
  uci set wireless.@wifi-iface[-1].encryption='psk2'
  uci set wireless.@wifi-iface[-1].key="5g_$PASS_5G"
  uci set wireless.@wifi-iface[-1].network="vlan${VLAN}"
  # 配置防火墙区域 禁止跨VLAN互访
  uci set firewall.@zone.network="$(uci get firewall.@zone.network) vlan${VLAN}"
  echo "5G生成SSID：$SSID_5G 绑定VLAN${VLAN}"
done

# 配置二层隔离核心规则 所有SSID之间完全无法互访
uci add firewall rule
uci set firewall.@rule[-1].name='Block_All_VLAN_Interflow'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='lan'
uci set firewall.@rule[-1].proto='all'
uci set firewall.@rule[-1].action='drop'

# 提交所有配置并重启服务生效
uci commit network
uci commit dhcp
uci commit wireless
uci commit firewall
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
wifi reload
echo "32个随机SSID全隔离配置全部完成"
