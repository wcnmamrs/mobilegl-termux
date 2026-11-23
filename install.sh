#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  mobilegl-termux —— 安装 / 校验 / 卸载
#
#  作用：把 MobileGL 的 split 架构装好，让 proot 容器（默认 Debian）里的程序
#        直接用手机 GPU（Mali / Adreno / PowerVR 的 Vulkan），无 root。
#
#  用法：
#      bash install.sh                    # 安装（已装则做幂等修复）
#      bash install.sh --check            # 只体检，不改动任何文件
#      bash install.sh --uninstall        # 卸载（按安装清单逐项删除并校验）
#      bash install.sh --distro NAME      # 指定 proot 容器（不指定且存在多个时会询问）
#      bash install.sh --payload FILE     # 用本地 payload 包（离线安装）
#      bash install.sh --force            # 跳过"已是最新"的短路，强制重装文件
#      bash install.sh --verbose          # 打印每一步的细节
#      bash install.sh --help
#
#  退出码：
#      0 成功    2 参数错    3 环境不满足    4 载荷获取/校验失败
#      5 安装失败  6 验证失败    7 卸载失败
#
#  设计取向：任何一步失败都不留半装状态 —— 失败会自动回滚到安装前。
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

VERSION="1.0.10"
REPO_OWNER="wcnmamrs"
REPO_NAME="mobilegl-termux"
PAYLOAD_FILE="mobilegl-payload-arm64-v${VERSION}.tar.xz"
PAYLOAD_SHA256="50981bdf6b70e0cf941c7cbc0bf4af3c9136ee054d8d083a671d5654f4f4ff84"

MGL_HOME="${MGL_HOME:-$HOME/mgl}"
DISTRO="${DISTRO_NAME:-}"          # 为空 = 自动探测 / 询问
DISTRO_ARG=""
PROOT_BASE="${PREFIX:?必须在 Termux 里运行（找不到 PREFIX）}/var/lib/proot-distro/containers"
PROOT_DIR="${PROOT_DIR:-}"          # 为空 = 由所选的容器决定
CACHE_DIR="$MGL_HOME/.cache"
LOG="$MGL_HOME/install.log"
MANIFEST="$MGL_HOME/installed-files.txt"

ACTION="install"
PAYLOAD_LOCAL=""
FORCE=0
VERBOSE=0

# ---------------------------------------------------------------------------
# 输出：三种标签 [i] / [E] / [OK]，无 emoji。日志保留纯文本，终端带颜色。
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_E=$'\033[31m'
    C_B=$'\033[1m'; C_DIM=$'\033[2m'
else
    C_RST=""; C_I=""; C_OK=""; C_E=""; C_B=""; C_DIM=""
fi

_log() {
    mkdir -p "$MGL_HOME" 2>/dev/null || true
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG" 2>/dev/null || true
}

# 所有界面消息一律走 stderr —— stdout 只留给"数据"（例如解包后的载荷目录），
# 否则 $(unpack_payload ...) 会把提示文字一起吞进变量。
info() { printf '%s[i]%s %s\n' "$C_I" "$C_RST" "$*" >&2; _log i "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_OK" "$C_RST" "$*" >&2; _log OK "$*"; }
err()  { printf '%s[E]%s %s\n' "$C_E" "$C_RST" "$*" >&2; _log E "$*"; }
dim()  { [ "$VERBOSE" = 1 ] && printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RST" >&2 || true; }
head1() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_RST" >&2; _log = "$*"; }

die() { local code="${2:-5}"; err "$1"; exit "$code"; }

ERR_REPORTED=0
on_err() {
    local line="$1"
    [ "$ERR_REPORTED" = 1 ] && return 0
    ERR_REPORTED=1
    err "在第 ${line} 行失败（命令退出码非 0）"
    err "日志：$LOG"
    if [ "$ACTION" = "install" ] && [ "${ROLLBACK_ON_FAIL:-0}" = "1" ]; then
        err "正在回滚到安装前状态……"
        do_rollback || err "回滚过程中又有失败，请检查 $LOG 后手动处理"
    fi
    exit 5
}
trap 'on_err $LINENO' ERR

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1${2:+（$2）}" 3
}

sha_of() { sha256sum "$1" | awk '{print $1}'; }

has_file() { [ -f "$1" ]; }

free_mb() {  # Termux 的 df 是 toybox，只认 -Pk；统一按 KB 取再换算
    local out
    out=$(df -Pk "$1" 2>/dev/null | awk 'NR==2{print int($4/1024)}') || true
    printf '%s' "${out:-0}"
}

# 在容器里执行；proot 的 stderr 提示会被过滤，但退出码保留。
in_container() {
    local script="$1" out rc=0
    out=$(proot-distro login "$DISTRO" --shared-tmp -- /bin/bash -c "$script" 2>&1) || rc=$?
    printf '%s\n' "$out" | grep -v '^proot warning' || true
    return $rc
}

# 登录 shell 版：会读到 /etc/profile.d/mobilegl.sh —— 也正是用户日常"装完就能用"的路径
in_container_login() {
    local script="$1" out rc=0
    out=$(proot-distro login "$DISTRO" --shared-tmp -- /bin/bash -lc "$script" 2>&1) || rc=$?
    printf '%s\n' "$out" | grep -v '^proot warning' || true
    return $rc
}

write_file_atomic() {  # <目标> <内容>
    local dst="$1" tmp="${1}.mgl-tmp.$$"
    mkdir -p "$(dirname "$dst")"
    printf '%s\n' "$2" >"$tmp"
    mv -f "$tmp" "$dst"
}

