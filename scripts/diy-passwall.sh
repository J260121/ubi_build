# ==== 1. 修复源重复问题：PassWall源置顶（仅添加一次，覆盖官方旧版geoview依赖） ====
# 置顶插入PassWall专用源（一次即可，解决geoview版本过旧编译失败）
echo 'src-git passwall_packages https://github.com/openwrt-passwall/openwrt-passwall.git;main' >> feeds.conf.default
# ==== 2. 自动补全核心配置（补全缺的关键依赖，避免编译报错） ====
cat > .config << EOF
# PassWall核心
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y
CONFIG_PACKAGE_passwall-core=y
CONFIG_PACKAGE_geoview=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_v2ray-core=y
CONFIG_PACKAGE_trojan-plus=y
CONFIG_PACKAGE_hysteria=y
CONFIG_PACKAGE_hysteria2=y
CONFIG_PACKAGE_shadowsocks-libev-config=y
CONFIG_PACKAGE_shadowsocks-libev-ss-local=y
CONFIG_PACKAGE_shadowsocks-libev-ss-redir=y
CONFIG_PACKAGE_shadowsocksr-libev-ssr-local=y
CONFIG_PACKAGE_shadowsocksr-libev-ssr-redir=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_dns2tcp=y
CONFIG_PACKAGE_ipt2socks=y
CONFIG_PACKAGE_simple-obfs=y
CONFIG_PACKAGE_tcping=y
CONFIG_PACKAGE_geosite=y
CONFIG_PACKAGE_geoip=y
CONFIG_PACKAGE_ca-certificates=y
CONFIG_PACKAGE_libcap=y
CONFIG_PACKAGE_libcap-bin=y
EOF
