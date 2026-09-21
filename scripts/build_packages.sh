#!/bin/bash
# =============================================================================
# scripts/build_packages.sh — TorchOffOnSleep 统一打包入口
#
# 本脚本是整个工程唯一认可的正式打包方式：Task 3.x 的验收全跑它，
# Task 4.3 的固件符号门禁也接在这里。
#
# 职责清单（对照《越狱插件打包规范》第 11 章与 design.md D7）：
#   1. set -euo pipefail
#   2. 构建锁：mkdir 原子建锁目录 + trap 清理 + stale 锁清理重试
#   3. THEOS 缺省 /opt/theos，可被环境变量覆盖
#   4. 三条线，每线前 make clean；rootful 空值分支保留但默认不启用
#   5. 每线独立 THEOS_PACKAGE_DIR，构建前清空；不用 find | head 选包
#   6. 产物复制到 out/，命名 TorchOffOnSleep_<Version>_<Scheme>_<ShortArch>.deb
#   7. 复制后 dpkg-deb -f 核对 Package / Version / Architecture 与文件名
#   8. 宿主元数据净化 clean_host_metadata（.DS_Store / ._* / __MACOSX）
#   9. 符号门禁 scripts/verify_symbols.sh（DSC_PATH 未提供则跳过，不失败）
#  10. 末尾打印两条线的验收命令提示
#
# 可用环境变量：
#   THEOS            theos 根目录，缺省 /opt/theos
#   ENABLE_ROOTFUL   置 1 才跑 rootful 空值分支，默认不跑
#   DSC_PATH         固件 dyld shared cache 路径；提供则先跑符号门禁
#   LOCK_WAIT_SECONDS  等待活锁的最长秒数，默认 120
#
# 三个名字别混（本工程实测值）：
#   PKG_ID       = com.tune.torchoffonsleep   control 的 Package 字段
#   DISPLAY_NAME = TorchOffOnSleep            control 的 Name 字段
#   TWEAK_NAME   = TorchOffOnSleep            Makefile 的 TWEAK_NAME
# theos 生成的 deb 文件名用 PKG_ID（com.tune.torchoffonsleep_1.0.0_iphoneos-arm64e.deb），
# 包头 Package 字段同样是 PKG_ID；本脚本复制到 out/ 的产物用 DISPLAY_NAME
# （TorchOffOnSleep_1.0.0_roothide_arm64e.deb）。两者不同是正确的，不要统一。
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 路径与默认值
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

THEOS="${THEOS:-/opt/theos}"
export THEOS

CONTROL_FILE="$PROJECT_ROOT/control"
OUT_DIR="$PROJECT_ROOT/out"
LOCAL_DATA_DIR="$PROJECT_ROOT/.theos"
STAGING_DIR="$LOCAL_DATA_DIR/_"          # theos 的 THEOS_STAGING_DIR 默认值
LOCK_DIR="$LOCAL_DATA_DIR/.build-packages.lock"
VERIFY_SCRIPT="$SCRIPT_DIR/verify_symbols.sh"

# 每条线的 package 目录彼此独立，避免后一条线读到上一条线的包。
PKG_DIR_ROOTHIDE="$LOCAL_DATA_DIR/packages-roothide"
PKG_DIR_ROOTLESS="$LOCAL_DATA_DIR/packages-rootless"
PKG_DIR_ROOTFUL="$LOCAL_DATA_DIR/packages-rootful"

# 产物名里的短架构与 deb 包头 Architecture 的对应关系（design.md D7）。
ROOTHIDE_SHORT_ARCH="arm64e"
ROOTHIDE_DEB_ARCH="iphoneos-arm64e"
ROOTLESS_SHORT_ARCH="arm64"
ROOTLESS_DEB_ARCH="iphoneos-arm64"
# rootful 线默认不启用；此处按 rootful 常规架构断言，将来启用时如需其它
# 架构，改这一行即可。
ROOTFUL_SHORT_ARCH="arm64"
ROOTFUL_DEB_ARCH="iphoneos-arm64"

