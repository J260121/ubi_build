
#!/usr/bin/env bash
# ImmortalWrt 24.10 aria2 预编译集成
# 适配 J260121/ubi_build
# 固定架构：aarch64_cortex-a53

set -Eeuo pipefail

ARCH="aarch64_cortex-a53"
REPO_BASE="https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/${ARCH}"
PKG_NAME="aria2"

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"
WORK_DIR="${OPENWRT_DIR}/tmp/aria2-prebuilt"
PKG_DIR="${OPENWRT_DIR}/package/aria2-prebuilt"
FILES_DIR="${PKG_DIR}/files"

log() {
    echo "[Aria2-IPK] $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v gzip >/dev/null 2>&1 || die "缺少 gzip"
command -v ar >/dev/null 2>&1 || die "缺少 ar"
command -v tar >/dev/null 2>&1 || die "缺少 tar"

[[ -d "$OPENWRT_DIR/package" ]] ||
    die "找不到 OpenWrt 源码目录：$OPENWRT_DIR"

mkdir -p "$WORK_DIR" "$FILES_DIR"

log "OpenWrt 目录：$OPENWRT_DIR"
log "固定软件包架构：$ARCH"
log "软件仓库：$REPO_BASE"

# 读取软件包索引。
# 先完整解压，再搜索，避免 gzip 与 awk 提前退出造成 Broken pipe。
lookup_package() {
    local package="$1"
    local repo="$2"
    local index plain result

    index="${WORK_DIR}/Packages-${repo}.gz"
    plain="${WORK_DIR}/Packages-${repo}.txt"

    log "查询软件包：${package}（feed: ${repo}）"

    if ! curl -fL --retry 3 --connect-timeout 15 \
        "${REPO_BASE}/${repo}/Packages.gz" -o "$index"; then
        log "无法下载 ${repo} 软件包索引"
        return 1
    fi

    if ! gzip -t "$index" >/dev/null 2>&1; then
        log "软件包索引损坏：$index"
        return 1
    fi

    if ! gzip -dc "$index" > "$plain"; then
        log "索引解压失败：$index"
        return 1
    fi

    result="$(
        awk -v wanted="$package" '
            BEGIN { RS = ""; FS = "\n" }
            {
                name = filename = arch = version = depends = ""

                for (i = 1; i <= NF; i++) {
                    sub(/\r$/, "", $i)

                    if ($i ~ /^Package: /)
                        name = substr($i, 10)
                    else if ($i ~ /^Filename: /)
                        filename = substr($i, 11)
                    else if ($i ~ /^Architecture: /)
                        arch = substr($i, 15)
                    else if ($i ~ /^Version: /)
                        version = substr($i, 10)
                    else if ($i ~ /^Depends: /)
                        depends = substr($i, 10)
                }

                if (name == wanted && filename != "") {
                    printf "%s|%s|%s|%s\n", \
                        filename, arch, version, depends
                    exit
                }
            }
        ' "$plain"
    )"

    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi

    log "仓库 ${repo} 中没有找到 ${package}"
    return 1
}

# 从 IPK 中读取 control 元数据。
read_control_field() {
    local ipk="$1"
    local field="$2"
    local control

    control="$(ar p "$ipk" control.tar.gz 2>/dev/null |
        tar -xzOf - ./control 2>/dev/null || true)"

    if [[ -z "$control" ]]; then
        control="$(ar p "$ipk" control.tar.gz 2>/dev/null |
            tar -xzOf - control 2>/dev/null || true)"
    fi

    printf '%s\n' "$control" |
        sed -n "s/^${field}: //p" |
        head -n 1
}

# 查找 aria2：依次检查常用 feed。
FOUND=""
FOUND_REPO=""

for repo in packages base; do
    if FOUND="$(lookup_package "$PKG_NAME" "$repo")"; then
        FOUND_REPO="$repo"
        break
    fi
done

[[ -n "$FOUND" ]] ||
    die "未找到 aria2 预编译 IPK；请检查仓库索引及软件包是否存在"

IFS='|' read -r IPK_PATH IPK_ARCH IPK_VERSION IPK_DEPENDS <<< "$FOUND"

[[ -n "$IPK_PATH" ]] || die "索引中的 Filename 为空"
[[ -n "$IPK_VERSION" ]] || IPK_VERSION="unknown"

if [[ "$IPK_ARCH" != "$ARCH" && "$IPK_ARCH" != "all" ]]; then
    die "架构不匹配：仓库=${IPK_ARCH}，目标=${ARCH}"
fi

IPK_FILE="${WORK_DIR}/aria2.ipk"
IPK_URL="${REPO_BASE}/${FOUND_REPO}/${IPK_PATH}"

log "软件包版本：$IPK_VERSION"
log "软件包架构：$IPK_ARCH"
log "下载地址：$IPK_URL"

curl -fL --retry 3 --connect-timeout 15 \
    "$IPK_URL" -o "$IPK_FILE" ||
    die "IPK 下载失败"

[[ -s "$IPK_FILE" ]] || die "下载文件为空"

