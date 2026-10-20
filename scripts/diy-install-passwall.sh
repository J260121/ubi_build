# ===== 集成 PassWall LuCI 界面 =====
set -e

echo "===== 集成 PassWall 软件包 ====="

# 克隆官方 PassWall 软件包库
if [ ! -d package/passwall-packages/.git ]; then
    rm -rf package/passwall-packages
    git clone --depth=1 \
      https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git \
      package/passwall-packages
fi

# 克隆官方 PassWall LuCI 界面
if [ ! -d package/passwall-luci/.git ]; then
    rm -rf package/passwall-luci
    git clone --depth=1 \
      https://github.com/Openwrt-Passwall/openwrt-passwall.git \
      package/passwall-luci
fi

# 检查 LuCI 包定义是否存在
test -f package/passwall-luci/luci-app-passwall/Makefile

# 生成编译配置
./scripts/feeds update -a
./scripts/feeds install -a

# 确保编译 PassWall 界面
grep -q '^CONFIG_PACKAGE_luci-app-passwall=y' .config ||
    echo 'CONFIG_PACKAGE_luci-app-passwall=y' >> .config
