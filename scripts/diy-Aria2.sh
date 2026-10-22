#!/usr/bin/env bash
# Aria2 + LuCI + 简体中文：预编译 IPK 集成
# 参考 scripts/diy-ssrplus.sh 的下载、校验、解包和本地包装逻辑
# Target: mediatek/filogic
# Arch: aarch64_cortex-a53
# Run after feeds are ready, before make defconfig
# Does NOT compile aria2 or luci-app-aria2 from source.

set -Eeuo pipefail

ARCH="aarch64_cortex-a53"
OPENWRT_DIR="${OPENWRT_DIR:-$PWD}"

# 可通过环境变量覆盖，以匹配自己的 ImmortalWrt 分支
REPO_ROOT="${ARIA2_REPO_ROOT:-https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/$ARCH}"

WORK_DIR="$OPENWRT_DIR/tmp/aria2-prebuilt"
PKG_ROOT="$OPENWRT_DIR/package"

ARIA2_DIR="$PKG_ROOT/aria2-prebuilt"
LUCI_DIR="$PKG_ROOT/aria2-prebuilt-luci-app"
I18N_DIR="$PKG_ROOT/aria2-prebuilt-luci-i18n-zh-cn"

log() {
    echo "[Aria2-IPK] $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

[[ -f "$OPENWRT_DIR/include/toplevel.mk" ]] ||
    die "$OPENWRT_DIR 不是有效的 OpenWrt 源码目录"

for cmd in curl gzip awk sed grep tr find sort tar ar wc; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "缺少命令：$cmd"
done

mkdir -p "$WORK_DIR"
mkdir -p "$PKG_ROOT"

# 防止重复运行后残留旧包装包
rm -rf "$ARIA2_DIR" "$LUCI_DIR" "$I18N_DIR"

# --------------------------------------------------
# 软件包索引
# --------------------------------------------------

get_index() {
    local repo="$1"
    local index="$WORK_DIR/Packages-${repo}.gz"
    local url="$REPO_ROOT/$repo/Packages.gz"

    if [[ ! -s "$index" ]]; then
        log "下载软件包索引：$url"
        curl --fail --location --retry 3 --retry-all-errors \
            --connect-timeout 20 --max-time 180 \
            -o "$index.tmp" "$url" ||
            {
                rm -f "$index.tmp"
                return 1
            }

        gzip -t "$index.tmp" ||
            {
                rm -f "$index.tmp"
                die "软件包索引损坏：$url"
            }

        mv "$index.tmp" "$index"
    fi

    printf '%s\n' "$index"
}

# 从 Packages.gz 精确查询 Package / Filename / Architecture / Version
lookup_package() {
    local name="$1"
    shift

    local repo index result

    for repo in "$@"; do
        index="$(get_index "$repo")" || continue

        result="$(
            gzip -dc "$index" |
            awk -v target="$name" '
                BEGIN { RS=""; FS="\n" }
                {
                    pkg=""; filename=""; arch=""; version=""
                    for (i=1; i<=NF; i++) {
                        if ($i ~ /^Package: /)
                            pkg=substr($i, 10)
                        else if ($i ~ /^Filename: /)
                            filename=substr($i, 11)
                        else if ($i ~ /^Architecture: /)
                            arch=substr($i, 14)
                        else if ($i ~ /^Version: /)
                            version=substr($i, 10)
                    }
                    if (pkg == target && filename != "") {
                        print filename "\t" arch "\t" version
                        exit
                    }
                }
            '
        )"

        if [[ -n "$result" ]]; then
            printf '%s\n' "$result"
            return 0
        fi
    done

    return 1
}

# --------------------------------------------------
# IPK 格式检查和解包
# --------------------------------------------------

unpack_ipk() {
    local ipk="$1"
    local dest="$2"

    rm -rf "$dest"
    mkdir -p "$dest"

    if ar t "$ipk" >/dev/null 2>&1; then
        (cd "$dest" && ar x "$ipk")
    elif tar -tf "$ipk" >/dev/null 2>&1; then
        tar -xf "$ipk" -C "$dest"
    else
        die "无效的 IPK 文件：$ipk"
    fi
}

extract_archive() {
    local archive="$1"
    local dest="$2"

    case "$archive" in
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.tar.zst|*.tar.bz2)
            tar -xf "$archive" -C "$dest"
            ;;
        *)
            die "不支持的 IPK 内部归档：$archive"
            ;;
    esac
}

# --------------------------------------------------
# 下载并校验预编译 IPK
# --------------------------------------------------