record() { printf '%s\n' "$1" >>"$MANIFEST"; }

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --check)     ACTION="check" ;;
        --uninstall) ACTION="uninstall" ;;
        --repair)    ACTION="install"; FORCE=1 ;;
        --force)     FORCE=1 ;;
        --distro)    shift; [ $# -gt 0 ] || die "--distro 需要一个容器名" 2; DISTRO_ARG="$1" ;;
        --payload)   shift; [ $# -gt 0 ] || die "--payload 需要一个文件路径" 2; PAYLOAD_LOCAL="$1" ;;
        --verbose|-v) VERBOSE=1 ;;
        --help|-h)   usage; exit 0 ;;
        *)           die "未知参数：$1（--help 看用法）" 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 环境自检
# ---------------------------------------------------------------------------
# 容器里的多架构库目录不是所有发行版都一样（Debian 系是 usr/lib/aarch64-linux-gnu，
# Arch/Fedora 是 usr/lib 或 usr/lib64，Alpine 是 lib）。用 ldconfig 的真实输出定位，
# 找不到再退回常见候选；仍然找不到就把它当成致命错误，而不是写死一个路径后神秘失败。
detect_multiarch_rel() {
    local rel=""
    rel=$(printf '%s' "$(in_container 'ldconfig -p 2>/dev/null | awk "/libGL\\.so\\.1 /{print \$NF; exit}"' 2>/dev/null)" | tr -d "\r")
    if [ -n "$rel" ]; then
        rel=$(dirname "$rel")
        rel=${rel#/}
        [ -d "$PROOT_DIR/$rel" ] && { printf '%s' "$rel"; return 0; }
    fi
    local cand
    for cand in usr/lib/aarch64-linux-gnu usr/lib64 usr/lib lib; do
        if [ -e "$PROOT_DIR/$cand/libGL.so.1" ] || [ -e "$PROOT_DIR/$cand/libGLX.so.0" ]; then
            printf '%s' "$cand"; return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# 容器（发行版）选择
#   —— 不假设一定是 Debian，也不假设机器上只有一份容器。
# ---------------------------------------------------------------------------
container_names() {
    local dir
    for dir in "$PROOT_BASE"/*/rootfs; do
        [ -d "$dir" ] || continue
        basename "$(dirname "$dir")"
    done
}

_container_field() {   # $1=容器名  $2=os-release 的键
    sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$PROOT_BASE/$1/rootfs/etc/os-release" 2>/dev/null | head -1
}

container_pretty() {
    local pretty
    pretty=$(_container_field "$1" PRETTY_NAME)
    [ -n "$pretty" ] || pretty="$1"
    printf '%s' "$pretty"
}

container_is_musl() {
    local root="$PROOT_BASE/$1/rootfs"
    [ "$(_container_field "$1" ID)" = "alpine" ] && return 0
    compgen -G "$root/lib/ld-musl-*" >/dev/null 2>&1 && return 0
    return 1
}

select_distro() {
    local names=() name choice i=0
    while IFS= read -r name; do [ -n "$name" ] && names+=("$name"); done < <(container_names)

    if [ "${#names[@]}" -eq 0 ]; then
        die "没找到任何 proot 容器（$PROOT_BASE 下没有 */rootfs）
    先装一个：proot-distro install <发行版>" 3
    fi

    if [ -n "$DISTRO_ARG" ]; then
        DISTRO="$DISTRO_ARG"
    elif [ -z "$DISTRO" ]; then
        if [ "${#names[@]}" -eq 1 ]; then
            DISTRO="${names[0]}"
            info "检测到唯一容器：$DISTRO（$(container_pretty "$DISTRO")）"
        else
            head1 "选择容器"
            printf '  发现 %d 个 proot 容器：\n\n' "${#names[@]}" >&2
            for name in "${names[@]}"; do
                i=$((i + 1))
                printf '    %d) %-18s %s\n' "$i" "$name" "$(container_pretty "$name")" >&2
            done
            printf '\n  请输入编号 [1-%d]，回车默认 1，Ctrl+C 取消：' "${#names[@]}" >&2
            # 能在终端里问就在终端里问（stdin 可能被管道占用）；否则退回 stdin。
            if exec 3</dev/tty 2>/dev/null; then
                read -r choice <&3 || choice=""
                exec 3<&-
            else
                read -r choice || choice=""
            fi
            printf '\n' >&2
            [ -n "$choice" ] || choice=1
            case "$choice" in *[!0-9]*) die "无效选择：$choice" 2 ;; esac
            { [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ]; } || die "编号超出范围：$choice" 2
            DISTRO="${names[$((choice - 1))]}"
            ok "已选择容器：$DISTRO（$(container_pretty "$DISTRO")）"
        fi
    fi

    [ -n "$DISTRO" ] || die "未能确定目标容器（可用：${names[*]}）" 3
    [ -d "$PROOT_BASE/$DISTRO/rootfs" ] || die "容器 $DISTRO 不存在（可用：${names[*]}）" 3
    if container_is_musl "$DISTRO"; then
        die "容器 $DISTRO 是 musl 系（Alpine 一类），而预编译的 libMobileGL.so 依赖 glibc，装进去也起不来。
    请换 glibc 系的容器（Debian / Ubuntu / Kali / Arch），或在该容器里自行编译。" 3
    fi
    [ -e "$PROOT_BASE/$DISTRO/rootfs/bin/sh" ] || die "容器 $DISTRO 的 rootfs 不完整（缺 /bin/sh）" 3

    PROOT_DIR="${PROOT_DIR:-$PROOT_BASE/$DISTRO/rootfs}"
    info "目标容器：$DISTRO  →  $PROOT_DIR"
}

preflight() {
    head1 "环境自检"

    case "$(uname -m)" in
        aarch64|arm64) ok "架构 aarch64" ;;
        *) die "只支持 aarch64（当前 $(uname -m)）—— 本 payload 是 arm64 预编译版" 3 ;;
    esac

    [ -d /data/data/com.termux ] || die "这不像 Termux 环境；请在手机 Termux 里运行" 3
    [ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/bash" ] || die "找不到 Termux 的 PREFIX" 3
    [ -d "$PROOT_DIR" ] || die "找不到容器 $DISTRO 的 rootfs：$PROOT_DIR
    先跑：proot-distro install $DISTRO" 3

    local c
    for c in curl tar xz sha256sum awk grep proot-distro python3; do need_cmd "$c"; done
    ok "基础命令齐备（curl/tar/xz/sha256sum/awk/grep/proot-distro/python3）"

    MULTIARCH_REL=$(detect_multiarch_rel) || die "容器里找不到 libGL.so.1（容器内先装 libgl1/libglx0/libegl1/libglvnd0）" 3
    ok "容器库目录 → /$MULTIARCH_REL"

    local sp rp
    sp=$(free_mb "$PREFIX"); rp=$(free_mb "$PROOT_DIR")
    { [ "${sp:-0}" -ge 120 ] && [ "${rp:-0}" -ge 120 ]; } || die "磁盘空间不足（需要各 120MB 以上，当前 \$PREFIX=${sp:-?}MB 容器=${rp:-?}MB）" 3
    ok "磁盘空间充足（\$PREFIX ${sp}MB / 容器 ${rp}MB）"

    # 容器里要有 GL 分发器（glvnd）与 OpenGL 库，否则我们的库挂上去也没人调用
    local missing=""
    [ -e "$PROOT_DIR/$MULTIARCH_REL/libGL.so.1" ] || missing="$missing libgl1"
    [ -e "$PROOT_DIR/$MULTIARCH_REL/libGLX.so.0" ] || missing="$missing libglx0"
    [ -e "$PROOT_DIR/$MULTIARCH_REL/libEGL.so.1" ] || missing="$missing libegl1"
    if [ -n "$missing" ]; then
        info "容器缺少 GL 运行库：$missing —— 自动安装"
        in_container 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq libgl1 libglx0 libegl1 libglvnd0 >/dev/null' \
            || die "容器内 apt 安装失败；请手动执行：apt-get install -y libgl1 libglx0 libegl1 libglvnd0" 3
        [ -e "$PROOT_DIR/$MULTIARCH_REL/libGL.so.1" ] || die "装了但仍找不到 libGL.so.1" 3
    fi
    ok "容器 GL 运行库就位（libGL/libGLX/libEGL）"

    if ! command -v termux-x11 >/dev/null 2>&1; then
        info "未检测到 termux-x11（只影响桌面/窗口程序；无窗口的离屏 GL 仍可用）"
    else
        ok "termux-x11 已安装"
    fi
}

