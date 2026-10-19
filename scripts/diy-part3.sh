
#!/bin/bash
# 添加 PassWall
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall.git package/passwall
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git package/passwall-packages

./scripts/feeds update -a
./scripts/feeds install -a

echo "CONFIG_PACKAGE_luci-app-passwall=y" >> .config
