
#!/usr/bin/env bash
# ImmortalWrt 24.10 aria2 预编译集成
# Repository: J260121/ubi_build
# Architecture: aarch64_cortex-a53

set -Eeuo pipefail

ARCH="aarch64_cortex-a53"
REPO_BASE="https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/${ARCH}"
PKG_NAME="aria2"

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"
WORK_DIR="${OPENWRT_DIR}/tmp/aria2-prebuilt"
PKG_DIR="${OPENWRT_DIR}/package/aria2-prebuilt"
FILES_DIR="${PKG_DIR}/files"

log() {
    # 关键修复：日志写入 stderr，不能污染命令替换的返回数据
    printf '[Aria2-IPK] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

for cmd in curl gzip awk sed tar ar; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "缺少必要命令：$cmd"
done

[[ -d "$OPENWRT_DIR/package" ]] ||
    die "找不到 OpenWrt 目录：$OPENWRT_DIR"

mkdir -p "$WORK_DIR"

log "OpenWrt 目录：$OPENWRT_DIR"
log "固定软件包架构：$ARCH"
log "软件仓库：$REPO_BASE"

# 从指定 feed 的 Packages.gz 中查找软件包。
# 函数 stdout 仅输出一行 filename|architecture|version。
lookup_package() {
    local package="$1"
    local repo="$2"
    local index plain result

    index="${WORK_DIR}/Packages-${repo}.gz"
    plain="${WORK_DIR}/Packages-${repo}.txt"

    log "查询软件包：${package}（feed: ${repo}）"

    if ! curl -fsSL --retry 3 --connect-timeout 20 \
        "${REPO_BASE}/${repo}/Packages.gz" -o "$index"; then
        log "无法下载 ${repo}/Packages.gz"
        return 1
    fi

    if ! gzip -t "$index" >/dev/null 2>&1; then
        log "索引文件损坏：$index"
        return 1
    fi

    # 完整解压到文件，避免 gzip | awk 提前退出造成 Broken pipe。
    if ! gzip -dc "$index" > "$plain"; then
        log "索引解压失败：$index"
        return 1
    fi

    result="$(
        awk -v wanted="$package" '
            BEGIN {
                RS = ""
                FS = "\n"
            }
            {
                name = filename = arch = version = ""

                for (i = 1; i <= NF; i++) {
                    sub(/\r$/, "", $i)

                    if (index($i, "Package: ") == 1)
                        name = substr($i, 10)
                    else if (index($i, "Filename: ") == 1)
                        filename = substr($i, 11)
                    else if (index($i, "Architecture: ") == 1)
                        arch = substr($i, 15)
                    else if (index($i, "Version: ") == 1)
                        version = substr($i, 10)
                }

                if (name == wanted &&
                    filename != "" &&
                    arch != "" &&
                    version != "") {
                    printf "%s|%s|%s\n", filename, arch, version
                    exit
                }
            }
        ' "$plain"
    )"

    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi

    log "在 ${repo} 索引中未找到有效的 ${package} 条目"
    return 1
}

# 依次搜索可能包含 aria2 的 feed。
FOUND=""
FOUND_REPO=""

for repo in packages base routing; do
    if result="$(lookup_package "$PKG_NAME" "$repo")"; then
        FOUND="$result"
        FOUND_REPO="$repo"
        break
    fi
done

[[ -n "$FOUND" ]] ||
    die "所有候选仓库均未找到 aria2 预编译 IPK"

# 解析索引数据并校验字段数量。
IFS='|' read -r IPK_PATH IPK_ARCH IPK_VERSION <<< "$FOUND"

[[ -n "${IPK_PATH:-}" ]] ||
    die "索引解析失败：Filename 为空，原始数据：$FOUND"

[[ -n "${IPK_ARCH:-}" ]] ||
    die "索引解析失败：Architecture 为空，原始数据：$FOUND"

[[ -n "${IPK_VERSION:-}" ]] ||
    die "索引解析失败：Version 为空，原始数据：$FOUND"

if [[ "$IPK_ARCH" != "$ARCH" && "$IPK_ARCH" != "all" ]]; then
    die "架构不匹配：仓库=${IPK_ARCH}，目标=${ARCH}"
fi

