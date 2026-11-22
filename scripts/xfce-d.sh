#!/data/data/com.termux/files/usr/bin/bash
# ============================================
#  停止所有服务：XFCE 桌面 + Termux:X11 + MobileGL GPU 服务端
#  （旧 VirGL 链路的残留进程也一并清掉）
# ============================================

log() {
    echo "$*"
}

# 1. 结束 XFCE 桌面
log "1/5 结束 XFCE 桌面"
pkill -f "xfce4-session" 2>/dev/null || true
sleep 1

# 2. 结束 X11 服务器
log "2/5 结束 Termux:X11 服务器"
pkill -f "termux-x11" 2>/dev/null || true

# 3. 结束 GPU 加速服务端（MobileGL，这是现在唯一在用的加速）
log "3/5 结束 MobileGL GPU 服务端"
bash "$HOME/mgl/stop-server.sh" 2>/dev/null || true
pkill -f "libMobileGLServer.so" 2>/dev/null || true
# 旧 VirGL 链路残留（已不再使用，清掉免得占内存）
pkill -f "virgl_test_server" 2>/dev/null || true

# 4. 结束 proot 里的 debian 容器
log "4/5 停止 debian 容器"
proot-distro stop debian 2>/dev/null || true

# 5. 音频服务与 X11 客户端 Activity
log "5/5 停止音频服务 / Termux:X11 Activity"
bash ~/music.sh exit 2>/dev/null || true
pkill -f "com.termux.x11" 2>/dev/null || true

log "所有服务已停止"