DSC_PATH="${DSC_PATH:-}"
ENABLE_ROOTFUL="${ENABLE_ROOTFUL:-0}"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-120}"
LOCK_POLL_SECONDS=2
LOCK_STALE_RETRIES=3

# 由 trap 清理的全局状态
LOCK_HELD=0
WORK_DIR=""

# 从 control / Makefile 读出的标识（主流程赋值）
#   PKG_ID       control 的 Package 字段。theos 生成 deb 用的就是它，
#                deb 实际文件名为 <PKG_ID>_<Version>_<DebArch>.deb
#   DISPLAY_NAME control 的 Name 字段，工程展示名，out/ 产物文件名用它
#   TWEAK_NAME   Makefile 的 TWEAK_NAME，即 dylib 的文件名
# 三者取值不同是正常的：Package 是 com.tune.torchoffonsleep，
# Name 与 TWEAK_NAME 是 TorchOffOnSleep。约定名选包、包头核对用 PKG_ID，
# out/ 文件名用 DISPLAY_NAME，dylib 路径用 TWEAK_NAME，切勿混用。
PKG_ID=""
DISPLAY_NAME=""
TWEAK_NAME=""
VERSION=""

# Makefile 里读不到 TWEAK_NAME 时的回退值（工程唯一 tweak 名）
TWEAK_NAME_FALLBACK="TorchOffOnSleep"

# ---------------------------------------------------------------------------
# 基础工具函数
# ---------------------------------------------------------------------------
log() {
    printf '[build_packages] %s\n' "$*"
}

die() {
    printf '[build_packages] 错误：%s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"
}

# 从 control 读字段值（不硬编码版本号）
read_control_field() {
    local field="$1"
    local value
    value="$(sed -n "s/^${field}:[[:space:]]*//p" "$CONTROL_FILE" | sed -n '1p' | tr -d '\r')"
    printf '%s' "$value"
}

# 从 Makefile 读 TWEAK_NAME（dylib 名）。theos 的 tweak.mk 产出
# <TWEAK_NAME>.dylib，与 control 的 Package / Name 都没有必然关系，
# 所以单独读，读不到再回退到硬编码值。
read_makefile_tweak_name() {
    local makefile="$PROJECT_ROOT/Makefile"
    local value=""
    if [ -f "$makefile" ]; then
        value="$(sed -n 's/^TWEAK_NAME[[:space:]]*:*=[[:space:]]*//p' "$makefile" |
            sed -n '1p' | tr -d '\r' | awk '{print $1}')"
    fi
    if [ -z "$value" ]; then
        value="$TWEAK_NAME_FALLBACK"
        log "未能从 Makefile 读出 TWEAK_NAME，回退为 ${value}"
    fi
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# 职责 8：宿主元数据净化
# 在 staging 目录与解包目录上都要跑，防止 .DS_Store / ._* / __MACOSX
# 进入 deb（否则 dpkg 安装时报 trying to overwrite /.DS_Store）。
# ---------------------------------------------------------------------------
clean_host_metadata() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    find "$dir" -depth \( -name '.DS_Store' -o -name '._*' -o -name '__MACOSX' \) \
        -exec rm -rf {} + 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 职责 5：选包
