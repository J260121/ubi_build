
#!/usr/bin/env bash
# ImmortalWrt 24.10 aria2 预编译集成脚本
# 目标架构：aarch64_cortex-a53
# 直接下载官方预编译 IPK，不编译 aria2 源码

set -Eeuo pipefail

ARCH="aarch64_cortex-a53"
REPO_BASE="https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/${ARCH}"
PKG_NAME="aria2"

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"
WORK_DIR="${OPENWRT_DIR}/tmp/aria2-prebuilt"
PKG_DIR="${OPENWRT_DIR}/package/aria2-prebuilt"
FILES_DIR="${PKG_DIR}/files"

log() {
    printf '[Aria2-IPK] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

for cmd in curl gzip awk sed tar python3; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "缺少必要命令：$cmd"
done

[[ -d "$OPENWRT_DIR/package" ]] ||
    die "找不到 OpenWrt package 目录：$OPENWRT_DIR/package"

mkdir -p "$WORK_DIR"

log "OpenWrt 目录：$OPENWRT_DIR"
log "固定软件包架构：$ARCH"
log "软件仓库：$REPO_BASE"

# --------------------------------------------------
# 1. 查询官方软件包索引
# --------------------------------------------------

lookup_package() {
    local package="$1"
    local repo="$2"
    local index="${WORK_DIR}/Packages-${repo}.gz"
    local plain="${WORK_DIR}/Packages-${repo}.txt"
    local result

    log "查询软件包：${package}（feed: ${repo}）"

    if ! curl -fsSL --retry 3 --connect-timeout 20 \
        "${REPO_BASE}/${repo}/Packages.gz" -o "$index"; then
        log "无法下载 ${repo}/Packages.gz"
        return 1
    fi

    gzip -t "$index" >/dev/null 2>&1 ||
        die "软件包索引损坏：$index"

    gzip -dc "$index" > "$plain" ||
        die "索引解压失败：$index"

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
                    version != "" &&
                    (arch == "all" || arch == "aarch64_cortex-a53")) {
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

    log "仓库 ${repo} 中没有找到有效的 ${package} 条目"
    return 1
}

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
    die "未找到 aria2 预编译 IPK"

IFS='|' read -r IPK_PATH IPK_ARCH IPK_VERSION <<< "$FOUND"

[[ -n "${IPK_PATH:-}" ]] ||
    die "索引解析失败：Filename 为空"

[[ "$IPK_PATH" != /* && "$IPK_PATH" != *".."* ]] ||
    die "软件包索引包含不安全路径：$IPK_PATH"

[[ "$IPK_ARCH" == "$ARCH" || "$IPK_ARCH" == "all" ]] ||
    die "架构不匹配：$IPK_ARCH"

IPK_FILE="${WORK_DIR}/aria2.ipk"
IPK_URL="${REPO_BASE}/${FOUND_REPO}/${IPK_PATH}"

log "匹配仓库：$FOUND_REPO"
log "软件包版本：$IPK_VERSION"
log "软件包架构：$IPK_ARCH"
log "IPK 下载地址：$IPK_URL"

curl -fL --retry 3 --connect-timeout 20 \
    "$IPK_URL" -o "$IPK_FILE" ||
    die "下载 aria2 IPK 失败"

[[ -s "$IPK_FILE" ]] ||
    die "下载文件为空"

# --------------------------------------------------
# 2. 识别 IPK 外层容器
#    支持 tar 和 ar 两种格式
# --------------------------------------------------

MEMBERS_FILE="${WORK_DIR}/ipk-members.txt"
IPK_FORMAT=""

if python3 - "$IPK_FILE" "$MEMBERS_FILE" <<'PY'
import sys

src, out = sys.argv[1:3]
data = open(src, "rb").read()

if not data.startswith(b"!<arch>\n"):
    sys.exit(1)

names = []
pos = 8
string_table = b""

while pos < len(data):
    if pos + 60 > len(data):
        sys.exit("ar 文件头不完整")

    header = data[pos:pos + 60]
    if header[58:60] != b"`\n":
        sys.exit("无效的 ar 文件头")

    raw_name = header[:16].decode("utf-8", "replace").strip()
    size_text = header[48:58].decode("ascii", "replace").strip()

    try:
        size = int(size_text)
    except ValueError:
        sys.exit("无效的 ar 成员大小")

    start = pos + 60
    end = start + size

    if end > len(data):
        sys.exit("ar 成员超出文件范围")

    payload = data[start:end]
    name = raw_name.rstrip("/")

    if raw_name == "//":
        string_table = payload
    elif raw_name.startswith("#1/"):
        n = int(raw_name[3:])
        name = payload[:n].decode("utf-8", "replace")
    elif raw_name.startswith("/") and raw_name[1:].isdigit():
        offset = int(raw_name[1:])
        if offset < len(string_table):
            name = string_table[offset:].split(
                b"/\n", 1
            )[0].decode("utf-8", "replace")
    elif raw_name in ("/", "/SYM64/"):
        name = raw_name

    if name not in ("/", "//", "/SYM64/"):
        names.append(name)

    pos = end + (size % 2)

with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(names) + "\n")
PY
then
    IPK_FORMAT="ar"
elif tar -tf "$IPK_FILE" > "$MEMBERS_FILE" 2>/dev/null; then
    IPK_FORMAT="tar"
else
    die "无法识别下载文件的 IPK 容器格式"
fi

log "检测到 IPK 容器格式：$IPK_FORMAT"

CONTROL_MEMBER="$(
    awk '/(^|\/)control\.tar\.(gz|xz|zst)$/ { print; exit }' \
        "$MEMBERS_FILE"
)"

DATA_MEMBER="$(
    awk '/(^|\/)data\.tar\.(gz|xz|zst)$/ { print; exit }' \
        "$MEMBERS_FILE"
)"

[[ -n "$CONTROL_MEMBER" ]] ||
    die "IPK 中找不到 control.tar.gz/xz/zst"

[[ -n "$DATA_MEMBER" ]] ||
    die "IPK 中找不到 data.tar.gz/xz/zst"

# --------------------------------------------------
# 3. 提取 IPK 内部成员
# --------------------------------------------------

extract_ipk_member() {
    local member="$1"
    local output="$2"

    if [[ "$IPK_FORMAT" == "tar" ]]; then
        tar -xOf "$IPK_FILE" "$member" > "$output" ||
            die "无法提取 IPK 成员：$member"
    else
        python3 - "$IPK_FILE" "$member" "$output" <<'PY'
import sys

src, wanted, out = sys.argv[1:4]
data = open(src, "rb").read()

if not data.startswith(b"!<arch>\n"):
    sys.exit("不是 ar 归档")

pos = 8
string_table = b""

while pos < len(data):
    header = data[pos:pos + 60]

    if len(header) != 60 or header[58:60] != b"`\n":
        sys.exit("无效的 ar 成员头")

    raw = header[:16].decode("utf-8", "replace").strip()
    size = int(header[48:58].decode("ascii").strip())
    start = pos + 60
    payload = data[start:start + size]

    name = raw.rstrip("/")

    if raw == "//":
        string_table = payload
    elif raw.startswith("#1/"):
        n = int(raw[3:])
        name = payload[:n].decode("utf-8", "replace")
        payload = payload[n:]
    elif raw.startswith("/") and raw[1:].isdigit():
        off = int(raw[1:])
        name = string_table[off:].split(
            b"/\n", 1
        )[0].decode("utf-8", "replace")

    if name == wanted:
        with open(out, "wb") as f:
            f.write(payload)
        sys.exit(0)

    pos = start + size + (size % 2)

sys.exit("找不到成员：" + wanted)
PY
        [[ -s "$output" ]] ||
            die "提取的 IPK 成员为空：$member"
    fi
}

# 根据 IPK 成员的真实后缀命名临时文件。
# 不要统一命名成 .tar，否则解压函数无法判断压缩格式。
case "$CONTROL_MEMBER" in
    *.gz)  CONTROL_ARCHIVE="${WORK_DIR}/control-inner.tar.gz" ;;
    *.xz)  CONTROL_ARCHIVE="${WORK_DIR}/control-inner.tar.xz" ;;
    *.zst) CONTROL_ARCHIVE="${WORK_DIR}/control-inner.tar.zst" ;;
    *) die "不支持的 control 压缩格式：$CONTROL_MEMBER" ;;
esac

case "$DATA_MEMBER" in
    *.gz)  DATA_ARCHIVE="${WORK_DIR}/data-inner.tar.gz" ;;
    *.xz)  DATA_ARCHIVE="${WORK_DIR}/data-inner.tar.xz" ;;
    *.zst) DATA_ARCHIVE="${WORK_DIR}/data-inner.tar.zst" ;;
    *) die "不支持的 data 压缩格式：$DATA_MEMBER" ;;
esac

CONTROL_DIR="${WORK_DIR}/control"
DATA_DIR="${WORK_DIR}/data"

# 清理旧结果后，只解压一次。
rm -rf "$CONTROL_DIR" "$DATA_DIR"
mkdir -p "$CONTROL_DIR" "$DATA_DIR"

extract_ipk_member "$CONTROL_MEMBER" "$CONTROL_ARCHIVE"
extract_ipk_member "$DATA_MEMBER" "$DATA_ARCHIVE"

# --------------------------------------------------
# 4. 解压内部压缩包
# --------------------------------------------------

extract_inner_tar() {
    local archive="$1"
    local destination="$2"

    [[ -s "$archive" ]] ||
        die "压缩文件不存在或为空：$archive"

    # 关键修复：tar -C 目标目录必须先创建。
    mkdir -p "$destination" ||
        die "无法创建解压目录：$destination"

    case "$archive" in
        *.tar.gz)
            tar -xzf "$archive" -C "$destination" ||
                die "解压失败：$archive"
            ;;
        *.tar.xz)
            tar -xJf "$archive" -C "$destination" ||
                die "解压失败：$archive"
            ;;
        *.tar.zst)
            if command -v zstd >/dev/null 2>&1; then
                zstd -dc "$archive" |
                    tar -xf - -C "$destination" ||
                    die "解压失败：$archive"
            elif tar --help 2>/dev/null | grep -q -- '--zstd'; then
                tar --zstd -xf "$archive" -C "$destination" ||
                    die "解压失败：$archive"
            else
                die "缺少 zstd 解压支持：$archive"
            fi
            ;;
        *)
            die "不支持的压缩格式：$archive"
            ;;
    esac
}

log "解压 control 元数据"
extract_inner_tar "$CONTROL_ARCHIVE" "$CONTROL_DIR"

log "解压 aria2 程序文件"
extract_inner_tar "$DATA_ARCHIVE" "$DATA_DIR"

CONTROL_FILE="${CONTROL_DIR}/control"

[[ -s "$CONTROL_FILE" ]] ||
    die "IPK 内部缺少 control 文件"

log "IPK 容器及内部数据解包成功"

# --------------------------------------------------
# 5. 校验 IPK 元数据
# --------------------------------------------------

get_control_field() {
    local field="$1"
    sed -n "s/^${field}: //p" "$CONTROL_FILE" | sed -n '1p'
}

META_NAME="$(get_control_field Package)"
META_VERSION="$(get_control_field Version)"
META_ARCH="$(get_control_field Architecture)"
META_DEPENDS="$(get_control_field Depends || true)"

[[ "$META_NAME" == "$PKG_NAME" ]] ||
    die "IPK 内部包名不匹配：${META_NAME:-空}"

[[ "$META_ARCH" == "$ARCH" || "$META_ARCH" == "all" ]] ||
    die "IPK 实际架构不匹配：${META_ARCH:-空}"

[[ -n "$META_VERSION" ]] ||
    META_VERSION="$IPK_VERSION"

log "内部包名：$META_NAME"
log "内部版本：$META_VERSION"
log "内部架构：$META_ARCH"
log "原始依赖：${META_DEPENDS:-未声明}"

# --------------------------------------------------
# 6. 生成本地预编译包装包
# --------------------------------------------------

rm -rf "$PKG_DIR"
mkdir -p "$FILES_DIR"

cp -a "$DATA_DIR"/. "$FILES_DIR"/ ||
    die "复制 aria2 文件失败"

# 把简单的依赖名转换为 OpenWrt Makefile 依赖格式。
# 删除版本约束；复杂的替代依赖表达式不自动伪造。
DEPENDS_MAKE=""

if [[ -n "$META_DEPENDS" ]]; then
    DEPENDS_MAKE="$(
        printf '%s\n' "$META_DEPENDS" |
        tr ',' '\n' |
        awk '
            {
                dep = $0
                sub(/^[[:space:]]+/, "", dep)
                sub(/[[:space:]]+$/, "", dep)
                sub(/[[:space:]]*\(.*$/, "", dep)
                sub(/[[:space:]]+$/, "", dep)

                if (dep ~ /^[A-Za-z0-9_.+-]+$/)
                    printf "+%s ", dep
            }
        '
    )"
fi

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

# --------------------------------------------------
# 7. 更新固件配置
# --------------------------------------------------

CONFIG_FILE="${OPENWRT_DIR}/.config"

if [[ -f "$CONFIG_FILE" ]]; then
    sed -i \
        -e '/^CONFIG_PACKAGE_aria2=y$/d' \
        -e '/^CONFIG_PACKAGE_aria2-prebuilt=y$/d' \
        "$CONFIG_FILE"

    printf '%s\n' 'CONFIG_PACKAGE_aria2-prebuilt=y' >> "$CONFIG_FILE"

    log "已启用 CONFIG_PACKAGE_aria2-prebuilt=y"
else
    log "警告：尚未生成 .config，请确认后续配置阶段启用本地包"
fi

log "预编译集成完成"
log "软件包版本：$META_VERSION"
log "软件包架构：$META_ARCH"
log "依赖：${DEPENDS_MAKE:-未提取到可转换依赖}"
log "本地包装目录：$PKG_DIR"
