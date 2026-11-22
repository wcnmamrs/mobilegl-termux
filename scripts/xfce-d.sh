#!/data/data/com.termux/files/usr/bin/bash
# ============================================
#  停止所有服务：XFCE 桌面 + Termux:X11 + MobileGL GPU 服务端
#  （旧 VirGL 链路的残留进程也一并清掉）
# ============================================

# 按可执行文件名精确杀进程。
# 为什么不用 pkill -f：它匹配整条命令行，会把"命令行里恰好含有这个名字"的 shell 一起杀掉
# （实测过一次：卸载脚本把自己的父 shell 打成 SIGKILL）。
killeq() {
    local name="$1" p exe
    for p in /proc/[0-9]*; do
        exe=$(readlink "$p/exe" 2>/dev/null) || continue
        [ "$(basename "$exe")" = "$name" ] || continue
        [ "${p#/proc/}" = "$$" ] && continue
        kill -9 "${p#/proc/}" 2>/dev/null || true
    done
}


log() {
    echo "$*"
}

# 1. 结束 XFCE 桌面
log "1/5 结束 XFCE 桌面"
killeq xfce4-session
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

# 5. 音频服务与 X11 客户端 Activity
log "5/5 停止音频服务 / Termux:X11 Activity"
bash ~/music.sh exit 2>/dev/null || true
killeq com.termux.x11

log "所有服务已停止"