# 禁止 find <dir> -name '*.deb' | head -n 1 —— 多包时会静默取错包。
# 优先用 theos 命名约定的明确路径；约定名不在时要求目录里恰好一个 deb。
# ---------------------------------------------------------------------------
select_built_deb() {
    local pkg_dir="$1"
    local expected="${2:-}"

    if [ -n "$expected" ] && [ -f "${pkg_dir}/${expected}" ]; then
        printf '%s\n' "${pkg_dir}/${expected}"
        return 0
    fi

    local count=0
    local only=""
    local candidate
    for candidate in "${pkg_dir}"/*.deb; do
        # 目录为空时通配符不展开，跳过字面量
        [ -e "$candidate" ] || continue
        count=$((count + 1))
        only="$candidate"
    done

    if [ "$count" -eq 1 ]; then
        if [ -n "$expected" ]; then
            log "注意：${pkg_dir} 中没有约定名 ${expected}，但只有一个 deb，采用 ${only}"
        fi
        printf '%s\n' "$only"
        return 0
    fi

    printf '[build_packages] 错误：%s 中应有且仅有一个 deb，实际 %s 个（期望名：%s）\n' \
        "$pkg_dir" "$count" "${expected:-<未指定>}" >&2
    return 1
}

# ---------------------------------------------------------------------------
# 职责 6 + 7：复制到 out/ 并核对包头与文件名
# ---------------------------------------------------------------------------
verify_package() {
    local src_deb="$1"
    local deb_arch="$2"
    local short_arch="$3"
    local scheme_label="$4"

    # out/ 产物文件名用展示名（规范 11.1：<DisplayName>）
    local expected_name="${DISPLAY_NAME}_${VERSION}_${scheme_label}_${short_arch}.deb"
    local dest="${OUT_DIR}/${expected_name}"

    mkdir -p "$OUT_DIR"
    cp -f "$src_deb" "$dest"
    log "已复制产物：out/${expected_name}"

    local actual_name
    actual_name="$(basename "$dest")"
    if [ "$actual_name" != "$expected_name" ]; then
        die "产物名不符：期望 ${expected_name}，实际 ${actual_name}"
    fi

    # dpkg-deb -f out/<deb> Package Version Architecture，与期望值逐字段比对。
    # 这里的 Package 期望值必须是 control 的 Package 字段（PKG_ID），
    # 因为 theos 打 deb 时写进包头的就是它，不是 out/ 文件名里的展示名。
    # 注意：dpkg-deb 在“请求多个字段”时会输出 "Field: value"（带字段名前缀），
    # 单字段时才只输出裸值；为兼容不同 dpkg 版本，这里逐行剥掉开头的
    # "字段名:" 前缀再比对（裸值行不含冒号，sed 原样保留，两种模式都对）。
    local got_fields expected_fields
    got_fields="$(dpkg-deb -f "$dest" Package Version Architecture | sed -E 's/^[^:]+:[[:space:]]*//')"
    expected_fields="$(printf '%s\n%s\n%s\n' "$PKG_ID" "$VERSION" "$deb_arch")"
    if [ "$got_fields" != "$expected_fields" ]; then
        printf '[build_packages] 错误：包头核对不一致\n  期望：\n%s\n  实际：\n%s\n' \
            "$expected_fields" "$got_fields" >&2
        exit 1
    fi
    log "包头核对通过：Package=${PKG_ID} Version=${VERSION} Architecture=${deb_arch}" \
        "（产物文件名展示名=${DISPLAY_NAME}）"

    # 解包后再跑一次净化并断言干净，确保 deb 内没有宿主元数据
    local unpack_dir="$WORK_DIR/unpack-${scheme_label}"
    rm -rf "$unpack_dir"
    dpkg-deb -R "$dest" "$unpack_dir"
    clean_host_metadata "$unpack_dir"

    local leftovers
    leftovers="$(find "$unpack_dir" \( -name '.DS_Store' -o -name '._*' -o -name '__MACOSX' \) -print)"
    if [ -n "$leftovers" ]; then
        die "deb 内仍存在宿主元数据：${leftovers}"
    fi
    log "清洁性核对通过：deb 内无 .DS_Store / ._* / __MACOSX"
}

# ---------------------------------------------------------------------------
# 职责 2：构建锁
# 用 mkdir 原子建锁目录（不是 test -f，存在竞态），锁目录内写 pid，
# trap 清理；发现 stale 锁（pid 不存在）时清理后重试，不无限等待。
# ---------------------------------------------------------------------------
lock_holder_alive() {
    local holder="$1"
    case "$holder" in
        '' | *[!0-9]*) return 1 ;;
    esac
    kill -0 "$holder" 2>/dev/null
}

read_lock_pid() {
    local pid_file="$LOCK_DIR/pid"
    [ -f "$pid_file" ] || return 0
    sed -n '1p' "$pid_file" 2>/dev/null | tr -d '[:space:]' || true
}