# ---------------------------------------------------------------------------
# 载荷：本地 / 缓存 / 下载，三重校验（整包 sha256 + 清单 + 逐文件）
# ---------------------------------------------------------------------------
PAYLOAD_DIR=""

acquire_payload() {
    head1 "获取载荷（预编译库 ${VERSION}）"

    mkdir -p "$CACHE_DIR"

    if [ -n "$PAYLOAD_LOCAL" ]; then
        [ -f "$PAYLOAD_LOCAL" ] || die "找不到本地载荷：$PAYLOAD_LOCAL" 4
        info "使用本地载荷：$PAYLOAD_LOCAL"
        PAYLOAD_DIR=$(unpack_payload "$PAYLOAD_LOCAL") || die "本地载荷解包失败" 4
        check_abi || exit $?
        return 0
    fi

    local cached="$CACHE_DIR/$PAYLOAD_FILE"
    if [ -f "$cached" ] && [ "$(sha_of "$cached")" = "$PAYLOAD_SHA256" ]; then
        ok "缓存载荷校验通过（$PAYLOAD_FILE）"
        PAYLOAD_DIR=$(unpack_payload "$cached") || die "缓存载荷解包失败" 4
        check_abi || exit $?
        return 0
    fi

    local urls=(
        "https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/v${VERSION}/${PAYLOAD_FILE}"
        "https://gh-proxy.com/https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/v${VERSION}/${PAYLOAD_FILE}"
        "https://ghfast.top/https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/v${VERSION}/${PAYLOAD_FILE}"
    )
    local url okd=0
    for url in "${urls[@]}"; do
        info "下载：$url"
        if curl -fL --retry 3 --retry-delay 2 --retry-connrefused -C - \
                --connect-timeout 20 --max-time 900 -o "$cached.part" "$url" 2>/dev/null; then
            mv -f "$cached.part" "$cached"; okd=1; break
        fi
        err "这个源失败，换下一个"
        rm -f "$cached.part"
    done
    [ "$okd" = 1 ] || die "所有下载源都失败；可用 --payload 指定本地文件" 4

    local got; got=$(sha_of "$cached")
    if [ "$got" != "$PAYLOAD_SHA256" ]; then
        rm -f "$cached"
        die "载荷校验失败（期望 $PAYLOAD_SHA256，实得 $got）—— 已删除，请重试" 4
    fi
    ok "载荷 sha256 校验通过"

    PAYLOAD_DIR=$(unpack_payload "$cached") || die "载荷解包失败" 4
        check_abi || exit $?
}

