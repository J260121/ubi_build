
#!/usr/bin/env bash
# ImmortalWrt 24.10 aria2 预编译集成脚本
# 仓库：J260121/ubi_build
# 目标架构：aarch64_cortex-a53
# 不编译 aria2 源码，直接集成预编译 IPK

set -Eeuo pipefail

ARCH="aarch64_cortex-a53"
REPO_BASE="https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/${ARCH}"
PKG_NAME="aria2"

OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"
WORK_DIR="${OPENWRT_DIR}/tmp/aria2-prebuilt"
PKG_DIR="${OPENWRT_DIR}/package/aria2-prebuilt"
FILES_DIR="${PKG_DIR}/files"

log() {
    # 所有日志写入 stderr，防止污染命令替换结果
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
    die "找不到 OpenWrt 目录：$OPENWRT_DIR"

mkdir -p "$WORK_DIR"

log "OpenWrt 目录：$OPENWRT_DIR"
log "固定软件包架构：$ARCH"
log "软件仓库：$REPO_BASE"

# --------------------------------------------------
# 1. 下载并解析软件包索引
# --------------------------------------------------

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

    gzip -t "$index" >/dev/null 2>&1 ||
        die "软件包索引损坏：$index"

    # 完整解压到文件，避免 gzip 管道 Broken pipe
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
    die "未找到 aria2 预编译 IPK，请检查软件仓库"

IFS='|' read -r IPK_PATH IPK_ARCH IPK_VERSION <<< "$FOUND"

[[ -n "${IPK_PATH:-}" ]] ||
    die "索引解析失败：Filename 为空"

[[ -n "${IPK_ARCH:-}" ]] ||
    die "索引解析失败：Architecture 为空"

[[ -n "${IPK_VERSION:-}" ]] ||
    die "索引解析失败：Version 为空"

if [[ "$IPK_ARCH" != "$ARCH" && "$IPK_ARCH" != "all" ]]; then
    die "架构不匹配：仓库=${IPK_ARCH}，目标=${ARCH}"
fi

case "$IPK_PATH" in
    /*|../*|*/../*)
        die "软件包索引包含不安全路径：$IPK_PATH"
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

[[ -s "$IPK_FILE" ]] ||
    die "下载文件为空"

# --------------------------------------------------
# 2. 识别 IPK 外层容器
#    优先使用 Python 读取 ar 归档，避免依赖 ar 命令
# --------------------------------------------------

MEMBERS_FILE="${WORK_DIR}/ipk-members.txt"
IPK_FORMAT=""

if python3 - "$IPK_FILE" "$MEMBERS_FILE" list <<'PY'
import sys

src, out, mode = sys.argv[1:4]
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
            name = string_table[offset:].split(b"/\n", 1)[0].decode(
                "utf-8", "replace"
            )
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
    log "无法识别下载文件格式，前 32 字节如下："
    od -An -tx1 -N32 "$IPK_FILE" >&2 || true
    die "下载文件不是有效的 ar 或 tar 容器"
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
    die "IPK 中找不到 control.tar 压缩包"

[[ -n "$DATA_MEMBER" ]] ||
    die "IPK 中找不到 data.tar 压缩包"

# --------------------------------------------------
# 3. 提取 IPK 成员
# --------------------------------------------------

extract_ipk_member() {
    local member="$1"
    local output="$2"

    if [[ "$IPK_FORMAT" == "ar" ]]; then
        # 自行解析 ar 归档，避免 GNU/BSD ar 兼容性问题
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
        name = string_table[off:].split(b"/\n", 1)[0].decode(
            "utf-8", "replace"
        )

    if name == wanted:
        with open(out, "wb") as f:
            f.write(payload)
        sys.exit(0)

    pos = start + size + (size % 2)

sys.exit("找不到成员：" + wanted)
PY
    else
        tar -xOf "$IPK_FILE" "$member" > "$output" ||
            die "无法提取 IPK 成员：$member"
    fi

    [[ -s "$output" ]] ||
        die "提取的成员为空：$member"
}

extract_inner_tar() {
    local archive="$1"
    local destination="$2"

    case "$archive" in
        *.gz)
            tar -xzf "$archive" -C "$destination"
            ;;
        *.xz)
            tar -xJf "$archive" -C "$destination"
            ;;
        *.zst)
            command -v zstd >/dev/null 2>&1 ||
                die "IPK 使用 zstd 压缩，但系统没有 zstd"
            zstd -dc "$archive" | tar -xf - -C "$destination"
            ;;
        *)
            die "不支持的压缩格式：$archive"
            ;;
    esac
}

CONTROL_DIR="${WORK_DIR}/control"
DATA_DIR="${WORK_DIR}/data"
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

extract_ipk_member "$CONTROL_MEMBER" "$CONTROL_ARCHIVE"
extract_ipk_member "$DATA_MEMBER" "$DATA_ARCHIVE"

extract_inner_tar "$CONTROL_ARCHIVE" "$CONTROL_DIR"
extract_inner_tar "$DATA_ARCHIVE" "$DATA_DIR"

rm -rf "$CONTROL_DIR" "$DATA_DIR"
mkdir -p "$CONTROL_DIR" "$DATA_DIR"

extract_ipk_member "$CONTROL_MEMBER" "$CONTROL_ARCHIVE"
extract_ipk_member "$DATA_MEMBER" "$DATA_ARCHIVE"

extract_inner_tar "$CONTROL_ARCHIVE" "$CONTROL_DIR" ||
    die "解压 control 数据失败"

extract_inner_tar "$DATA_ARCHIVE" "$DATA_DIR" ||
    die "解压 data 数据失败"

CONTROL_FILE="${CONTROL_DIR}/control"
[[ -s "$CONTROL_FILE" ]] ||
    die "IPK 内部缺少 control 文件"

log "IPK 容器及内部数据解包成功"

# --------------------------------------------------
# 4. 校验 IPK 内部元数据
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
    die "IPK 内部软件包名称不匹配：${META_NAME:-空}"

[[ -n "$META_ARCH" ]] ||
    die "IPK 内部 Architecture 字段为空"

if [[ "$META_ARCH" != "$ARCH" && "$META_ARCH" != "all" ]]; then
    die "IPK 实际架构不匹配：${META_ARCH}，目标=${ARCH}"
fi

[[ -n "$META_VERSION" ]] ||
    META_VERSION="$IPK_VERSION"

# --------------------------------------------------
# 5. 复制数据文件并生成本地包装包
# --------------------------------------------------

rm -rf "$PKG_DIR"
mkdir -p "$FILES_DIR"

cp -a "$DATA_DIR"/. "$FILES_DIR"/ ||
    die "复制 aria2 文件失败"

# 将常见 Depends 字段转换成 OpenWrt 包依赖。
# 遇到无法简单解析的依赖表达式时，不自动伪造依赖名。
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
# 6. 更新 .config
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
    log "警告：未找到 .config，请确保脚本在配置生成后执行"
fi

log "预编译集成完成"
log "软件包版本：$META_VERSION"
log "软件包架构：$META_ARCH"
log "依赖：${DEPENDS_MAKE:-未提取到可转换依赖}"
log "本地包装目录：$PKG_DIR"