acquire_lock() {
    mkdir -p "$LOCAL_DATA_DIR"

    local waited=0
    local stale_retries=0
    local holder=""

    while :; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" >"$LOCK_DIR/pid"
            LOCK_HELD=1
            log "已获取构建锁：${LOCK_DIR}（pid $$）"
            return 0
        fi

        holder="$(read_lock_pid)"

        if lock_holder_alive "$holder"; then
            # 活锁：有限等待，超时即失败，绝不无限等待
            if [ "$waited" -ge "$LOCK_WAIT_SECONDS" ]; then
                die "等待构建锁超时（${LOCK_WAIT_SECONDS} 秒），pid ${holder} 仍在运行：" \
                    "${LOCK_DIR}"
            fi
            log "构建锁被 pid ${holder} 持有，等待中（${waited}/${LOCK_WAIT_SECONDS} 秒）"
            sleep "$LOCK_POLL_SECONDS"
            waited=$((waited + LOCK_POLL_SECONDS))
        else
            # stale 锁：清理后重试，重试次数有上限
            stale_retries=$((stale_retries + 1))
            if [ "$stale_retries" -gt "$LOCK_STALE_RETRIES" ]; then
                die "连续 ${LOCK_STALE_RETRIES} 次清理 stale 锁后仍无法获取构建锁：" \
                    "${LOCK_DIR}"
            fi
            log "发现 stale 构建锁（pid '${holder:-<空>}' 不存在），清理后重试" \
                "（第 ${stale_retries} 次）"
            rm -rf "$LOCK_DIR"
        fi
    done
}

release_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        rm -rf "$LOCK_DIR" || true
        LOCK_HELD=0
        log "已释放构建锁：${LOCK_DIR}"
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT
    release_lock
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR" || true
    fi
    exit "$rc"
}

# ---------------------------------------------------------------------------
# make 封装：保留退出码，失败时给出明确上下文
# ---------------------------------------------------------------------------
run_make() {
    log "执行：make $*"
    local rc=0
    make "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        die "make 失败（退出码 ${rc}）：make $*"
    fi
}

# ---------------------------------------------------------------------------
# 职责 9：固件符号门禁
# DSC_PATH 未提供 -> 打印提示并跳过；脚本不存在 -> 打印提示并跳过；
# 两者都不得让构建失败。提供了且校验不过 -> 构建中止。
# ---------------------------------------------------------------------------
run_symbol_gate() {
    if [ -z "$DSC_PATH" ]; then
        log "未提供 DSC_PATH，跳过固件符号门禁（不执行 ${VERIFY_SCRIPT}）"
        return 0
    fi
    if [ ! -f "$VERIFY_SCRIPT" ]; then
        log "已提供 DSC_PATH=${DSC_PATH}，但 ${VERIFY_SCRIPT} 尚不存在，跳过符号门禁"
        return 0
    fi
    log "运行固件符号门禁：DSC_PATH=${DSC_PATH}"
    local rc=0
    bash "$VERIFY_SCRIPT" || rc=$?
    if [ "$rc" -ne 0 ]; then
        die "固件符号门禁未通过（退出码 ${rc}），构建中止"
    fi
    log "固件符号门禁通过"
}

# ---------------------------------------------------------------------------
# 每条线动手前的净化：必须在 run_make 之前调用，清理上一条线/上一次构建的残留，
# 保证本线 package 目录里只会有本线新产出的 deb（select_built_deb 才不会取错）。
# 不要把它挪进 finalize_line：那是在构建之后运行，会把刚打好的 deb 删掉。
# ---------------------------------------------------------------------------
prebuild_clean() {
    local pkg_dir="$1"
    # 构建前清空该线独立的 package 目录，避免历史残留包导致“有且仅有一个 deb”误判
    rm -rf "$pkg_dir"
    # 构建前净化 staging 目录（make clean 已删过，这里是双保险）
    clean_host_metadata "$STAGING_DIR"
}