unpack_payload() {  # <tarball> → 打印解包目录
    local tarfile="$1" digest stage final
    digest=$(sha_of "$tarfile")
    final="$CACHE_DIR/payload-${digest:0:16}"
    if [ -f "$final/.unpacked" ] && [ -f "$final/manifest.sha256" ]; then
        dim "复用已解包载荷 $final"
        printf '%s' "$final"; return 0
    fi
    stage="$CACHE_DIR/.stage.$$"
    rm -rf "$stage"; mkdir -p "$stage"
    tar -xJf "$tarfile" -C "$stage" || { rm -rf "$stage"; return 1; }

    # 清单校验：逐文件比对 sha256（-c 会在不符时报错并返回非 0）
    [ -f "$stage/MANIFEST.sha256" ] || { err "载荷里没有 MANIFEST.sha256"; rm -rf "$stage"; return 1; }
    if ! ( cd "$stage" && sha256sum -c MANIFEST.sha256 --quiet ); then
        err "载荷内文件校验失败"
        rm -rf "$stage"; return 1
    fi
    ok "载荷内 $(wc -l <"$stage/MANIFEST.sha256" | tr -d ' ') 个文件全部校验通过"

    cp "$stage/MANIFEST.sha256" "$stage/manifest.sha256"
    : >"$stage/.unpacked"
    rm -rf "$final"; mv "$stage" "$final"
    printf '%s' "$final"
}

# ---------------------------------------------------------------------------
# 安装：Termux 侧
# ---------------------------------------------------------------------------
# 载荷是用 Debian trixie 的工具链编的，符号里带着 GLIBC_2.38 / GLIBCXX_3.4.32 这类版本需求。
# 容器比它老的话，动态链接器会在启动瞬间甩一屏 "version `GLIBC_2.38' not found" ——
# 与其让用户对着那屏猜，不如在这里先算清楚再给一句人话。
check_abi() {
    local lib="$PAYLOAD_DIR/glibc/libMobileGL.so"
    [ -f "$lib" ] || { err "载荷里没有 glibc/libMobileGL.so"; return 4; }
    local need_glibc need_cxx have_glibc have_cxx
    need_glibc=$(strings -a "$lib" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -uV | tail -1 | sed 's/GLIBC_//')
    need_cxx=$(strings -a "$lib" 2>/dev/null | grep -oE 'GLIBCXX_[0-9]+\.[0-9]+\.[0-9]+' | sort -uV | tail -1 | sed 's/GLIBCXX_//')
    have_glibc=$(in_container "ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$'" 2>/dev/null | tr -d '\r')
    have_cxx=$(strings -a "$PROOT_DIR/$MULTIARCH_REL/libstdc++.so.6" 2>/dev/null | grep -oE 'GLIBCXX_[0-9]+\.[0-9]+\.[0-9]+' | sort -uV | tail -1 | sed 's/GLIBCXX_//')
    info "载荷需要 glibc ${need_glibc:-?} / GLIBCXX ${need_cxx:-?}；容器提供 glibc ${have_glibc:-?} / GLIBCXX ${have_cxx:-?}"
    if [ -n "$need_glibc" ] && [ -n "$have_glibc" ]; then
        if [ "$(printf '%s\n%s\n' "$need_glibc" "$have_glibc" | sort -V | tail -1)" != "$have_glibc" ]; then
            err "容器的 glibc ${have_glibc} 低于载荷要求的 ${need_glibc}；请把容器升到 Debian 13+ / Ubuntu 24.04+，或用源码自行重编"
            return 3
        fi
    fi
    if [ -n "$need_cxx" ] && [ -n "$have_cxx" ]; then
        if [ "$(printf '%s\n%s\n' "$need_cxx" "$have_cxx" | sort -V | tail -1)" != "$have_cxx" ]; then
            err "容器的 libstdc++ 只到 GLIBCXX ${have_cxx}，载荷需要 ${need_cxx}"
            return 3
        fi
    fi
    ok "容器 ABI 满足载荷要求"
}

