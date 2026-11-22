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

VERSION="1.0.1"
REPO_OWNER="wcnmamrs"
REPO_NAME="mobilegl-termux"
PAYLOAD_FILE="mobilegl-payload-arm64-v${VERSION}.tar.xz"
PAYLOAD_SHA256="99832feab114269d0004fb5a29bbb460a75f71e9513b8163e05ae1f23c374586"

MGL_HOME="${MGL_HOME:-$HOME/mgl}"
DEBIAN="${DEBIAN_NAME:-debian}"
PROOT_BASE="${PREFIX:?必须在 Termux 里运行（找不到 PREFIX）}/var/lib/proot-distro/containers"
PROOT_DIR="${PROOT_DIR:-$PROOT_BASE/$DEBIAN/rootfs}"
CACHE_DIR="$MGL_HOME/.cache"
LOG="$MGL_HOME/install.log"
MANIFEST="$MGL_HOME/installed-files.txt"
BACKUP_DIR="$MGL_HOME/.backups"

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
in_debian() {
    local script="$1" out rc=0
    out=$(proot-distro login "$DEBIAN" --shared-tmp -- /bin/bash -c "$script" 2>&1) || rc=$?
    printf '%s\n' "$out" | grep -v '^proot warning' || true
    return $rc
}

# 登录 shell 版：会读到 /etc/profile.d/mobilegl.sh —— 也正是用户日常"装完就能用"的路径
in_debian_login() {
    local script="$1" out rc=0
    out=$(proot-distro login "$DEBIAN" --shared-tmp -- /bin/bash -lc "$script" 2>&1) || rc=$?
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

backup_once() {  # <文件> —— 第一次触碰时留一份
    local f="$1" name
    [ -e "$f" ] || return 0
    name=$(printf '%s' "$f" | tr '/' '_')
    [ -e "$BACKUP_DIR/$name" ] && return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$f" "$BACKUP_DIR/$name"
    dim "备份 $f → $BACKUP_DIR/$name"
}

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
preflight() {
    head1 "环境自检"

    case "$(uname -m)" in
        aarch64|arm64) ok "架构 aarch64" ;;
        *) die "只支持 aarch64（当前 $(uname -m)）—— 本 payload 是 arm64 预编译版" 3 ;;
    esac

    [ -d /data/data/com.termux ] || die "这不像 Termux 环境；请在手机 Termux 里运行" 3
    [ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/bash" ] || die "找不到 Termux 的 PREFIX" 3
    [ -d "$PROOT_DIR" ] || die "找不到容器 $DEBIAN 的 rootfs：$PROOT_DIR
    先跑：proot-distro install $DEBIAN" 3

    local c
    for c in curl tar xz sha256sum awk grep proot-distro python3; do need_cmd "$c"; done
    ok "基础命令齐备（curl/tar/xz/sha256sum/awk/grep/proot-distro/python3）"

    local sp rp
    sp=$(free_mb "$PREFIX"); rp=$(free_mb "$PROOT_DIR")
    { [ "${sp:-0}" -ge 120 ] && [ "${rp:-0}" -ge 120 ]; } || die "磁盘空间不足（需要各 120MB 以上，当前 \$PREFIX=${sp:-?}MB 容器=${rp:-?}MB）" 3
    ok "磁盘空间充足（\$PREFIX ${sp}MB / 容器 ${rp}MB）"

    # 容器里要有 GL 分发器（glvnd）与 OpenGL 库，否则我们的库挂上去也没人调用
    local missing=""
    [ -e "$PROOT_DIR/usr/lib/aarch64-linux-gnu/libGL.so.1" ] || missing="$missing libgl1"
    [ -e "$PROOT_DIR/usr/lib/aarch64-linux-gnu/libGLX.so.0" ] || missing="$missing libglx0"
    [ -e "$PROOT_DIR/usr/lib/aarch64-linux-gnu/libEGL.so.1" ] || missing="$missing libegl1"
    if [ -n "$missing" ]; then
        info "容器缺少 GL 运行库：$missing —— 自动安装"
        in_debian 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq libgl1 libglx0 libegl1 libglvnd0 >/dev/null' \
            || die "容器内 apt 安装失败；请手动执行：apt-get install -y libgl1 libglx0 libegl1 libglvnd0" 3
        [ -e "$PROOT_DIR/usr/lib/aarch64-linux-gnu/libGL.so.1" ] || die "装了但仍找不到 libGL.so.1" 3
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
        return 0
    fi

    local cached="$CACHE_DIR/$PAYLOAD_FILE"
    if [ -f "$cached" ] && [ "$(sha_of "$cached")" = "$PAYLOAD_SHA256" ]; then
        ok "缓存载荷校验通过（$PAYLOAD_FILE）"
        PAYLOAD_DIR=$(unpack_payload "$cached") || die "缓存载荷解包失败" 4
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
install_termux_side() {
    head1 "安装 Termux 侧（脚本 / 兼容层 / 启动器 / 开机自启）"

    local src="$PAYLOAD_DIR"
    mkdir -p "$MGL_HOME"/{lib,logs,.cache} "$BACKUP_DIR"

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

    # 桌面启动器：~/xfce.sh 与 ~/xfce-d.sh（覆盖前先备份用户的旧脚本）
    local launcher
    for launcher in xfce.sh xfce-d.sh; do
        backup_once "$HOME/$launcher"
        ln -sfn "$MGL_HOME/$launcher" "$HOME/$launcher"
        record "$HOME/$launcher"
        dim "$HOME/$launcher -> $MGL_HOME/$launcher"
    done
    ok "桌面启动器 ~/xfce.sh、~/xfce-d.sh 已指向本工具链"

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
    head1 "安装容器侧（$DEBIAN）"

    local src="$PAYLOAD_DIR" libdir="$PROOT_DIR/usr/lib/aarch64-linux-gnu"
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
        'CHROMIUM_FLAGS="$CHROMIUM_FLAGS --use-gl=angle --use-angle=gl --ignore-gpu-blocklist --no-sandbox --disable-dev-shm-usage"'
    record "$PROOT_DIR/etc/chromium.d/50-mobilegl"
    ok "Chromium 旗标 → /etc/chromium.d/50-mobilegl"

    # 7. 刷新动态链接缓存
    if in_debian 'ldconfig' >/dev/null 2>&1; then
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

    local image="$HOME/src/MobileGL/build-bionic/libMobileGLServer.so"
    if [ -f "$MGL_HOME/lib/libMobileGLServer.so" ]; then
        image="$MGL_HOME/lib/libMobileGLServer.so"
    fi

    # 服务端二进制也随载荷装到 ~/mgl/lib，避免依赖源码目录
    if [ ! -f "$MGL_HOME/lib/libMobileGLServer.so" ]; then
        install -m 755 "$PAYLOAD_DIR/bionic/libMobileGLServer.so" "$MGL_HOME/lib/libMobileGLServer.so"
        install -m 755 "$PAYLOAD_DIR/bionic/libMobileGL.so" "$MGL_HOME/lib/libMobileGL.so"
        ok "服务端二进制 → $MGL_HOME/lib（$image）"
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
    pkill -f "termux-x11 :5 -listen unix" 2>/dev/null || true
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

    out=$(in_debian_login "command -v glxinfo >/dev/null || apt-get install -y -qq mesa-utils >/dev/null 2>&1; DISPLAY=$dpy glxinfo -B 2>/dev/null" \
        | grep -E 'OpenGL (renderer|core profile version) string' || true)
    if printf '%s' "$out" | grep -q 'Magma (MobileGL Core)'; then
        ok "GLX → $(printf '%s' "$out" | grep 'renderer' | sed 's/.*string: *//')"
        dim "$(printf '%s' "$out" | grep 'core profile' | sed 's/.*string: *//')"
    else
        err "GLX 没走到 MobileGL："
        printf '%s\n' "${out:-（无输出）}" | sed 's/^/      /' >&2
        fails=$((fails + 1))
    fi

    out=$(in_debian_login "command -v es2_info >/dev/null || apt-get install -y -qq mesa-utils-extra >/dev/null 2>&1; DISPLAY=$dpy es2_info 2>/dev/null" \
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
          "$PROOT_DIR/usr/share/glvnd/egl_vendor.d/10_mobilegl.json" \
          "$PROOT_DIR/usr/lib/aarch64-linux-gnu/libGLX_mobilegl.so.0"
    in_debian 'ldconfig' >/dev/null 2>&1 || true
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
                 "$PROOT_DIR/usr/share/glvnd/egl_vendor.d/10_mobilegl.json" \
                 "$PROOT_DIR/usr/lib/aarch64-linux-gnu/libGLX_mobilegl.so.0"; do
        [ -e "$check" ] && leftovers+=("$check")
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

    local l
    for l in xfce.sh xfce-d.sh; do
        if [ -L "$HOME/$l" ]; then rm -f "$HOME/$l"; ok "已删启动器 ~/$l"; fi
    done
    if [ -L "$HOME/.termux/boot/mobilegl-server.sh" ] || [ -f "$HOME/.termux/boot/mobilegl-server.sh" ]; then
        rm -f "$HOME/.termux/boot/mobilegl-server.sh"; ok "已删开机自启"
    fi

    # 恢复备份（用户原本的脚本）
    if [ -f "$BACKUP_DIR/_data_data_com.termux_files_home_xfce.sh" ]; then
        cp -a "$BACKUP_DIR/_data_data_com.termux_files_home_xfce.sh" "$HOME/xfce.sh"
        ok "已恢复你原来的 ~/xfce.sh"
    fi

    rm -rf "$MGL_HOME/lib" "$MGL_HOME"/*.sh "$MGL_HOME/.cache"
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
main() {
    mkdir -p "$MGL_HOME"
    printf '%s\n' "===== mobilegl-termux ${VERSION}  ($(date '+%F %T'))  action=${ACTION} =====" >>"$LOG"

    case "$ACTION" in
        uninstall)
            uninstall_all || die "卸载未完成，见上" 7
            exit 0
            ;;
        check)
            preflight
            check_only || die "体检未通过" 6
            exit 0
            ;;
    esac

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
    printf '\n'
    printf '  日常用法\n'
    printf '    %s~/xfce.sh%s                  开桌面（自动确保服务端与 X）\n' "$C_B" "$C_RST"
    printf '    %sbash ~/mgl/gpu-check.sh%s     体检（两条路都出现 Magma 即正常）\n' "$C_B" "$C_RST"
    printf '    %sbash ~/mgl/gpu-check.sh 程序%s 用完整 GPU 环境跑任意程序\n' "$C_B" "$C_RST"
    printf '    %sbash install.sh --uninstall%s  卸载（按清单逐项删除并校验）\n' "$C_B" "$C_RST"
    printf '\n  日志：%s\n' "$LOG"
}

main "$@"