# ---------------------------------------------------------------------------
# 每条线构建之后的收尾：选包 -> 核对包头/文件名 -> 解包复检清洁性。
# 这里只做只读核对与复制，绝不删 package 目录——删除动作在 prebuild_clean。
# ---------------------------------------------------------------------------
finalize_line() {
    local pkg_dir="$1"
    local expected_deb_name="$2"
    local deb_arch="$3"
    local short_arch="$4"
    local scheme_label="$5"

    local src_deb
    src_deb="$(select_built_deb "$pkg_dir" "$expected_deb_name")"
    log "选中包：${src_deb}"

    verify_package "$src_deb" "$deb_arch" "$short_arch" "$scheme_label"
}

# ---------------------------------------------------------------------------
# 三条构建线
# ---------------------------------------------------------------------------
build_roothide_line() {
    log "=== 线 1/2：roothide（scheme 显式传 roothide，ARCHS=arm64e）==="
    prebuild_clean "$PKG_DIR_ROOTHIDE"
    run_make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide \
        "THEOS_PACKAGE_DIR=$PKG_DIR_ROOTHIDE"
    finalize_line "$PKG_DIR_ROOTHIDE" \
        "${PKG_ID}_${VERSION}_${ROOTHIDE_DEB_ARCH}.deb" \
        "$ROOTHIDE_DEB_ARCH" "$ROOTHIDE_SHORT_ARCH" "roothide"
}

build_rootless_line() {
    log "=== 线 2/2：rootless（scheme 显式传 rootless，ARCHS=arm64 arm64e）==="
    prebuild_clean "$PKG_DIR_ROOTLESS"
    run_make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless \
        "THEOS_PACKAGE_DIR=$PKG_DIR_ROOTLESS"
    finalize_line "$PKG_DIR_ROOTLESS" \
        "${PKG_ID}_${VERSION}_${ROOTLESS_DEB_ARCH}.deb" \
        "$ROOTLESS_DEB_ARCH" "$ROOTLESS_SHORT_ARCH" "rootless"
}

build_rootful_line() {
    log "=== 附加线：rootful（显式空 scheme，仅 ENABLE_ROOTFUL=1 时执行）==="
    prebuild_clean "$PKG_DIR_ROOTFUL"
    run_make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME= \
        "THEOS_PACKAGE_DIR=$PKG_DIR_ROOTFUL"
    finalize_line "$PKG_DIR_ROOTFUL" \
        "${PKG_ID}_${VERSION}_${ROOTFUL_DEB_ARCH}.deb" \
        "$ROOTFUL_DEB_ARCH" "$ROOTFUL_SHORT_ARCH" "rootful"
}

# ---------------------------------------------------------------------------
# 职责 10：末尾打印验收命令提示
# ---------------------------------------------------------------------------

# 各线短架构
line_short_arch() {
    case "$1" in
        roothide) printf '%s' "$ROOTHIDE_SHORT_ARCH" ;;
        rootless) printf '%s' "$ROOTLESS_SHORT_ARCH" ;;
        rootful) printf '%s' "$ROOTFUL_SHORT_ARCH" ;;
        *) return 1 ;;
    esac
}

# 各线解包后 dylib 的相对路径：rootless 的安装根带 /var/jb 前缀，
# roothide 没有该前缀（install prefix 为空，见 theos 的 scheme 模块）。
# dylib 文件名来自 Makefile 的 TWEAK_NAME（tweak.mk 产出 <TWEAK_NAME>.dylib），
# 与 control 的 Package（包 id）、Name（展示名）都可能不同。
line_dylib_relpath() {
    case "$1" in
        roothide) printf 'Library/MobileSubstrate/DynamicLibraries/%s.dylib' "$TWEAK_NAME" ;;
        rootless) printf 'var/jb/Library/MobileSubstrate/DynamicLibraries/%s.dylib' "$TWEAK_NAME" ;;
        rootful) printf 'Library/MobileSubstrate/DynamicLibraries/%s.dylib' "$TWEAK_NAME" ;;
        *) return 1 ;;
    esac
}