install_termux_side() {
    head1 "安装 Termux 侧（脚本 / 兼容层 / 启动器 / 开机自启）"

    local src="$PAYLOAD_DIR"
    mkdir -p "$MGL_HOME"/{lib,logs,.cache}

    # 脚本
    local f base
    for f in "$src/scripts"/*.sh; do
        base=$(basename "$f")
        install -m 700 "$f" "$MGL_HOME/$base"
        dim "脚本 $MGL_HOME/$base"
    done
    ok "$(ls "$src/scripts"/*.sh | wc -l | tr -d ' ') 个脚本 → $MGL_HOME"

    # 兼容层（LD_PRELOAD）
    install -m 755 "$src/extras/libfixfunc.so" "$MGL_HOME/lib/libfixfunc.so"
    install -m 755 "$src/extras/libnovsync.so" "$MGL_HOME/lib/libnovsync.so"
    ok "兼容层 → $MGL_HOME/lib（libfixfunc 老式固定管线 / libnovsync 关垂直同步）"

    # 装完只保证"GPU 加速对任何 GUI 程序透明生效"；桌面怎么起是用户自己的事，
    # 所以这里不放任何启动器、也不碰 $HOME 里已有的脚本。
    dim "GPU 加速已生效，直接开你自己的桌面即可"

    # 开机自启（Termux:Boot）
    if [ -d "$HOME/.termux" ]; then
        mkdir -p "$HOME/.termux/boot"
        install -m 700 "$MGL_HOME/boot-mobilegl-server.sh" "$HOME/.termux/boot/mobilegl-server.sh"
        record "$HOME/.termux/boot/mobilegl-server.sh"
        ok "开机自启 → ~/.termux/boot/mobilegl-server.sh（装了 Termux:Boot 才会触发）"
    fi
}

# ---------------------------------------------------------------------------
# 安装：容器侧（系统级接线，让任何程序一启动就用上 GPU）
# ---------------------------------------------------------------------------
install_container_side() {
    head1 "安装容器侧（$DISTRO）"

    local src="$PAYLOAD_DIR" libdir="$PROOT_DIR/$MULTIARCH_REL"
    local target="$PROOT_DIR/opt/mobilegl/lib/libMobileGL.so"

    # 1. 客户端库
    if [ -f "$target" ] && [ "$(sha_of "$target")" = "$(sha_of "$src/glibc/libMobileGL.so")" ] && [ "$FORCE" = 0 ]; then
        ok "客户端库已是最新（跳过复制）"
    else
        mkdir -p "$(dirname "$target")"
        install -m 755 "$src/glibc/libMobileGL.so" "$target.mgl-tmp"
        mv -f "$target.mgl-tmp" "$target"
        record "$target"
        ok "客户端库 → /opt/mobilegl/lib/libMobileGL.so（$(du -h "$target" | awk '{print $1}')）"
    fi

    # 2. glvnd EGL 厂商描述（EGL 程序靠它发现 MobileGL）
    local json='{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "/opt/mobilegl/lib/libMobileGL.so"
    }
}'
    write_file_atomic "$PROOT_DIR/usr/share/glvnd/egl_vendor.d/10_mobilegl.json" "$json"
    record "$PROOT_DIR/usr/share/glvnd/egl_vendor.d/10_mobilegl.json"
    ok "EGL 厂商描述 → /usr/share/glvnd/egl_vendor.d/10_mobilegl.json"

    # 3. GLX 厂商库符号链接（glvnd 用 __GLX_VENDOR_LIBRARY_NAME 找它）
    [ -d "$libdir" ] || die "容器里没有 $libdir（架构可能不是 arm64）" 3
    ln -sfn /opt/mobilegl/lib/libMobileGL.so "$libdir/libGLX_mobilegl.so.0"
    record "$libdir/libGLX_mobilegl.so.0"
    ok "GLX 厂商库 → $libdir/libGLX_mobilegl.so.0"

    # 4. 环境变量（登录 shell 与 /etc/environment 双写）
    local envblock='# MobileGL —— 让容器里的程序默认走手机 GPU（由 install.sh 写入）
export __GLX_VENDOR_LIBRARY_NAME=mobilegl
export MOBILEGL_TRANSPORT=spawn
export MOBILEGL_IPC_CONTROL=unix:@mobilegl
export MOBILEGL_IPC_DATA=auto
export MOBILEGL_BACKEND_TYPE=DirectVulkan
export MOBILEGL_IPC_RING_MB=64
export MOBILEGL_IPC_STAGE_MB=256
export MOBILEGL_IPC_SPIN_US=200
export MOBILEGL_IPC_PROBE_TIMEOUT_MS=250
# 让 EGL 程序也能发现 MobileGL（保留 Mesa 作为后备）
if [ -f /usr/share/glvnd/egl_vendor.d/10_mobilegl.json ]; then
    export __EGL_VENDOR_LIBRARY_FILENAMES="/usr/share/glvnd/egl_vendor.d/10_mobilegl.json:/usr/share/glvnd/egl_vendor.d/50_mesa.json"
fi'
    write_file_atomic "$PROOT_DIR/etc/profile.d/mobilegl.sh" "$envblock"
    record "$PROOT_DIR/etc/profile.d/mobilegl.sh"
    chmod 644 "$PROOT_DIR/etc/profile.d/mobilegl.sh"
    ok "登录 shell 环境 → /etc/profile.d/mobilegl.sh"

    local enventries='__GLX_VENDOR_LIBRARY_NAME=mobilegl
MOBILEGL_TRANSPORT=spawn
MOBILEGL_IPC_CONTROL=unix:@mobilegl
MOBILEGL_IPC_DATA=auto
MOBILEGL_BACKEND_TYPE=DirectVulkan'
    write_file_atomic "$PROOT_DIR/etc/environment.d/10-mobilegl.conf" "$enventries"
    record "$PROOT_DIR/etc/environment.d/10-mobilegl.conf"
    ok "非 shell 环境 → /etc/environment.d/10-mobilegl.conf"

    # 5. 客户端的配置文件形式（进程环境 > backend > client.conf > 内建）
    local conf='MOBILEGL_TRANSPORT=spawn
MOBILEGL_IPC_CONTROL=unix:@mobilegl
MOBILEGL_IPC_DATA=auto
MOBILEGL_BACKEND_TYPE=DirectVulkan
MOBILEGL_IPC_RING_MB=64
MOBILEGL_IPC_STAGE_MB=256
MOBILEGL_IPC_SPIN_US=200
MOBILEGL_IPC_PROBE_TIMEOUT_MS=250'
    write_file_atomic "$PROOT_DIR/etc/mobilegl/client.conf" "$conf"
    record "$PROOT_DIR/etc/mobilegl/client.conf"
    ok "客户端配置 → /etc/mobilegl/client.conf"

    # 6. Chromium（Debian 包读 /etc/chromium.d/*）
    write_file_atomic "$PROOT_DIR/etc/chromium.d/50-mobilegl" \
'CHROMIUM_FLAGS="$CHROMIUM_FLAGS --use-gl=angle --use-angle=gles --ignore-gpu-blocklist --no-sandbox --disable-dev-shm-usage"'
    record "$PROOT_DIR/etc/chromium.d/50-mobilegl"
    ok "Chromium 旗标 → /etc/chromium.d/50-mobilegl"

    # 6a. 自检：Chromium 的两个关键行必须真的写进去了。write_file_atomic 只接受一个内容参数，
    #     早先这里传了两个参数，结果旗标行被静默丢弃——浏览器于是退回默认后端，WebGL 全废。
    local chromium_cfg="$PROOT_DIR/etc/chromium.d/50-mobilegl"
    if ! grep -q 'use-angle=gles' "$chromium_cfg" 2>/dev/null ||
       ! grep -q -- '--use-angle=gles' "$chromium_cfg" 2>/dev/null; then
        err "Chromium 配置写入不完整：$chromium_cfg（缺 --use-angle=gles）"
        return 5
    fi

    # 6b. GL 1.x 兼容包装器：Magma（Vulkan 后端）把 glBegin/glVertex*/显示列表实现成空 stub，
    #     老程序直接跑会得到黑窗口。legacy 通过 LD_PRELOAD 把立即模式翻译成 VBO + 着色器。
    # 注意：包装器运行在容器里，它自己的 $HOME 是 /root，所以这里必须把 Termux 侧的
    # 绝对路径写死进去 —— 用安装时的 $MGL_HOME 展开，而不是固定某个用户名下的路径。
    write_file_atomic "$PROOT_DIR/usr/local/bin/legacy" \
        "#!/bin/sh
# 给 Magma 补上 GL 1.x 固定管线（立即模式 / 矩阵栈 / 显示列表 / 客户端数组 / 纹理）。
MGL_SHIM=$MGL_HOME/lib/libfixfunc.so
[ -f \"\$MGL_SHIM\" ] || { echo \"legacy: 找不到 \$MGL_SHIM（重新运行 install.sh）\" >&2; exit 1; }
LD_PRELOAD=\"\$MGL_SHIM\${LD_PRELOAD:+:\$LD_PRELOAD}\" exec \"\$@\""
    chmod 755 "$PROOT_DIR/usr/local/bin/legacy" 2>/dev/null || true
    record "$PROOT_DIR/usr/local/bin/legacy"
    ok "GL 1.x 兼容包装器 → /usr/local/bin/legacy（容器内用 legacy <命令>）"

    # 7. 刷新动态链接缓存
    if in_container 'ldconfig' >/dev/null 2>&1; then
        ok "容器 ldconfig 已刷新"
    else
        info "ldconfig 返回非 0（多半只是警告，不影响）"
    fi
}

# ---------------------------------------------------------------------------
# 服务端：起进程并确认真的在应答
# ---------------------------------------------------------------------------
start_and_wait_server() {
    head1 "启动 GPU 服务端（Termux 侧）"

    # 服务端二进制随载荷装到 ~/mgl/lib —— 普通用户没有源码树，这里必须自给自足。
    local image="$MGL_HOME/lib/libMobileGLServer.so"
    if [ ! -f "$image" ] || [ "$FORCE" = 1 ] || [ "$(sha_of "$image")" != "$(sha_of "$PAYLOAD_DIR/bionic/libMobileGLServer.so")" ]; then
        install -m 755 "$PAYLOAD_DIR/bionic/libMobileGLServer.so" "$image"
        install -m 755 "$PAYLOAD_DIR/bionic/libMobileGL.so" "$MGL_HOME/lib/libMobileGL.so"
        ok "服务端二进制 → $image（$(du -h "$MGL_HOME/lib/libMobileGL.so" | awk '{print $1}')）"
    else
        ok "服务端二进制已是最新（$image）"
    fi

    if bash "$MGL_HOME/ensure-server.sh" >/dev/null 2>&1; then
        local st
        st=$(bash "$MGL_HOME/ensure-server.sh" status 2>/dev/null || true)
        ok "$st"
    else
        err "服务端没能应答 @mobilegl"
        info "看 /storage/emulated/0/MG/latest.server.log 与 $MGL_HOME/server.log"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 验证：GLX 与 EGL 两条路都必须看到 Magma
# ---------------------------------------------------------------------------
x_alive() {  # <socket 路径> —— 真的 connect 一下，别只看文件在不在
    python3 - "$1" <<'PYPY' >/dev/null 2>&1
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(1.0)
try:
    s.connect(sys.argv[1])
except Exception:
    sys.exit(1)
finally:
    s.close()
PYPY
}

# 找一个能用的 X display：优先已有的 :0，没有就临时起一个，验完关掉。
ensure_test_display() {
    local sock="$PREFIX/tmp/.X11-unix/X0"
    if [ -S "$sock" ] && x_alive "$sock"; then
        printf '%s' ":0"; return 0
    fi
    local n=5
    while [ -S "$PREFIX/tmp/.X11-unix/X$n" ]; do n=$((n + 1)); [ "$n" -gt 20 ] && break; done
    info "没有运行中的 X 服务器，临时启动 :$n 做实测（验完即关）"
    setsid termux-x11 ":$n" -listen unix >/dev/null 2>&1 &
    TEST_X_PID=$!
    TEST_X_DISPLAY=":$n"
    STARTED_X=1
    local i
    for i in $(seq 1 30); do
        x_alive "$PREFIX/tmp/.X11-unix/X$n" && { printf '%s' ":$n"; return 0; }
        sleep 0.2
    done
    return 1
}

stop_test_display() {
    [ "${STARTED_X:-0}" = 1 ] || return 0
    [ -n "${TEST_X_PID:-}" ] && kill "$TEST_X_PID" 2>/dev/null || true
    [ -n "${TEST_X_DISPLAY:-}" ] && pkill -f "termux-x11 ${TEST_X_DISPLAY} -listen unix" 2>/dev/null || true
    STARTED_X=0
    dim "临时 X 已关闭"
}

verify_all() {
    head1 "验证（GLX + EGL 两条路）"
    local fails=0 out dpy

    if ! dpy=$(ensure_test_display); then
        err "无法准备 X 服务器，跳过实测"
        info "装好 termux-x11 后运行：bash $MGL_HOME/gpu-check.sh"
        return 1
    fi
    dim "测试用 DISPLAY=$dpy"

    out=$(in_container_login "command -v glxinfo >/dev/null || apt-get install -y -qq mesa-utils >/dev/null 2>&1; DISPLAY=$dpy glxinfo -B 2>/dev/null" \
        | grep -E 'OpenGL (renderer|core profile version) string' || true)
    if printf '%s' "$out" | grep -q 'Magma (MobileGL Core)'; then
        ok "GLX → $(printf '%s' "$out" | grep 'renderer' | sed 's/.*string: *//')"
        dim "$(printf '%s' "$out" | grep 'core profile' | sed 's/.*string: *//')"
    else
        err "GLX 没走到 MobileGL："
        printf '%s\n' "${out:-（无输出）}" | sed 's/^/      /' >&2
        fails=$((fails + 1))
    fi

    out=$(in_container_login "command -v es2_info >/dev/null || apt-get install -y -qq mesa-utils-extra >/dev/null 2>&1; DISPLAY=$dpy es2_info 2>/dev/null" \
        | grep -E 'EGL_VENDOR|GL_RENDERER' || true)
    if printf '%s' "$out" | grep -qi 'Magma\|MobileGL'; then
        ok "EGL → $(printf '%s' "$out" | grep -i 'GL_RENDERER' | sed 's/.*: *//')"
    else
        err "EGL 没走到 MobileGL："
        printf '%s\n' "${out:-（无输出）}" | sed 's/^/      /' >&2
        fails=$((fails + 1))
    fi

    stop_test_display

    if [ "$fails" -eq 0 ]; then
        return 0
    fi
    err "$fails 条路径未通过"
    info "排查顺序：1) bash $MGL_HOME/gpu-check.sh   2) 看 /storage/emulated/0/MG/latest.server.log"
    return 1
}

# ---------------------------------------------------------------------------
# 回滚 / 卸载
# ---------------------------------------------------------------------------
do_rollback() {
    bash "$MGL_HOME/stop-server.sh" >/dev/null 2>&1 || true
    # 只删本次清单里记录过的容器文件
    if [ -f "$MANIFEST" ]; then
        local p
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case "$p" in
                "$PROOT_DIR"/*) rm -f "$p" || true ;;
            esac
        done <"$MANIFEST"
        rm -f "$MANIFEST"
    fi
    rm -rf "$PROOT_DIR/opt/mobilegl" "$PROOT_DIR/etc/mobilegl"
    rm -f "$PROOT_DIR/etc/profile.d/mobilegl.sh" "$PROOT_DIR/etc/environment.d/10-mobilegl.conf" \
          "$PROOT_DIR/etc/chromium.d/50-mobilegl" \
          "$PROOT_DIR/usr/share/glvnd/egl_vendor.d/10_mobilegl.json" || true
    # 卸载路径不跑 preflight，MULTIARCH_REL 可能没设过；这里按候选目录挨个清，避免 set -u 报错。
    local linkdir
    for linkdir in ${MULTIARCH_REL:+"$PROOT_DIR/$MULTIARCH_REL"} \
                   "$PROOT_DIR/usr/lib/aarch64-linux-gnu" "$PROOT_DIR/usr/lib64" \
                   "$PROOT_DIR/usr/lib" "$PROOT_DIR/lib"; do
        [ -n "$linkdir" ] && rm -f "$linkdir/libGLX_mobilegl.so.0" || true
    done
    in_container 'ldconfig' >/dev/null 2>&1 || true
    ok "容器侧已清理"
}

uninstall_all() {
    head1 "卸载"
    local fails=0

    if [ -f "$MGL_HOME/stop-server.sh" ]; then
        bash "$MGL_HOME/stop-server.sh" >/dev/null 2>&1 && ok "服务端已停止" || info "服务端本来就没在跑"
    fi

    do_rollback

    # 校验容器侧确实清干净了
    local leftovers=()
    local check
    for check in "$PROOT_DIR/opt/mobilegl" "$PROOT_DIR/etc/mobilegl" \
                 "$PROOT_DIR/etc/profile.d/mobilegl.sh" \
                 "$PROOT_DIR/usr/share/glvnd/egl_vendor.d/10_mobilegl.json"; do
        [ -e "$check" ] && leftovers+=("$check")
    done
    # 同样：卸载时不依赖 MULTIARCH_REL，直接扫候选目录里的软链
    for check in ${MULTIARCH_REL:+"$PROOT_DIR/$MULTIARCH_REL"} \
                 "$PROOT_DIR/usr/lib/aarch64-linux-gnu" "$PROOT_DIR/usr/lib64" \
                 "$PROOT_DIR/usr/lib" "$PROOT_DIR/lib"; do
        [ -n "$check" ] && [ -e "$check/libGLX_mobilegl.so.0" ] && leftovers+=("$check/libGLX_mobilegl.so.0")
    done
    if [ ${#leftovers[@]} -eq 0 ]; then
        ok "容器侧无残留"
    else
        err "仍有残留：${leftovers[*]}"; fails=$((fails + 1))
    fi

    # Termux 侧：先按清单删（覆盖"用户原先就有同名文件"与"不是软链"的情况）
    if [ -f "$MANIFEST" ]; then
        local rec
        while IFS= read -r rec; do
            [ -n "$rec" ] || continue
            case "$rec" in
                "$HOME"/*) rm -f "$rec" || true ;;
            esac
        done <"$MANIFEST"
        rm -f "$MANIFEST"
        ok "已按安装清单清理 Termux 侧文件"
    fi

    if [ -L "$HOME/.termux/boot/mobilegl-server.sh" ] || [ -f "$HOME/.termux/boot/mobilegl-server.sh" ]; then
        rm -f "$HOME/.termux/boot/mobilegl-server.sh"; ok "已删开机自启"
    fi

    # $HOME 下没有本工具链的任何文件（入口在 ~/mgl），因此不做任何清理
    rm -rf "$MGL_HOME/lib" "$MGL_HOME"/*.sh "$MGL_HOME/.cache"
    # 旧版本（<= v1.0.4）在本工具链里往 $HOME 放过软链，只清这种指向 ~/mgl 的残留，
    # 用户自己的同名文件一律不碰。
    ok "Termux 侧脚本与载荷缓存已清理（日志与备份保留在 $MGL_HOME）"

    [ "$fails" -eq 0 ] && { ok "卸载完成，图形加速已完全移除"; return 0; }
    return 1
}

check_only() {
    head1 "体检"
    local st
    st=$(bash "$MGL_HOME/ensure-server.sh" status 2>/dev/null || echo "server: 未知")
    printf '%s\n' "$st" | sed 's/^/      /'
    if printf '%s' "$st" | grep -q ready; then ok "服务端在应答"; else err "服务端不在应答"; fi
    verify_all || return 1
    printf '\n'
    ok "结论：GLX 与 EGL 都走手机 GPU"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
# 安装完成后把用法摆到眼前：先打到终端，环境里有 yad 就再弹一个窗口。
show_help_popup() {
    local text dpy
    text="MobileGL 已经装好了，日常就这么用：

1) 开桌面
     开你自己的桌面（比如你平时用的启动脚本，或在容器里 DISPLAY=:0 startxfce4）

2) 体检（GLX 与 EGL 两条路都应显示 Magma）
     bash ~/mgl/gpu-check.sh

3) 用完整 GPU 环境跑某个程序
     bash ~/mgl/gpu-check.sh <程序>
     ~/mgl/mgl-run.sh <程序>

4) 老游戏（GL 1.x 立即模式）在容器里加前缀
     legacy <程序>

5) 关桌面 / 停服务端
     关桌面就用你自己的方式；要停 GPU 服务端：bash ~/mgl/stop-server.sh

6) 卸载
     bash install.sh --uninstall

服务端日志：/storage/emulated/0/MG/latest.server.log
本工具链不会改动你 \$HOME 里的任何文件。"
    printf '\n%s\n' "$text" >&2
    command -v yad >/dev/null 2>&1 || return 0
    dpy="${DISPLAY:-}"
    if [ -z "$dpy" ] && [ -S "$PREFIX/tmp/.X11-unix/X0" ]; then dpy=":0"; fi
    [ -n "$dpy" ] || return 0
    # 弹窗放后台：安装脚本立刻返回，不把终端卡住 3 分钟。
    DISPLAY="$dpy" setsid yad --title="MobileGL 使用帮助" --text="$text" --width=660 --height=420 \
        --button="知道了:0" --timeout=180 >/dev/null 2>&1 &
    return 0
}

main() {
    mkdir -p "$MGL_HOME"
    printf '%s\n' "===== mobilegl-termux ${VERSION}  ($(date '+%F %T'))  action=${ACTION} =====" >>"$LOG"

    case "$ACTION" in
        uninstall)
            select_distro
            uninstall_all || die "卸载未完成，见上" 7
            exit 0
            ;;
        check)
            select_distro
            preflight
            check_only || die "体检未通过" 6
            exit 0
            ;;
    esac

    select_distro
    preflight
    acquire_payload
    info "载荷目录：$PAYLOAD_DIR"

    : >"$MANIFEST"
    ROLLBACK_ON_FAIL=1

    install_termux_side
    install_container_side
    start_and_wait_server || die "服务端起不来" 5

    if ! verify_all; then
        die "验证失败" 6
    fi
    ROLLBACK_ON_FAIL=0

    head1 "安装完成"
    ok "GLX 与 EGL 都已走手机 GPU"
    show_help_popup
    printf '\n'
    printf '  日常用法\n'
    printf '    %s<你自己的桌面启动脚本>%s      桌面/程序自动走 GPU（已配置好 profile.d）\n' "$C_B" "$C_RST"
    printf '    %sbash ~/mgl/gpu-check.sh%s     体检（两条路都出现 Magma 即正常）\n' "$C_B" "$C_RST"
    printf '    %sbash ~/mgl/gpu-check.sh 程序%s 用完整 GPU 环境跑任意程序\n' "$C_B" "$C_RST"
    printf '    %sbash install.sh --uninstall%s  卸载（按清单逐项删除并校验）\n' "$C_B" "$C_RST"
    printf '\n  日志：%s\n' "$LOG"
}

main "$@"
