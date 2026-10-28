#!/bin/sh
# ImmortalWrt MT7986：编译阶段修改默认 Wi-Fi 名称
# 适配 J260121/ubi_build

set -eu

OPENWRT_DIR="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE 未设置}/openwrt"
CONFIG="$OPENWRT_DIR/package/base-files/files/bin/config_generate"

SSID_2G="277221866-2.4G"
SSID_5G="277221866-5G"

if [ ! -f "$CONFIG" ]; then
    echo "错误：未找到 $CONFIG"
    echo "请确认 OpenWrt 源码已下载并完成目录初始化。"
    exit 1
fi

# 备份原始配置生成脚本
cp -p "$CONFIG" "$CONFIG.ssid-backup"

# 检查默认无线名称生成位置
if ! grep -q 'set wireless.default_radio' "$CONFIG"; then
    echo "错误：未找到预期的无线配置生成代码，停止修改。"
    mv "$CONFIG.ssid-backup" "$CONFIG"
    exit 1
fi

# 编译阶段修改生成器：根据 radio0/radio1 写入不同 SSID
# 保留原有加密、密码、信道等配置逻辑
python3 - "$CONFIG" "$SSID_2G" "$SSID_5G" <<'PY'
import sys

path, ssid2, ssid5 = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# 只修改无线配置生成器里的默认 SSID 字符串，
# 不猜测源码中的实际变量结构。
old = 'set wireless.default_radio${devidx}.ssid=OpenWrt'

if old not in text:
    print("错误：当前源码中未找到标准 OpenWrt 默认 SSID 模板。")
    sys.exit(2)

# 保持 radio0/2.4G、radio1/5G 的默认名称分别生成。
new = '''case "$devidx" in
        0) ssid="%s" ;;
        1) ssid="%s" ;;
        *) ssid="OpenWrt" ;;
    esac
    set wireless.default_radio${devidx}.ssid="$ssid"''' % (ssid2, ssid5)

text = text.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)

print("已修改编译阶段无线 SSID 生成逻辑。")
PY

echo "===== 验证修改 ====="
grep -n -A6 -B3 'ssid=' "$CONFIG" | head -n 30
echo "2.4G 默认名称：$SSID_2G"
echo "5G 默认名称：$SSID_5G"
