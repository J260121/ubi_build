#!/usr/bin/env bash
set -Eeuo pipefail

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"
REPO="https://github.com/chenmozhijin/turboacc.git"
BRANCH="luci"
DEST="$OPENWRT_DIR/package/turboacc/luci-app-turboacc"
TMP="${RUNNER_TEMP:-/tmp}/turboacc-luci-$$"

log() { echo "[TurboACC] $*"; }
die() { echo "[TurboACC] ERROR: $*" >&2; exit 1; }

[[ -f "$OPENWRT_DIR/Makefile" ]] ||
  die "OpenWrt 源码目录不存在：$OPENWRT_DIR"

# 如果源码树已有插件，避免重复克隆
if [[ -f "$DEST/Makefile" ]]; then
  log "发现已有 TurboACC 软件包，跳过克隆"
else
  rm -rf "$TMP"
  mkdir -p "$(dirname "$TMP")"

  git clone --depth 1 --single-branch \
    --branch "$BRANCH" "$REPO" "$TMP" ||
    die "TurboACC 仓库克隆失败"

  # 上游 luci 分支的实际目录为仓库/luci-app-turboacc
  SRC="$TMP/luci-app-turboacc"
  [[ -f "$SRC/Makefile" ]] ||
    die "上游目录结构异常，未找到 $SRC/Makefile"

  mkdir -p "$(dirname "$DEST")"
  rm -rf "$DEST"
  cp -a "$SRC" "$DEST"
  rm -rf "$TMP"
fi

[[ -f "$DEST/Makefile" ]] ||
  die "TurboACC Makefile 不存在"

# 仅启用 LuCI 插件，不强制加入不兼容的内核模块
CONFIG="$OPENWRT_DIR/.config"
if [[ -f "$CONFIG" ]]; then
  if grep -q '^CONFIG_PACKAGE_luci-app-turboacc=' "$CONFIG"; then
    sed -i \
      's/^CONFIG_PACKAGE_luci-app-turboacc=.*/CONFIG_PACKAGE_luci-app-turboacc=y/' \
      "$CONFIG"
  else
    echo 'CONFIG_PACKAGE_luci-app-turboacc=y' >> "$CONFIG"
  fi
else
  log "尚无 .config，请在配置文件中加入："
  log "CONFIG_PACKAGE_luci-app-turboacc=y"
fi

log "TurboACC LuCI 软件包已集成"
log "下一步：make defconfig，然后正常编译"
