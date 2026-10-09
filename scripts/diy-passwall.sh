#!/bin/bash
# ============================================================
#  PassWall 集成脚本 —— 适配 J260121/ubi_build 云编译流程
#
#  使用方法：
#    1. 把本文件放到仓库的 scripts/ 目录下，命名为 passwall.sh
#    2. 在 GitHub Actions 的 "plugin_scripts" 参数里填入 passwall.sh
#       （如果同时要跑多个脚本，用英文逗号分隔，例如 passwall.sh,xxx.sh）
#    3. 触发编译即可。脚本在「加载设备 Config 之后、make defconfig 之前」执行。
#
#  适配环境：
#    - ImmortalWrt 24.10 (openwrt-24.10-6.6, mt798x/mt7986)
#    - Cudy TR3000 (128/256/512M) / QLB-4Pro / ikuai-q6000-nand
# ============================================================

set -euo pipefail

# ------------------------------------------------------------------
# 0. 基础检查
# ------------------------------------------------------------------
if [ ! -f "feeds.conf.default" ] || [ ! -d "package" ]; then
    echo "[PassWall] ERROR: 请在 OpenWrt/ImmortalWrt 源码根目录下执行本脚本"
    exit 1
fi

echo "========================================"
echo "[PassWall] 开始集成 PassWall"
echo "========================================"

# ------------------------------------------------------------------
# 1. 清理旧版本/冲突包
#    ImmortalWrt 24.10 自带 feeds 里可能包含旧版 xray-core / sing-box /
#    chinadns-ng / dns2socks / geoview 等，PassWall 自带的 packages 仓库
#    里是专门适配过的版本，不清理会导致 feeds 版本冲突、编译失败或运行异常。
# ------------------------------------------------------------------
echo "[PassWall] 清理可能冲突的旧包..."

# 清理系统 feeds 中已有的同名包
rm -rf feeds/packages/net/xray-core
rm -rf feeds/packages/net/sing-box
rm -rf feeds/packages/net/chinadns-ng
rm -rf feeds/packages/net/dns2socks
rm -rf feeds/packages/net/tcping
rm -rf feeds/packages/net/naiveproxy
rm -rf feeds/packages/net/brook
rm -rf feeds/packages/net/hysteria
rm -rf feeds/packages/net/hysteria2
rm -rf feeds/packages/net/tuic-client
rm -rf feeds/packages/net/shadowsocks-rust
rm -rf feeds/packages/net/shadowsocksr-libev
rm -rf feeds/packages/net/simple-obfs
rm -rf feeds/packages/net/v2ray-core
rm -rf feeds/packages/net/v2ray-geodata
rm -rf feeds/packages/net/v2ray-plugin
rm -rf feeds/packages/net/xray-plugin
rm -rf feeds/packages/net/geoview

# 清理 luci feeds 中可能存在的旧版 passwall
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf package/feeds/luci/luci-app-passwall
rm -rf package/feeds/packages/xray-core
rm -rf package/feeds/packages/sing-box
rm -rf package/feeds/packages/chinadns-ng
rm -rf package/feeds/packages/geoview

# 清理之前 DIY 可能残留的 passwall 目录
rm -rf package/passwall
rm -rf package/passwall-packages
rm -rf package/luci-app-passwall

echo "[PassWall] 旧包清理完成"

# ------------------------------------------------------------------
# 2. 克隆 PassWall 官方源码到 package 目录
#    使用 xiaorouji 官方仓库，--depth=1 浅克隆节省 Actions 时间
#    - openwrt-passwall-packages : PassWall 依赖的所有代理核心/工具
#    - openwrt-passwall          : LuCI 界面本体
# ------------------------------------------------------------------
PASSWALL_PKG_REPO="https://github.com/xiaorouji/openwrt-passwall-packages.git"
PASSWALL_LUCI_REPO="https://github.com/xiaorouji/openwrt-passwall.git"

echo "[PassWall] 克隆 passwall-packages ..."
git clone --depth=1 "$PASSWALL_PKG_REPO" package/passwall-packages

echo "[PassWall] 克隆 luci-app-passwall ..."
git clone --depth=1 "$PASSWALL_LUCI_REPO" package/passwall

echo "[PassWall] 源码克隆完成"
echo "[PassWall] package/passwall-packages 列表:"
ls -1 package/passwall-packages | head -30
echo "[PassWall] package/passwall 列表:"
ls -1 package/passwall | head -20

# ------------------------------------------------------------------
# 3. 更新 feeds 索引，让编译系统识别新加的包
#    这里只 install，不 update（update 会重新拉 feeds，可能把刚清理的
#    冲突包又拉回来）。只对新加入 package/ 的包做 install 即可。
# ------------------------------------------------------------------
echo "[PassWall] 更新 feeds 索引..."

./scripts/feeds update -i
./scripts/feeds install -a -f -p passwall-packages 2>/dev/null || true
./scripts/feeds install -a -f -p passwall 2>/dev/null || true
./scripts/feeds install -a

echo "[PassWall] feeds 更新完成"

# ------------------------------------------------------------------
# 4. 追加 .config 选项，确保 PassWall 及核心组件被选中编译
#    此时设备专用 .config 已经由上一步 Load Device Config 拷贝好，
#    我们只需要把 PassWall 相关的选项追加进去；后面的 make defconfig
#    会自动解析依赖并补全 CONFIG_ 项。
# ------------------------------------------------------------------
echo "[PassWall] 追加 PassWall 配置到 .config ..."