# 校验 IPK 容器。
ar t "$IPK_FILE" >/dev/null 2>&1 ||
    die "下载文件不是有效的 IPK/AR 软件包"

# 提取 control 元数据和数据文件。
CONTROL_DIR="${WORK_DIR}/control"
DATA_DIR="${WORK_DIR}/data"
mkdir -p "$CONTROL_DIR" "$DATA_DIR"

CONTROL_MEMBER="$(ar t "$IPK_FILE" |
    grep -E '^control\.tar\.(gz|xz|zst)$' | head -n 1 || true)"
DATA_MEMBER="$(ar t "$IPK_FILE" |
    grep -E '^data\.tar\.(gz|xz|zst)$' | head -n 1 || true)"

[[ -n "$CONTROL_MEMBER" ]] || die "IPK 中没有 control 压缩包"
[[ -n "$DATA_MEMBER" ]] || die "IPK 中没有 data 压缩包"

extract_member() {
    local member="$1"
    local dest="$2"
    local stream="${WORK_DIR}/member.archive"

    ar p "$IPK_FILE" "$member" > "$stream" ||
        die "无法读取 IPK 成员：$member"

    case "$member" in
        *.gz)  tar -xzf "$stream" -C "$dest" ;;
        *.xz)  tar -xJf "$stream" -C "$dest" ;;
        *.zst)
            command -v zstd >/dev/null 2>&1 ||
                die "IPK 使用 zstd 压缩，请安装 zstd"
            zstd -dc "$stream" | tar -xf - -C "$dest"
            ;;
    esac
}

extract_member "$CONTROL_MEMBER" "$CONTROL_DIR"
extract_member "$DATA_MEMBER" "$DATA_DIR"

CONTROL_FILE="${CONTROL_DIR}/control"
[[ -s "$CONTROL_FILE" ]] ||
    die "无法读取 IPK control 元数据"

META_NAME="$(sed -n 's/^Package: //p' "$CONTROL_FILE" | head -n 1)"
META_VERSION="$(sed -n 's/^Version: //p' "$CONTROL_FILE" | head -n 1)"
META_ARCH="$(sed -n 's/^Architecture: //p' "$CONTROL_FILE" | head -n 1)"
META_DEPENDS="$(sed -n 's/^Depends: //p' "$CONTROL_FILE" | head -n 1)"

[[ "$META_NAME" == "$PKG_NAME" ]] ||
    die "软件包名称不匹配：${META_NAME:-空}"

if [[ "$META_ARCH" != "$ARCH" && "$META_ARCH" != "all" ]]; then
    die "IPK 实际架构不匹配：${META_ARCH:-空}"
fi

# 将 IPK 中的数据文件放入本地包装包。
rm -rf "$FILES_DIR"
mkdir -p "$FILES_DIR"
cp -a "$DATA_DIR"/. "$FILES_DIR"/

# 把依赖项转换成 OpenWrt 包 Makefile 的依赖格式。
# 去除版本比较条件，仅保留包名。
DEPENDS_MAKE=""
if [[ -n "$META_DEPENDS" ]]; then
    DEPENDS_MAKE="$(
        printf '%s\n' "$META_DEPENDS" |
        tr ',' '\n' |
        sed -E \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' \
            -e 's/[[:space:]]*\([<>=!]+[^)]*\)//g' |
        awk 'NF {
            if ($0 ~ /^[A-Za-z0-9_.+-]+$/)
                printf "+%s ", $0
        }'
    )"
fi

# 生成本地包装软件包 Makefile。
cat > "${PKG_DIR}/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=aria2-prebuilt
PKG_VERSION:=${META_VERSION:-$IPK_VERSION}
PKG_RELEASE:=1

PKG_BUILD_DIR:=\$(BUILD_DIR)/\$(PKG_NAME)

include \$(INCLUDE_DIR)/package.mk

define Package/aria2-prebuilt
  SECTION:=net
  CATEGORY:=Network
  TITLE:=aria2 prebuilt binary
  DEPENDS:=${DEPENDS_MAKE}
  PKGARCH:=all
endef

define Package/aria2-prebuilt/description
 aria2 prebuilt from ImmortalWrt ${ARCH} repository.
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

# 避免同时选择源码版 aria2，启用本地预编译包装包。
CONFIG_FILE="${OPENWRT_DIR}/.config"
if [[ -f "$CONFIG_FILE" ]]; then
    sed -i \
        -e '/^CONFIG_PACKAGE_aria2=y$/d' \
        -e '/^# CONFIG_PACKAGE_aria2 is not set$/d' \
        -e '/^CONFIG_PACKAGE_aria2-prebuilt=y$/d' \
        "$CONFIG_FILE"

    echo 'CONFIG_PACKAGE_aria2-prebuilt=y' >> "$CONFIG_FILE"
fi

log "预编译集成完成"
log "来源：${FOUND_REPO}"
log "版本：${META_VERSION:-$IPK_VERSION}"
log "架构：${META_ARCH}"
log "本地包：${PKG_DIR}"
log "已启用 CONFIG_PACKAGE_aria2-prebuilt=y"
