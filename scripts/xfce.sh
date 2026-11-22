#!/data/data/com.termux/files/usr/bin/bash

# 按名字精确杀进程：先看 /proc/<pid>/exe 的基本名，再看 /proc/<pid>/comm。
# 为什么不用 pkill -f：它匹配整条命令行，会把"命令行里恰好含有这个名字"的 shell 一起杀掉
# （实测踩到过：卸载脚本把自己的父 shell 打成 SIGKILL）。
# 为什么要看 comm：proot 里的子进程被 ptrace 盯住，从 Termux 侧 readlink /proc/<pid>/exe
# 会失败；而 termux-x11 这类 shell 包装器的 exe 是 /system/bin/sh，只有 comm 才对得上。
killeq() {
    local name="$1" p exe comm
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        exe=$(readlink "$p/exe" 2>/dev/null) && [ "$(basename "$exe")" = "$name" ] && {
            kill -9 "${p#/proc/}" 2>/dev/null || true; continue; }
        comm=$(cat "$p/comm" 2>/dev/null) || continue
        [ "$comm" = "$name" ] && kill -9 "${p#/proc/}" 2>/dev/null || true
    done
}


# ============================================
#  XFCE 桌面启动器 (中文桌面，英文音频对话框)
#  GPU 加速：MobileGL —— Magma 后端直连 Mali Vulkan (1.1.177)
#            呈现走 DRI3 + Present 零拷贝（dma-buf，无回读）
#  链路：proot(Debian) 里的 GL → libMobileGL.so → 抽象 socket @mobilegl
#        → Termux 侧常驻 libMobileGLServer.so → Mali Vulkan → dma-buf → termux-x11
# ============================================

set -u

MGL_DIR="$HOME/mgl"
MGL_SERVER="$HOME/mgl/lib"
MGL_CLIENT_IN_CONTAINER="/opt/mobilegl/lib"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

error_exit() {
    log "错误：$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error_exit "缺少命令：$1"
}

# ---------- 前置检查 ----------
log "检查依赖..."
require_cmd termux-x11
require_cmd am
require_cmd proot-distro

CLIENT_LIB_HOST="${PROOT_DIR:-$PREFIX/var/lib/proot-distro/containers/debian/rootfs}/opt/mobilegl/lib/libMobileGL.so"
[ -f "$CLIENT_LIB_HOST" ] ||
    error_exit "客户端库不存在：$CLIENT_LIB_HOST（先跑 install.sh）"
[ -x "$MGL_SERVER/libMobileGLServer.so" ] ||
    error_exit "服务端不存在：$MGL_SERVER/libMobileGLServer.so（先跑 install.sh）"
[ -x "$MGL_DIR/ensure-server.sh" ] ||
    error_exit "缺少 $MGL_DIR/ensure-server.sh"

if command -v pulseaudio >/dev/null 2>&1; then
    log "pulseaudio 可用"
else
    log "警告：pulseaudio 未安装，音频功能将不可用"
fi

# ---------- 清理旧桌面进程（不动 MobileGL 服务端） ----------
# 注意：不能调 xfce-d.sh —— 那个会把 server 一起停掉，紧接着又要拉起来。
# 容器侧的桌面进程必须从容器里杀：proot 用 ptrace 盯子进程，Termux 侧读不到它们的 exe。
kill_desktop_in_container() {
    proot-distro login debian --shared-tmp -- /bin/sh -c '
        for n in xfce4-session xfwm4 xfce4-panel xfce4-notifyd xfsettingsd xfdesktop xfce4-terminal dbus-launch; do
            pkill -x "$n" 2>/dev/null && echo "  killed $n"
        done
        exit 0' 2>&1 | grep -v '^proot warning' || true
}

log "清理旧桌面进程..."
kill_desktop_in_container
killeq termux-x11
killeq com.termux.x11
# 旧 VirGL 链路若还有残留，顺手清掉（新版已不需要它）
killeq virgl_test_server_android
sleep 2
log "清理完成"

# ---------- GPU 加速：确保 MobileGL 服务端活着 ----------
# server 必须从 Termux 侧拉起：PRoot 用 ptrace 盯子进程，proot 里 setsid 起的进程会
# 随会话退出一起被杀（实测 glxinfo 当次能跑、退出后 server 就没了）。
log "检查 MobileGL GPU 服务端 (Magma / Mali Vulkan)..."
# 注意：不能写成 `if ! ... | tail -3` —— 管道的退出码是 tail 的，永远为 0，
# server 起不来也会被当成成功（踩过一次）。
ensure_out=$(bash "$MGL_DIR/ensure-server.sh" 2>&1) || ensure_rc=$?
ensure_rc=${ensure_rc:-0}
echo "$ensure_out" | tail -3
[ "$ensure_rc" -eq 0 ] || error_exit "MobileGL 服务端启动失败，见 /storage/emulated/0/MG/latest.server.log"
log "GPU 服务端就绪 (endpoint=@mobilegl)"

# ---------- 启动 X11 ----------
# 只判断 socket 文件存在是不够的：termux-x11 被杀后 socket 文件会留在原地，
# 复用它会得到 "xrdb: Can't open display :0" / xfce4-session 起不来（踩过）。
x0_live() {
    python3 - "$PREFIX/tmp/.X11-unix/X0" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(0.5)
try:
    s.connect(sys.argv[1])
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
}

if [ -S "$PREFIX/tmp/.X11-unix/X0" ] && x0_live; then
    log "检测到正在运行的 Termux:X11 (:0)，直接复用"
