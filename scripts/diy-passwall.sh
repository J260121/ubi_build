# ==== 1. 修复源重复问题：PassWall源置顶（仅添加一次，覆盖官方旧版geoview依赖） ====
# 置顶插入PassWall专用源（一次即可，解决geoview版本过旧编译失败）
sed -i '1i src-git passwall_packages https://github.com/openwrt-passwall/openwrt-passwall-packages.git;main' feeds.conf.default

# ==== 2. 自动补全核心配置（补全缺的关键依赖，避免编译报错） ====
cat > .config << EOF
CONFIG_TARGET_mediatek_filogic_DEVICE_cudy_tr3000-v1=y
# PassWall核心
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y
CONFIG_PACKAGE_passwall-core=y
# 修复你之前遇到的geoview编译失败+常用代理组件
CONFIG_PACKAGE_geoview=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_v2ray-core=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_hysteria2=y
EOF
