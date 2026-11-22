#!/data/data/com.termux/files/usr/bin/bash
# ============================================
#  停止所有服务：XFCE 桌面 + Termux:X11 + MobileGL GPU 服务端
#  （旧 VirGL 链路的残留进程也一并清掉）
# ============================================

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


# 容器侧的桌面进程必须从容器里杀：proot 用 ptrace 盯子进程，Termux 侧读不到它们的 exe。
kill_desktop_in_container() {
    proot-distro login debian --shared-tmp -- /bin/sh -c '
        for n in xfce4-session xfwm4 xfce4-panel xfce4-notifyd xfsettingsd xfdesktop xfce4-terminal dbus-launch; do
            pkill -x "$n" 2>/dev/null && echo "  killed $n"
        done
        exit 0' 2>&1 | grep -v '^proot warning' || true
}

log() {
    echo "$*"
}

# 1. 结束 XFCE 桌面
log "1/5 结束 XFCE 桌面"
kill_desktop_in_container
sleep 1

# 2. 结束 X11 服务器
log "2/5 结束 Termux:X11 服务器"
killeq termux-x11

# 3. 结束 GPU 加速服务端（MobileGL，这是现在唯一在用的加速）
log "3/5 结束 MobileGL GPU 服务端"
bash "$HOME/mgl/stop-server.sh" 2>/dev/null || true
killeq libMobileGLServer.so
# 旧 VirGL 链路残留（已不再使用，清掉免得占内存）
killeq virgl_test_server_android

# 4. 结束 proot 里的 debian 容器
log "4/5 停止 debian 容器"
proot-distro stop debian 2>/dev/null || true

# 5. X11 客户端 Activity
log "5/5 停止 Termux:X11 Activity"
killeq com.termux.x11

log "所有服务已停止"
