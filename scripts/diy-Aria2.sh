
#!/usr/bin/env bash
# Prebuilt Aria2 integration for ImmortalWrt 24.10-SNAPSHOT.
# Fixed architecture: aarch64_cortex-a53
# Run after the OpenWrt source tree exists and before make defconfig.

set -Eeuo pipefail

ARCH="aarch64_cortex-a53"
REPO_ROOT="${REPO_ROOT:-https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/$ARCH}"
OPENWRT_DIR="${OPENWRT_DIR:-${GITHUB_WORKSPACE:-$PWD}/openwrt}"

# Allow running from inside the OpenWrt source directory.
if [[ ! -f "$OPENWRT_DIR/include/toplevel.mk" && -f "$PWD/include/toplevel.mk" ]]; then
    OPENWRT_DIR="$PWD"
fi

log() {
    # Important: logs must go to stderr so command substitutions stay clean.
    printf '[Aria2-IPK] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

for cmd in curl gzip awk sed tar ar find grep sort; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "缺少必要命令：$cmd"
done

[[ -f "$OPENWRT_DIR/include/toplevel.mk" ]] ||
    die "找不到 OpenWrt 源码目录：$OPENWRT_DIR"

PKG_ROOT="$OPENWRT_DIR/package"
WORK_DIR="$OPENWRT_DIR/tmp/aria2-prebuilt"
CONFIG_FILE="$OPENWRT_DIR/.config"

mkdir -p "$WORK_DIR" "$PKG_ROOT"
touch "$CONFIG_FILE"

# Only remove wrapper packages created by this script.
rm -rf \
    "$PKG_ROOT/aria2-prebuilt" \
    "$PKG_ROOT/luci-app-aria2-prebuilt" \
    "$PKG_ROOT/luci-i18n-aria2-zh-cn-prebuilt"

# Download and validate a repository package index.
get_index() {
    local repo="$1"
    local index="$WORK_DIR/Packages-${repo}.gz"
    local url="$REPO_ROOT/$repo/Packages.gz"

    if [[ ! -s "$index" ]] || ! gzip -t "$index" >/dev/null 2>&1; then
        rm -f "$index" "$index.tmp"
        log "下载软件包索引：$url"

        if ! curl -fsSL \
            --retry 3 \
            --retry-all-errors \
            --retry-delay 2 \
            --connect-timeout 20 \
            --max-time 180 \
            -o "$index.tmp" "$url"; then
            rm -f "$index.tmp"
            log "无法下载索引：$url"
            return 1
        fi

        if ! gzip -t "$index.tmp" >/dev/null 2>&1; then
            rm -f "$index.tmp"
            log "软件包索引损坏：$url"
            return 1
        fi

        mv "$index.tmp" "$index"
    fi

    # Return only the file path on stdout.
    printf '%s\n' "$index"
}

# Look up a package in a feed index.
# Output format: Filename|Architecture|Version|Depends
lookup_package() {
    local package="$1"
    local repo="$2"
    local index

    index="$(get_index "$repo")" || return 1

    gzip -dc "$index" | awk -v wanted="$package" '
        BEGIN {
            RS = ""
            FS = "\n"
        }
        {
            name = filename = arch = version = depends = ""

            for (i = 1; i <= NF; i++) {
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
                printf "%s|%s|%s|%s\n", filename, arch, version, depends
                exit
            }
        }
    '
}

# Find and download a package from one or more feeds.
# Output format: downloaded_ipk|Architecture|Version|Depends
download_ipk() {
    local package="$1"
    local repos="$2"
    local repo metadata filename arch version depends url
    local -a repo_list

    IFS=' ' read -r -a repo_list <<< "$repos"

    for repo in "${repo_list[@]}"; do
        log "查询软件包：$package（feed: $repo）"

        if ! metadata="$(lookup_package "$package" "$repo")"; then
            continue
        fi

        [[ -n "$metadata" ]] || continue

        IFS='|' read -r filename arch version depends <<< "$metadata"

        if [[ -z "$filename" || -z "$version" ]]; then
            log "索引条目不完整：$package"
            continue
        fi

        # Prevent an unexpected architecture from being silently accepted.
        if [[ "$arch" != "all" && "$arch" != "$ARCH" ]]; then
            log "跳过架构不匹配的软件包：$package ($arch)"
            continue
        fi

        url="$REPO_ROOT/$repo/$filename"
        local dest="$WORK_DIR/${package}_${version}.ipk"

        log "下载：$url"

        if ! curl -fsSL \
            --retry 3 \
            --retry-all-errors \
            --retry-delay 2 \
            --connect-timeout 20 \
            --max-time 300 \
            -o "$dest.tmp" "$url"; then
            rm -f "$dest.tmp"
            log "下载失败：$url"
            continue
        fi

        if ! ar t "$dest.tmp" >/dev/null 2>&1; then
            rm -f "$dest.tmp"
            log "下载文件不是有效的 IPK：$url"
            continue
        fi

        mv "$dest.tmp" "$dest"

        # Stdout contains metadata only; logs go to stderr.
        printf '%s|%s|%s|%s\n' "$dest" "$arch" "$version" "$depends"
        return 0
    done

    return 1
}

# Convert repository Depends metadata to OpenWrt Makefile dependencies.
# Rename dependencies that are supplied by our local wrapper packages.
normalize_depends() {
    local original_pkg="$1"
    local depends="${2:-}"

    awk -v input="$depends" -v pkg="$original_pkg" '
        BEGIN {
            count = split(input, items, ",")
            output = ""
            seen = " "
            for (i = 1; i <= count; i++) {
                dep = items[i]
                gsub(/^[ \t]+|[ \t]+$/, "", dep)

                # Drop version constraints, leaving the package name.
                sub(/[ \t]*\(.*/, "", dep)
                gsub(/^[ \t]+|[ \t]+$/, "", dep)

                # Ignore empty dependency entries.
                if (dep == "")
                    continue

                # Keep the first package in alternative dependency expressions.
                split(dep, alternatives, /[ \t]*\|[ \t]*/)
                dep = alternatives[1]
                gsub(/[ \t]+$/, "", dep)

                if (dep == "")
                    continue

                if (dep == "aria2")
                    dep = "aria2-prebuilt"
                else if (dep == "luci-app-aria2")
                    dep = "luci-app-aria2-prebuilt"

                if (index(seen, " " dep " ") == 0) {
                    output = output " +" dep
                    seen = seen dep " "
                }
            }
            sub(/^ /, "", output)
            print output
        }
    '
}

# Extract the data payload and wrap it as a local no-source-build package.
wrap_ipk() {
    local ipk="$1"
    local original_pkg="$2"
    local wrapper_pkg="$3"
    local pkgarch="$4"
    local version="$5"
    local depends="$6"
    local pkgdir="$PKG_ROOT/$wrapper_pkg"
    local extract_dir="$WORK_DIR/extract-$wrapper_pkg"
    local data_tar control_tar normalized_depends

    [[ -s "$ipk" ]] || die "IPK 文件不存在或为空：$ipk"

    rm -rf "$pkgdir" "$extract_dir"
    mkdir -p "$pkgdir/files" "$extract_dir"

    log "解包：$original_pkg"

    (
        cd "$extract_dir"
        ar x "$ipk"
    ) || die "无法解开 IPK：$ipk"

    data_tar="$(find "$extract_dir" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)"
    control_tar="$(find "$extract_dir" -maxdepth 1 -type f -name 'control.tar.*' -print -quit)"

    [[ -n "$data_tar" && -f "$data_tar" ]] ||
        die "IPK 中缺少 data.tar：$ipk"

    [[ -n "$control_tar" && -f "$control_tar" ]] ||
        die "IPK 中缺少 control.tar：$ipk"

    tar -xf "$data_tar" -C "$pkgdir/files" ||
        die "解压数据文件失败：$ipk"

    # Prefer Depends from the IPK control file if present.
    local control_file="$WORK_DIR/control-$wrapper_pkg"
    rm -rf "$control_file"
    mkdir -p "$control_file"
    tar -xf "$control_tar" -C "$control_file" ||
        die "解压控制信息失败：$ipk"

    local control_path
    control_path="$(find "$control_file" -type f -name control -print -quit)"

    if [[ -n "$control_path" && -f "$control_path" ]]; then
        local control_depends
        control_depends="$(awk '
            /^Depends: / {
                sub(/^Depends: /, "")
                printf "%s", $0
                active = 1
                next
            }
            active && /^[ \t]/ {
                gsub(/^[ \t]+/, "")
                printf " %s", $0
                next
            }
            active {
                exit
            }
        ' "$control_path")"

        [[ -z "$control_depends" ]] || depends="$control_depends"
    fi

    normalized_depends="$(normalize_depends "$original_pkg" "$depends")"

    cat > "$pkgdir/Makefile" <<MAKEFILE
include \$(TOPDIR)/rules.mk

PKG_NAME:=$wrapper_pkg
PKG_VERSION:=$version
PKG_RELEASE:=1
PKGARCH:=$pkgarch

include \$(INCLUDE_DIR)/package.mk

define Package/$wrapper_pkg
  SECTION:=net
  CATEGORY:=Network
  TITLE:=$original_pkg (prebuilt)
  DEPENDS:=$normalized_depends
endef

define Package/$wrapper_pkg/description
  Prebuilt $original_pkg payload from the ImmortalWrt package repository.
  No source compilation is performed by this wrapper.
endef

define Build/Compile
endef

define Package/$wrapper_pkg/install
	\$(INSTALL_DIR) \$(1)
	\$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,$wrapper_pkg))
MAKEFILE

    log "已生成：$pkgdir（PKGARCH=$pkgarch，版本=$version）"
}

