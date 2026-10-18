# 追加PassWall依赖包源和LuCI界面源
echo 'src-git passwall_packages https://github.com/openwrt-passwall/openwrt-passwall-packages.git;main' >> feeds.conf.default
echo 'src-git passwall_luci https://github.com/xiaorouji/openwrt-passwall.git;main' >> feeds.conf.default

# 自动选中PassWall核心组件
echo "CONFIG_PACKAGE_luci-app-passwall=y" >> .config
echo "CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y" >> .config
echo "CONFIG_PACKAGE_passwall-core=y" >> .config
# 自动包含常用依赖组件
echo "CONFIG_PACKAGE_xray-core=y" >> .config
echo "CONFIG_PACKAGE_v2ray-core=y" >> .config
echo "CONFIG_PACKAGE_shadowsocks-libev-ss-local=y" >> .config