else
    log "启动 Termux:X11..."
    rm -f "$PREFIX/tmp/.X11-unix/X0" 2>/dev/null || true
    # setsid：X 服务器必须脱离本脚本的进程组，否则脚本退出/被 Ctrl+C 时会一起没
    # （踩过：用 timeout 跑脚本，X 服务器跟着死，Android 端就显示"未连接"）
    setsid termux-x11 :0 -listen unix >/dev/null 2>&1 &
    X11_PID=$!
    sleep 5
    if ! kill -0 $X11_PID 2>/dev/null; then
        error_exit "Termux:X11 启动失败"
    fi
    log "Termux:X11 已启动 (PID: $X11_PID)"
fi

# ---------- 启动 XFCE 桌面（GPU 加速） ----------
# 整段用单引号交给 proot 内的 bash：里面的 $ 全在 proot 里展开，外层（set -u）不碰。
# 外层把两个预载开关用 env 显式传进去。
log "启动 XFCE 桌面 (proot-distro)，GL 走 MobileGL / Magma..."
setsid proot-distro login debian --shared-tmp -- env \
    MGL_NOVSYNC="${MGL_NOVSYNC:-0}" \
    MGL_LEGACY="${MGL_LEGACY:-0}" \
    /bin/bash -c '
    export DISPLAY=:0
    export LANG=zh_CN.UTF-8
    export LC_ALL=zh_CN.UTF-8
    export LANGUAGE=zh_CN:zh

    # 给 root 指定的运行时临时目录，防止权限崩溃
    export XDG_RUNTIME_DIR=/tmp/runtime-root
    mkdir -p /tmp/runtime-root
    chmod 700 /tmp/runtime-root

    # --- GPU 加速注入 ---
    # env.sh 负责：MOBILEGL_TRANSPORT=spawn + IPC_CONTROL=unix:@mobilegl（只连不拉进程）、
    # MOBILEGL_BACKEND_TYPE=DirectVulkan、LD_LIBRARY_PATH、__GLX_VENDOR_LIBRARY_NAME=mobilegl
    #
    # MGL_NOVSYNC/MGL_LEGACY 会往 LD_PRELOAD 里塞本地的 glibc .so；桌面会话里若混进
    # bionic 二进制（PATH 末尾会回落到 Termux 的 bin），Android 链接器会报
    #   CANNOT LINK EXECUTABLE "xxx": library "libc.so.6" not found
    # 所以桌面启动默认不预载；需要时 MGL_NOVSYNC=1 bash ~/xfce.sh，或对单个程序用 mgl-run.sh。
    . /data/data/com.termux/files/home/mgl/env.sh >/dev/null 2>&1
    if [ "$MGL_NOVSYNC" = "0" ] && [ "$MGL_LEGACY" = "0" ]; then unset LD_PRELOAD; fi

    # dbus-launch 消灭 D-Bus 报错（用 Debian 自己的 dbus-x11，不是 Termux 的 bionic 版本）
    exec dbus-launch --exit-with-session startxfce4
' &
XFCE_PID=$!
log "XFCE 启动命令已后台运行 (PID: $XFCE_PID)，等待桌面就绪..."
sleep 10

# ---------- 启动 Termux:X11 Activity ----------
log "启动 Termux:X11 应用..."
# 先 force-stop：Activity 会缓存上一次的连接状态，X 服务器重启后不重连会一直显示"未连接"
am force-stop com.termux.x11 2>/dev/null || true
sleep 1
am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity
if [ $? -ne 0 ]; then
    log "警告：无法启动 Activity，请手动打开 Termux:X11"
else
    log "Activity 已启动"
fi
sleep 3

# ---------- 音频选择对话框（英文参数） ----------
log "弹出音频选择窗口..."

audio_choice() {
    proot-distro login debian --shared-tmp -- bash -c '
        export DISPLAY=:0

        PIPE=$(mktemp -u /tmp/yad_audio.XXXXXX)
        mkfifo "$PIPE"
        trap "rm -f $PIPE" EXIT

        yad --progress \
            --title="Audio Setup" \
            --text="Enable audio support?\nTimeout will choose No." \
            --percentage=0 \
            --button="Yes:0" --button="No:1" \
            --width=450 \
            < "$PIPE" 2>/dev/null &
        yad_pid=$!

        sleep 0.5
        if ! kill -0 $yad_pid 2>/dev/null; then
            echo "yad failed to start" >&2
            exit 1
        fi

        exec 3>"$PIPE"

        for i in $(seq 1 60); do
            if ! kill -0 $yad_pid 2>/dev/null; then
                break
            fi
            pct=$(( i * 100 / 60 ))
            rem=$(( 60 - i ))
            echo "# Countdown ${rem} sec" >&3
            echo "$pct" >&3
            sleep 1
        done

        exec 3>&-

        if kill -0 $yad_pid 2>/dev/null; then
            kill $yad_pid 2>/dev/null
            wait $yad_pid
            exit 1
        else
            wait $yad_pid
            exit $?
        fi
    '
}

if audio_choice; then
    log "用户选择启用音频"
    if command -v pulseaudio >/dev/null 2>&1 && command -v pactl >/dev/null 2>&1; then
        bash ~/music.sh &
    else
        log "错误：音频服务命令未安装，无法启用音频"
    fi
else
    log "用户跳过音频，桌面将以无声模式运行。"
fi

log "GPU 加速：MobileGL / Magma（Mali Vulkan 直连 + DRI3 零拷贝）"
log "自检命令：~/mgl/mgl-run.sh glxinfo -B   （应显示 Magma (MobileGL Core)）"
log "桌面启动流程结束，按 Ctrl+C 退出脚本（但桌面仍在后台运行）"
wait