# Enable or disable a Kconfig package symbol without duplicate entries.
set_symbol() {
    local symbol="$1"
    local value="$2"

    sed -i \
        -e "/^${symbol}=.*/d" \
        -e "/^# ${symbol} is not set$/d" \
        "$CONFIG_FILE"

    if [[ "$value" == "y" ]]; then
        printf '%s=y\n' "$symbol" >> "$CONFIG_FILE"
    else
        printf '# %s is not set\n' "$symbol" >> "$CONFIG_FILE"
    fi
}

log "OpenWrt 目录：$OPENWRT_DIR"
log "固定软件包架构：$ARCH"
log "软件仓库：$REPO_ROOT"

# 1. aria2 command-line program.
ARIA2_META="$(download_ipk aria2 "packages base")" ||
    die "在 packages/base 仓库中找不到 aria2 预编译 IPK。请检查仓库索引、版本和网络连接。"

IFS='|' read -r ARIA2_IPK ARIA2_ARCH ARIA2_VERSION ARIA2_DEPENDS <<< "$ARIA2_META"

[[ "$ARIA2_ARCH" == "all" ]] && ARIA2_ARCH="$ARCH"

wrap_ipk \
    "$ARIA2_IPK" \
    "aria2" \
    "aria2-prebuilt" \
    "$ARIA2_ARCH" \
    "$ARIA2_VERSION" \
    "$ARIA2_DEPENDS"