# 拒绝意外的绝对路径和目录跳转。
case "$IPK_PATH" in
    /*|../*|*/../*)
        die "索引返回了不安全的 Filename：$IPK_PATH"
        ;;
esac

IPK_FILE="${WORK_DIR}/aria2.ipk"
IPK_URL="${REPO_BASE}/${FOUND_REPO}/${IPK_PATH}"

log "匹配仓库：$FOUND_REPO"
log "软件包版本：$IPK_VERSION"
log "软件包架构：$IPK_ARCH"
log "IPK 下载地址：$IPK_URL"

curl -fL --retry 3 --connect-timeout 20 \
    "$IPK_URL" -o "$IPK_FILE" ||
    die "下载 aria2 IPK 失败"

[[ -s "$IPK_FILE" ]] || die "下载到的 IPK 文件为空"

# 校验 IPK 容器格式。
ar t "$IPK_FILE" > "${WORK_DIR}/ar-members.txt" ||
    die "下载文件不是有效的 IPK/AR 文件"

CONTROL_MEMBER="$(
    awk '/^control\.tar\.(gz|xz|zst)$/ { print; exit }' \
        "${WORK_DIR}/ar-members.txt"
)"
DATA_MEMBER="$(
    awk '/^data\.tar\.(gz|xz|zst)$/ { print; exit }' \
        "${WORK_DIR}/ar-members.txt"
)"

[[ -n "$CONTROL_MEMBER" ]] ||
    die "IPK 中找不到 control.tar 压缩包"

[[ -n "$DATA_MEMBER" ]] ||
    die "IPK 中找不到 data.tar 压缩包"

extract_member() {
    local member="$1"
    local dest="$2"
    local stream="${WORK_DIR}/member.archive"

    ar p "$IPK_FILE" "$member" > "$stream" ||
        die "无法读取 IPK 成员：$member"

    case "$member" in
        *.gz)
            tar -xzf "$stream" -C "$dest"
            ;;
        *.xz)
            tar -xJf "$stream" -C "$dest"
            ;;
        *.zst)
            command -v zstd >/dev/null 2>&1 ||
                die "IPK 使用 zstd 压缩，但系统没有 zstd"
            zstd -dc "$stream" | tar -xf - -C "$dest"
            ;;
        *)
            die "不支持的压缩格式：$member"
            ;;
    esac
}

CONTROL_DIR="${WORK_DIR}/control"
DATA_DIR="${WORK_DIR}/data"

rm -rf "$CONTROL_DIR" "$DATA_DIR"
mkdir -p "$CONTROL_DIR" "$DATA_DIR"

extract_member "$CONTROL_MEMBER" "$CONTROL_DIR" ||
    die "解压 control 失败"

extract_member "$DATA_MEMBER" "$DATA_DIR" ||
    die "解压 data 失败"

CONTROL_FILE="${CONTROL_DIR}/control"
[[ -s "$CONTROL_FILE" ]] ||
    die "IPK 内没有有效的 control 元数据"

get_control_field() {
    local field="$1"
    sed -n "s/^${field}: //p" "$CONTROL_FILE" | sed -n '1p'
}

META_NAME="$(get_control_field Package)"
META_VERSION="$(get_control_field Version)"
META_ARCH="$(get_control_field Architecture)"
META_DEPENDS="$(get_control_field Depends || true)"

[[ "$META_NAME" == "$PKG_NAME" ]] ||
    die "IPK 内部软件包名称不匹配：${META_NAME:-空}"

[[ -n "$META_ARCH" ]] ||
    die "IPK 内部 Architecture 字段为空"

if [[ "$META_ARCH" != "$ARCH" && "$META_ARCH" != "all" ]]; then
    die "IPK 实际架构不匹配：${META_ARCH}，目标=${ARCH}"
fi

[[ -d "$DATA_DIR" ]] ||
    die "IPK 数据目录不存在"

# 依赖项从 IPK control 元数据生成。
# 去除版本限制，只保留依赖包名称。
DEPENDS_MAKE=""
if [[ -n "$META_DEPENDS" ]]; then
    DEPENDS_MAKE="$(
        printf '%s\n' "$META_DEPENDS" |
        tr ',' '\n' |
        sed -E \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' |
        awk '
            NF {
                dep = $0
                sub(/[[:space:]]*\(.*$/, "", dep)
                sub(/[[:space:]]+$/, "", dep)

                if (dep ~ /^[A-Za-z0-9_.+-]+$/)
                    printf "+%s ", dep
            }
        '
    )"
fi

# 复制 aria2 的真实 IPK 文件内容。
rm -rf "$PKG_DIR"
mkdir -p "$FILES_DIR"
cp -a "$DATA_DIR"/. "$FILES_DIR"/

# 生成本地包装包。
# 注意：此处必须使用目标架构，不能把 ARM64 二进制声明成 all。
cat > "${PKG_DIR}/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=aria2-prebuilt
PKG_VERSION:=${META_VERSION}
PKG_RELEASE:=1
PKGARCH:=${ARCH}

include \$(INCLUDE_DIR)/package.mk

define Package/aria2-prebuilt
  SECTION:=net
  CATEGORY:=Network
  TITLE:=aria2 prebuilt binary
  DEPENDS:=${DEPENDS_MAKE}
  PKGARCH:=${ARCH}
endef

define Package/aria2-prebuilt/description
 Prebuilt aria2 package for ImmortalWrt ${ARCH}.
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/aria2-prebuilt/install
	\$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,aria2-prebuilt))
EOF

# 清理旧的 aria2 选择，再启用包装包。
CONFIG_FILE="${OPENWRT_DIR}/.config"

if [[ -f "$CONFIG_FILE" ]]; then
    sed -i \
        -e '/^CONFIG_PACKAGE_aria2=y$/d' \
        -e '/^CONFIG_PACKAGE_aria2-prebuilt=y$/d' \
        "$CONFIG_FILE"

    printf '%s\n' 'CONFIG_PACKAGE_aria2-prebuilt=y' >> "$CONFIG_FILE"
    log "已更新 .config"
else
    log "警告：尚未生成 .config，请确保脚本运行顺序在配置生成之后"
fi

log "预编译集成完成"
log "IPK 版本：${META_VERSION}"
log "IPK 架构：${META_ARCH}"
log "依赖：${DEPENDS_MAKE:-无}"
log "本地包装目录：${PKG_DIR}"
log "配置项：CONFIG_PACKAGE_aria2-prebuilt=y"