download_ipk() {
    local pkg="$1"
    local repos="$2"
    local meta filename pkgarch version url output

    local -a repo_list
    IFS=' ' read -r -a repo_list <<< "$repos"

    meta="$(lookup_package "$pkg" "${repo_list[@]}")" ||
        return 1

    IFS=$'\t' read -r filename pkgarch version <<< "$meta"

    [[ -n "$filename" && -n "$pkgarch" ]] ||
        die "$pkg 的软件包元数据不完整"

    if [[ "$pkgarch" != "all" && "$pkgarch" != "$ARCH" ]]; then
        die "$pkg 架构不匹配：$pkgarch（期望 all 或 $ARCH）"
    fi

    url="$REPO_ROOT/$filename"
    output="$WORK_DIR/$(basename "$filename")"

    log "下载 $pkg $version [$pkgarch]"
    curl --fail --location --retry 3 --retry-all-errors \
        --retry-delay 2 --connect-timeout 20 --max-time 300 \
        -A 'Mozilla/5.0 Aria2-prebuilt-build' \
        -o "$output.tmp" "$url" ||
        {
            rm -f "$output.tmp"
            die "下载失败：$url"
        }

    [[ -s "$output.tmp" ]] || die "下载文件为空：$pkg"
    ar t "$output.tmp" >/dev/null 2>&1 ||
        die "下载结果不是有效的 IPK：$pkg"

    mv "$output.tmp" "$output"

    printf '%s\t%s\t%s\n' "$output" "$pkgarch" "$version"
}

# --------------------------------------------------
# 读取依赖并转换为本地预编译包装包依赖
# --------------------------------------------------

read_dependencies() {
    local ipk="$1"
    local wrapper="$2"
    local outer="$WORK_DIR/read-control"
    local cdir="$WORK_DIR/read-control-data"
    local control_archive control deps dep

    unpack_ipk "$ipk" "$outer"

    control_archive="$(
        find "$outer" -maxdepth 1 -type f \
            -name 'control.tar.*' -print -quit
    )"

    [[ -n "$control_archive" ]] ||
        die "IPK 缺少 control 归档：$ipk"

    rm -rf "$cdir"
    mkdir -p "$cdir"
    extract_archive "$control_archive" "$cdir"

    local control="$cdir/control"
    [[ -f "$control" ]] || control="$cdir/./control"
    [[ -f "$control" ]] || die "IPK 缺少 control 文件：$ipk"

    deps="$(
        awk '
            BEGIN { IGNORECASE=1 }
            /^Depends:[[:space:]]*/ {
                sub(/^[^:]*:[[:space:]]*/, "")
                print
                exit
            }
        ' "$control" |
        tr ',' '\n' |
        sed -E \
            -e 's/[[:space:]]*\([^)]*\)//g' \
            -e 's/^[[:space:]]+//' \
            -e 's/[[:space:]]+$//'
    )"

    local result=""
    while IFS= read -r dep; do
        dep="${dep%%[[:space:]]*}"
        [[ -z "$dep" ]] && continue

        # 这些由基础系统提供，不作为显式包装依赖
        case "$dep" in
            libc|libgcc|libpthread|librt|libdl|kernel)
                continue
                ;;
        esac

        # 将包间依赖指向本地预编译包装包
        case "$dep" in
            aria2)
                dep="aria2-prebuilt"
                ;;
            luci-app-aria2)
                dep="aria2-prebuilt-luci-app"
                ;;
        esac

        # 不重复追加依赖
        case " $result " in
            *" +$dep "*) ;;
            *)
                result="${result:+$result }+$dep"
                ;;
        esac
    done <<< "$deps"

    printf '%s' "$result"
}

# --------------------------------------------------
# 把官方 IPK 包装成本地 OpenWrt 软件包
# 保留原始文件载荷，不执行上游源码编译
# --------------------------------------------------

wrap_ipk() {
    local ipk="$1"
    local wrapper="$2"
    local pkgarch="$3"
    local target_dir="$4"
    local category="$5"

    local outer="$WORK_DIR/${wrapper}-outer"
    local payload="$WORK_DIR/${wrapper}-payload"
    local cdir="$WORK_DIR/${wrapper}-control"
    local control_archive data_archive control
    local original_pkg version pkg_version pkg_release depends

    unpack_ipk "$ipk" "$outer"

    control_archive="$(
        find "$outer" -maxdepth 1 -type f \
            -name 'control.tar.*' -print -quit
    )"
    data_archive="$(
        find "$outer" -maxdepth 1 -type f \
            -name 'data.tar.*' -print -quit
    )"

    [[ -n "$control_archive" && -n "$data_archive" ]] ||
        die "IPK 缺少 control/data 归档：$ipk"

    rm -rf "$cdir" "$payload"
    mkdir -p "$cdir" "$payload"

    extract_archive "$control_archive" "$cdir"

    control="$cdir/control"
    [[ -f "$control" ]] || control="$cdir/./control"
    [[ -f "$control" ]] || die "找不到 control 文件：$ipk"

    original_pkg="$(
        awk -F': *' 'tolower($1)=="package" {print $2; exit}' "$control"
    )"
    version="$(
        awk -F': *' 'tolower($1)=="version" {print $2; exit}' "$control"
    )"

    [[ -n "$original_pkg" && -n "$version" ]] ||
        die "IPK 缺少 Package 或 Version 元数据"

    if [[ "$version" =~ ^(.+)-r([0-9]+)$ ]]; then
        pkg_version="${BASH_REMATCH[1]}"
        pkg_release="${BASH_REMATCH[2]}"
    else
        pkg_version="$version"
        pkg_release=1
    fi

    extract_archive "$data_archive" "$payload"

    mkdir -p "$target_dir/files"
    cp -a "$payload/." "$target_dir/files/"

    depends="$(read_dependencies "$ipk" "$wrapper")"

    # 语言包依赖本地包装后的 LuCI 应用
    if [[ "$wrapper" == "aria2-prebuilt-luci-i18n-zh-cn" ]]; then
        depends="${depends:+$depends }+aria2-prebuilt-luci-app"
    fi

    cat > "$target_dir/Makefile" <<MAKEFILE