cat >> .config <<'EOF'

# ===== PassWall 主程序 =====
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y

# ===== 代理核心（推荐同时编译 xray-core + sing-box，覆盖全部协议）=====
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_sing-box=y

# ===== PassWall 必需的基础工具 =====
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_tcping=y
CONFIG_PACKAGE_geoview=y

# ===== iptables/nftables 分流支持（24.10 默认 nftables） =====
CONFIG_PACKAGE_ipt2socks=y
CONFIG_PACKAGE_iptables-nft=y
CONFIG_PACKAGE_nftables-json=y

# ===== 传输插件（按需启用，不编译不会影响其他功能，但保留更灵活） =====
CONFIG_PACKAGE_shadowsocks-rust=y
CONFIG_PACKAGE_shadowsocksr-libev-ssr-local=y
CONFIG_PACKAGE_shadowsocksr-libev-ssr-redir=y
CONFIG_PACKAGE_shadowsocksr-libev-ssr-check=y
CONFIG_PACKAGE_simple-obfs=y
CONFIG_PACKAGE_v2ray-plugin=y
CONFIG_PACKAGE_xray-plugin=y
CONFIG_PACKAGE_tuic-client=y
CONFIG_PACKAGE_hysteria=y
CONFIG_PACKAGE_hysteria2=y
CONFIG_PACKAGE_naiveproxy=y

# ===== GeoIP / GeoSite 数据（PassWall 分流规则依赖）=====
CONFIG_PACKAGE_v2ray-geoip=y
CONFIG_PACKAGE_v2ray-geosite=y

# ===== 关闭官方 feeds 中可能存在的重复包，避免冲突 =====
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_NONE is not set
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust=y
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=y
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Trojan_Plus=y
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Brook=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Haproxy=y

EOF

# 去掉可能冲突的默认 m 选项，确保 defconfig 选中=y 的包
# （有些 config 里默认 =m 会导致 y 被忽略）
sed -i 's/^CONFIG_PACKAGE_xray-core=m/CONFIG_PACKAGE_xray-core=y/' .config
sed -i 's/^CONFIG_PACKAGE_sing-box=m/CONFIG_PACKAGE_sing-box=y/' .config
sed -i 's/^CONFIG_PACKAGE_chinadns-ng=m/CONFIG_PACKAGE_chinadns-ng=y/' .config
sed -i 's/^CONFIG_PACKAGE_geoview=m/CONFIG_PACKAGE_geoview=y/' .config

echo "[PassWall] 配置追加完成，以下是 PassWall 相关 CONFIG 项:"
grep -E "passwall|xray-core|sing-box|chinadns-ng|geoview" .config | grep -v '^#' | sort

# ------------------------------------------------------------------
# 5. 处理 flash 空间问题（小 ROM 设备适配）
#    128M 版本的 TR3000 可用空间非常紧张，必要时可以把部分代理核心
#    去掉。下面根据 DEVICE 环境变量做最小化裁剪（可选，注释掉即可保留全部）。
# ------------------------------------------------------------------
case "${DEVICE:-}" in
  cudy-tr3000-128M)
    echo "[PassWall] 检测到 128M 小 ROM 设备，精简代理核心以节省空间..."
    # 128M 只保留 sing-box（覆盖主流协议），去掉 xray-core / hysteria2 / tuic
    sed -i 's/^CONFIG_PACKAGE_xray-core=y/CONFIG_PACKAGE_xray-core=n/' .config
    sed -i 's/^CONFIG_PACKAGE_hysteria2=y/CONFIG_PACKAGE_hysteria2=n/' .config
    sed -i 's/^CONFIG_PACKAGE_tuic-client=y/CONFIG_PACKAGE_tuic-client=n/' .config
    sed -i 's/^CONFIG_PACKAGE_naiveproxy=y/CONFIG_PACKAGE_naiveproxy=n/' .config
    sed -i 's/^CONFIG_PACKAGE_hysteria=y/CONFIG_PACKAGE_hysteria=n/' .config
    sed -i 's/^CONFIG_PACKAGE_brook=y/CONFIG_PACKAGE_brook=n/' .config
    echo "[PassWall] 128M 精简完成，仅保留 sing-box + shadowsocks-rust 核心组合"
    ;;
  cudy-tr3000-256M)
    echo "[PassWall] 256M 设备，保留 xray-core + sing-box 双核心"
    ;;
  cudy-tr3000-512M|QLB-4Pro|ikuai-q6000-nand)
    echo "[PassWall] 512M+ 大 Flash 设备，保留全部代理组件"
    ;;
  *)
    echo "[PassWall] 未识别设备，使用默认完整配置"
    ;;
esac

# ------------------------------------------------------------------
# 6. 完成
# ------------------------------------------------------------------
echo "========================================"
echo "[PassWall] ✅ PassWall 集成完成"
echo "========================================"
echo "  - 源码位置 : package/passwall"
echo "              package/passwall-packages"
echo "  - 入口     : LuCI -> 服务 -> PassWall"
echo "  - 下一步   : workflow 将自动执行 make defconfig 并编译"
echo ""