# 2. LuCI web interface.
APP_META="$(download_ipk luci-app-aria2 "luci packages")" ||
    die "找不到 luci-app-aria2 预编译 IPK。请检查 luci/packages 仓库索引。"

IFS='|' read -r APP_IPK APP_ARCH APP_VERSION APP_DEPENDS <<< "$APP_META"

wrap_ipk \
    "$APP_IPK" \
    "luci-app-aria2" \
    "luci-app-aria2-prebuilt" \
    "${APP_ARCH:-all}" \
    "$APP_VERSION" \
    "$APP_DEPENDS"

# 3. Simplified Chinese translation is optional.
I18N_META=""
if I18N_META="$(download_ipk luci-i18n-aria2-zh-cn "luci")"; then
    IFS='|' read -r I18N_IPK I18N_ARCH I18N_VERSION I18N_DEPENDS <<< "$I18N_META"

    wrap_ipk \
        "$I18N_IPK" \
        "luci-i18n-aria2-zh-cn" \
        "luci-i18n-aria2-zh-cn-prebuilt" \
        "${I18N_ARCH:-all}" \
        "$I18N_VERSION" \
        "$I18N_DEPENDS"

    set_symbol CONFIG_PACKAGE_luci-i18n-aria2-zh-cn-prebuilt y
else
    log "未找到简体中文语言包，继续构建；可在固件中另行安装。"
    set_symbol CONFIG_PACKAGE_luci-i18n-aria2-zh-cn-prebuilt n
fi

# Disable the source packages so the build system does not compile them.
set_symbol CONFIG_PACKAGE_aria2 n
set_symbol CONFIG_PACKAGE_luci-app-aria2 n
set_symbol CONFIG_PACKAGE_luci-i18n-aria2-zh-cn n

# Enable the local wrapper packages.
set_symbol CONFIG_PACKAGE_aria2-prebuilt y
set_symbol CONFIG_PACKAGE_luci-app-aria2-prebuilt y

log "Aria2 预编译包已集成。"
log "请在工作流中确保本脚本运行于 make defconfig 之前。"
log "检查最终 .config 中以下选项是否保留为 y："
log "  CONFIG_PACKAGE_aria2-prebuilt=y"
log "  CONFIG_PACKAGE_luci-app-aria2-prebuilt=y"
log "  CONFIG_PACKAGE_luci-i18n-aria2-zh-cn-prebuilt（若仓库提供）"
log "注意：预编译 IPK 必须与固件的 libc、依赖库及软件包版本兼容。"
