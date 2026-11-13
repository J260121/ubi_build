#!/usr/bin/env bash
# =========================================================
# UBI Build - Sysupgrade Config Extractor
# 适用仓库：J260121/ubi_build
# 用途：GitHub Actions 云编译时解压配置包
# =========================================================

set -Eeuo pipefail

SCRIPT_NAME="extract-sysupgrade-config"
ARCHIVE_NAME="sysupgrade-config.tar.gz"

# 仓库根目录
REPO_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"

# ImmortalWrt 源码目录，可由环境变量覆盖
OPENWRT_DIR="${OPENWRT_DIR:-$REPO_DIR/openwrt}"

# 配置压缩包
ARCHIVE="${CONFIG_ARCHIVE:-$REPO_DIR/zip/$ARCHIVE_NAME}"

# 固件 files 目录
DEST="$OPENWRT_DIR/files"

log() {
    echo "[$SCRIPT_NAME] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# 检查依赖
command -v tar >/dev/null 2>&1 || error "缺少 tar"
command -v grep >/dev/null 2>&1 || error "缺少 grep"

# 检查源码目录
[ -d "$OPENWRT_DIR" ] || error "源码目录不存在：$OPENWRT_DIR"

# 检查压缩包
[ -f "$ARCHIVE" ] || error "配置包不存在：$ARCHIVE"

log "仓库目录：$REPO_DIR"
log "源码目录：$OPENWRT_DIR"
log "配置包：$ARCHIVE"
log "目标目录：$DEST"

# 检查压缩包完整性
tar -tzf "$ARCHIVE" >/dev/null 2>&1 ||
    error "配置包损坏或不是有效的 tar.gz"

# 检查路径安全
tar -tzf "$ARCHIVE" > /tmp/sysupgrade-config-list.txt

if grep -Eq '(^/|(^|/)\.\.(/|$))' \
    /tmp/sysupgrade-config-list.txt; then
    error "压缩包存在不安全路径，拒绝解压"
fi

# 创建目标目录
mkdir -p "$DEST"

# 解压
log "开始解压配置包..."

tar \
    --no-same-owner \
    --no-same-permissions \
    -xzf "$ARCHIVE" \
    -C "$DEST"

# 兼容压缩包直接包含 config/ 的情况
if [ ! -d "$DEST/etc/config" ] && [ -d "$DEST/config" ]; then
    mkdir -p "$DEST/etc"
    mv "$DEST/config" "$DEST/etc/config"
fi

# 检查配置文件
[ -d "$DEST/etc/config" ] ||
    error "未发现 etc/config/，请检查压缩包目录结构"

log "配置文件列表："
find "$DEST/etc/config" -maxdepth 1 -type f -print | sort

log "配置包解压成功！"
log "配置目标：$DEST/etc/config"

exit 0
