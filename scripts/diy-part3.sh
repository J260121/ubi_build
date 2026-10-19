# PassWall 官方源
sed -i '1i src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main' feeds.conf.default
sed -i '1i src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main' feeds.conf.default


./scripts/feeds update -a
./scripts/feeds install -a

echo "CONFIG_PACKAGE_luci-app-passwall=y" >> .config
