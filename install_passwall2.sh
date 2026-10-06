
#!/bin/sh

# PassWall2 自动安装脚本
# 适用于 OpenWrt 系统 (OPKG 包管理器)

set -e

# 配置变量
GITHUB_REPO="Openwrt-Passwall/openwrt-passwall2"
LUCI_APP_NAME="luci-app-passwall2"
LANG_PACKAGE="luci-i18n-passwall2-zh-cn" # 默认安装中文语言包

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本 (sudo sh $0)"
        exit 1
    fi
}

# 获取系统架构
get_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="x86_64" ;;
        aarch64) ARCH="aarch64_generic" ;;
        armv7l) ARCH="arm_cortex-a9_vfpv4" ;; # 常见于 Broadcom/MTK
        mipsel) ARCH="mipsel_24kc" ;; # 常见于老款 MTK
        *) 
            log_warn "未识别的架构: $ARCH, 尝试使用默认 all 包或请手动指定"
            ARCH="all"
            ;;
    esac
    echo "$ARCH"
}

# 获取最新版本号
get_latest_version() {
    log_info "正在查询最新版本..."
    # 使用 GitHub API 获取最新 release tag
    LATEST_VER=$(curl -s https://api.github.com/repos/$GITHUB_REPO/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VER" ]; then
        log_error "无法获取最新版本号，请检查网络连接或 GitHub API 访问情况"
        exit 1
    fi
    log_info "最新版本: $LATEST_VER"
    echo "$LATEST_VER"
}

# 下载文件
download_package() {
    local url=$1
    local output=$2
    log_info "正在下载: $output"
    if curl -L -o "$output" "$url"; then
        log_info "下载成功: $output"
    else
        log_error "下载失败: $url"
        exit 1
    fi
}

# 安装主程序
install_main() {
    local version=$1
    local arch=$2
    local base_url="https://github.com/$GITHUB_REPO/releases/download/$version"
    
    # 构造文件名
    # 注意：PassWall2 的主包通常是 all 架构，因为它是 LuCI 应用
    local main_pkg="${LUCI_APP_NAME}_${version}_all.ipk"
    local lang_pkg="${LANG_PACKAGE}_${version}_all.ipk"
    
    local main_url="$base_url/$main_pkg"
    local lang_url="$base_url/$lang_pkg"

    # 下载主包
    download_package "$main_url" "/tmp/$main_pkg"
    
    # 下载语言包 (可选，如果存在)
    # 先检查语言包是否存在于 release 中，这里简化处理，直接尝试下载，失败则忽略
    if curl -s -o /dev/null -w "%{http_code}" "$lang_url" | grep -q "200"; then
        download_package "$lang_url" "/tmp/$lang_pkg"
        LANG_PKG_FILE="/tmp/$lang_pkg"
    else
        log_warn "未找到对应的语言包 $lang_pkg，将仅安装主程序"
        LANG_PKG_FILE=""
    fi

    # 更新 opkg 列表
    log_info "正在更新 opkg 软件包列表..."
    opkg update

    # 安装主包
    log_info "正在安装主程序..."
    if opkg install "/tmp/$main_pkg"; then
        log_info "主程序安装成功"
    else
        log_error "主程序安装失败，可能存在依赖问题"
        log_warn "尝试强制安装依赖..."
        opkg install --force-depends "/tmp/$main_pkg"
    fi

    # 安装语言包
    if [ -n "$LANG_PKG_FILE" ]; then
        log_info "正在安装中文语言包..."
        opkg install "$LANG_PKG_FILE"
    fi

    # 清理临时文件
    rm -f "/tmp/$main_pkg"
    if [ -n "$LANG_PKG_FILE" ]; then
        rm -f "$LANG_PKG_FILE"
    fi
    
    log_info "安装完成！请刷新浏览器页面或在 LuCI 菜单中查找 PassWall2"
}

# 主流程
main() {
    log_info "========================================"
    log_info "  PassWall2 自动安装脚本"
    log_info "========================================"
    
    check_root
    
    # 获取架构和版本
    ARCH=$(get_arch)
    VERSION=$(get_latest_version)
    
    # 执行安装
    install_main "$VERSION" "$ARCH"
    
    log_info "========================================"
    log_info "  安装结束"
    log_info "========================================"
}

main "$@"