include \$(TOPDIR)/rules.mk

PKG_NAME:=$wrapper
PKG_VERSION:=$pkg_version
PKG_RELEASE:=$pkg_release
PKGARCH:=$pkgarch

include \$(INCLUDE_DIR)/package.mk

define Package/$wrapper
  SECTION:=net
  CATEGORY:=$category
  TITLE:=$original_pkg (prebuilt payload)
  DEPENDS:=$depends
endef

define Package/$wrapper/description
  Prebuilt $original_pkg payload from ImmortalWrt package repository.
  No upstream source compilation.
endef

define Build/Compile
endef

define Package/$wrapper/install
	\$(INSTALL_DIR) \$(1)
	\$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,$wrapper))
MAKEFILE

    log "已包装 $original_pkg $version -> $wrapper [$pkgarch]"
}

# --------------------------------------------------
# 获取三个软件包
# --------------------------------------------------

log "Repository: $REPO_ROOT"
log "Architecture fixed to $ARCH"

ARIA2_META="$(download_ipk aria2 "packages base")" ||
    die "仓库中找不到 aria2 预编译 IPK"

LUCI_META="$(download_ipk luci-app-aria2 "luci")" ||
    die "仓库中找不到 luci-app-aria2 预编译 IPK"

# 中文包可选：找不到时继续，但会明确提示
I18N_META=""
if I18N_META="$(download_ipk luci-i18n-aria2-zh-cn "luci")"; then
    log "找到简体中文语言包"
else
    log "WARN: 未找到 luci-i18n-aria2-zh-cn，将不集成中文包"
fi

IFS=$'\t' read -r ARIA2_IPK ARIA2_ARCH ARIA2_VERSION <<< "$ARIA2_META"
IFS=$'\t' read -r LUCI_IPK LUCI_ARCH LUCI_VERSION <<< "$LUCI_META"

wrap_ipk "$ARIA2_IPK" \
    "aria2-prebuilt" "$ARIA2_ARCH" "$ARIA2_DIR" "Network"

wrap_ipk "$LUCI_IPK" \
    "aria2-prebuilt-luci-app" "$LUCI_ARCH" "$LUCI_DIR" "LuCI"

if [[ -n "$I18N_META" ]]; then
    IFS=$'\t' read -r I18N_IPK I18N_ARCH I18N_VERSION <<< "$I18N_META"

    wrap_ipk "$I18N_IPK" \
        "aria2-prebuilt-luci-i18n-zh-cn" \
        "$I18N_ARCH" "$I18N_DIR" "LuCI"
fi

# --------------------------------------------------
# 配置 .config：只选择包装包，关闭同名源码包
# --------------------------------------------------

CONFIG_FILE="$OPENWRT_DIR/.config"
touch "$CONFIG_FILE"

set_symbol() {
    local symbol="$1"
    local value="$2"

    sed -i \
        -e "/^${symbol}=.*$/d" \
        -e "/^# ${symbol} is not set$/d" \
        "$CONFIG_FILE"

    if [[ "$value" == "y" ]]; then
        printf '%s=y\n' "$symbol" >> "$CONFIG_FILE"
    else
        printf '# %s is not set\n' "$symbol" >> "$CONFIG_FILE"
    fi
}

set_symbol CONFIG_PACKAGE_aria2 n
set_symbol CONFIG_PACKAGE_luci-app-aria2 n
set_symbol CONFIG_PACKAGE_luci-i18n-aria2-zh-cn n

set_symbol CONFIG_PACKAGE_aria2-prebuilt y
set_symbol CONFIG_PACKAGE_aria2-prebuilt-luci-app y

if [[ -n "$I18N_META" ]]; then
    set_symbol CONFIG_PACKAGE_aria2-prebuilt-luci-i18n-zh-cn y
fi

log "预编译 Aria2 集成完成"
log "请继续执行 make defconfig"
log "检查包装包配置是否保留："
grep -E '^CONFIG_PACKAGE_aria2-prebuilt.*=y$' "$CONFIG_FILE" || true
log "注意：依赖库仍由现有 feeds/固件配置提供；本脚本不编译 Aria2 本体。"