print_acceptance_hints() {
    local built_labels="$1"
    local label deb dylib_rel

    printf '\n'
    printf '=====================================================================\n'
    printf '构建完成。产物位于 %s\n' "$OUT_DIR"
    printf '=====================================================================\n'
    printf '\n'
    printf '验收命令（逐线复制执行）：\n'

    for label in $built_labels; do
        # out/ 产物文件名用展示名，与控制 的 Package 不同
        deb="${OUT_DIR}/${DISPLAY_NAME}_${VERSION}_${label}_$(line_short_arch "$label").deb"
        dylib_rel="$(line_dylib_relpath "$label")"
        printf '\n'
        printf -- '--- %s 线 ---\n' "$label"
        printf 'dpkg-deb -I %s\n' "$deb"
        printf 'dpkg-deb -c %s\n' "$deb"
        printf 'dpkg-deb -f %s Package Version Architecture\n' "$deb"
        printf 'rm -rf /tmp/torchoff-%s && dpkg-deb -R %s /tmp/torchoff-%s\n' \
            "$label" "$deb" "$label"
        printf "find /tmp/torchoff-%s \\( -name .DS_Store -o -name '._*' -o -name __MACOSX \\) -print\n" \
            "$label"
        printf 'lipo -archs /tmp/torchoff-%s/%s\n' "$label" "$dylib_rel"
        printf 'otool -L /tmp/torchoff-%s/%s\n' "$label" "$dylib_rel"
    done

    printf '\n'
    printf '清洁性判据：上面每条 find 的输出都应为空。\n'
    printf '架构判据：roothide -> %s；rootless -> %s。\n' \
        "$ROOTHIDE_DEB_ARCH" "$ROOTLESS_DEB_ARCH"
    printf '=====================================================================\n'
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    # 职责 1 的静态前置：必要的命令与文件都必须在动手前确认
    require_cmd make
    require_cmd dpkg-deb
    require_cmd find
    require_cmd sed
    require_cmd mktemp
    require_cmd cp
    require_cmd kill
    require_cmd sleep

    [ -f "$CONTROL_FILE" ] || die "找不到 control 文件：$CONTROL_FILE"
    [ -f "$THEOS/makefiles/common.mk" ] ||
        die "THEOS 路径无效：$THEOS（可用 THEOS=/path/to/theos 覆盖）"

    PKG_ID="$(read_control_field Package)"
    DISPLAY_NAME="$(read_control_field Name)"
    VERSION="$(read_control_field Version)"
    [ -n "$PKG_ID" ] || die "control 缺少 Package 字段"
    [ -n "$DISPLAY_NAME" ] || die "control 缺少 Name 字段"
    [ -n "$VERSION" ] || die "control 缺少 Version 字段"
    TWEAK_NAME="$(read_makefile_tweak_name)"
    log "包 id=${PKG_ID} 展示名=${DISPLAY_NAME} tweak 名=${TWEAK_NAME}" \
        "版本=${VERSION} THEOS=${THEOS} 项目根=${PROJECT_ROOT}"

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/torchoffonsleep-build.XXXXXX")"

    # 职责 2：构建锁
    acquire_lock

    # 职责 9：符号门禁放在构建之前，符号不过就不浪费构建时间
    run_symbol_gate

    # 职责 4：三条线，每线前 make clean；rootful 默认不启用
    build_roothide_line
    build_rootless_line

    local built_labels="roothide rootless"
    case "$ENABLE_ROOTFUL" in
        1 | true | TRUE | yes | YES | Yes)
            log "ENABLE_ROOTFUL=${ENABLE_ROOTFUL}，额外执行 rootful 空值分支"
            build_rootful_line
            built_labels="$built_labels rootful"
            ;;
        *)
            log "未设置 ENABLE_ROOTFUL=1，跳过 rootful 空值分支"
            ;;
    esac

    # 职责 10
    print_acceptance_hints "$built_labels"

    log "全部完成"
}

main "$@"
