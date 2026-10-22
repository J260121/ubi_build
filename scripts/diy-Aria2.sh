
#!/usr/bin/env bash
# Aria2 + LuCI + 简体中文
# J260121/ubi_build
# Target: mediatek/filogic
# Package arch: aarch64_cortex-a53

set -euo pipefail

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:?请设置 GITHUB_WORKSPACE}/openwrt}"
CONFIG="$OPENWRT_DIR/.config"

log() {
    echo "[Aria2] $*"
}

[[ -d "$OPENWRT_DIR" ]] || {
    log "ERROR: 找不到 OpenWrt 目录：$OPENWRT_DIR"
    exit 1
}

cd "$OPENWRT_DIR"
touch "$CONFIG"

# 检查软件包定义是否已由 feeds 安装
find_pkg() {
    local name="$1"
    find package feeds -type f -name Makefile \
        -path "*/$name/Makefile" -print -quit 2>/dev/null
}

set_config() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "$CONFIG"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG"
    elif grep -q "^# ${key} is not set$" "$CONFIG"; then
        sed -i "s|^# ${key} is not set$|${key}=${value}|" "$CONFIG"
    else
        printf '%s=%s\n' "$key" "$value" >> "$CONFIG"
    fi
}

# 必需包：缺少定义时明确报错，避免静默漏装
for pkg in aria2 luci-app-aria2; do
    if [[ -z "$(find_pkg "$pkg")" ]]; then
        log "ERROR: 未找到软件包 $pkg"
        log "请先完成 feeds update / feeds install，再运行本脚本。"
        exit 1
    fi
done

# 开启 Aria2 与 LuCI
set_config CONFIG_PACKAGE_aria2 y
set_config CONFIG_PACKAGE_luci-app-aria2 y

# 中文包是可选项；若存在则启用
if [[ -n "$(find_pkg luci-i18n-aria2-zh-cn)" ]]; then
    set_config CONFIG_PACKAGE_luci-i18n-aria2-zh-cn y
    log "已启用简体中文语言包"
else
    log "WARN: 当前 feeds 未找到 luci-i18n-aria2-zh-cn"
    log "将尝试使用 LuCI 自带语言或默认界面"
fi

# 首次启动时启用 Aria2 服务（不覆盖已有配置）
DEFAULTS="$OPENWRT_DIR/files/etc/uci-defaults/99-aria2-enable"
mkdir -p "$(dirname "$DEFAULTS")"

cat > "$DEFAULTS" <<'EOF'
#!/bin/sh

if [ -x /etc/init.d/aria2 ]; then
    /etc/init.d/aria2 enable
    /etc/init.d/aria2 start
fi

exit 0
EOF

chmod 0755 "$DEFAULTS"

log "已启用 Aria2、LuCI 管理界面及可用的中文包"
log "请继续执行 make defconfig"
