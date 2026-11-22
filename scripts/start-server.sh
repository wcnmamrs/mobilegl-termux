#!/data/data/com.termux/files/usr/bin/bash
# MobileGL server —— Termux 侧（bionic），直连 Mali GLES/Vulkan
# 契约（ServerMain.cpp CheckServerEnvironment）：
#   MOBILEGL_IPC_DIAL=no 必须显式设置，否则 exit 64
#   MOBILEGL_TRANSPORT / MOBILEGL_IPC_SERVER_PATH / MOBILEGL_IPC_RING_MB / MOBILEGL_IPC_STAGE_MB
#   存在则 exit 65
set -u

# 服务端镜像：装了就用 ~/mgl/lib 里的（普通用户只有这份），开发者可显式指定源码产物
if [ -n "${MGL_BUILD:-}" ]; then
    BUILD="$MGL_BUILD"
elif [ -x "$HOME/mgl/lib/libMobileGLServer.so" ]; then
    BUILD="$HOME/mgl/lib"
else
    BUILD="$HOME/src/MobileGL/build-bionic"
fi
IMAGE="$BUILD/libMobileGLServer.so"
# 注意：这里是 SERVER 侧参数。@name 才是抽象 socket。
# 写成 unix:@name 会让 SocketTransport::Listen 把它当文件系统路径，
# 在 cwd 建一个名叫 "unix:@mobilegl" 的 socket 文件，client 永远连不上。
ENDPOINT=${MGL_ENDPOINT:-@mobilegl}
SESSIONS=${MGL_SESSIONS:-8}
LOG=${MGL_LOG:-$HOME/mgl/server.log}
PIDFILE=$HOME/mgl/server.pid

if [ ! -x "$IMAGE" ]; then
    echo "server image not executable: $IMAGE" >&2
    exit 1
fi

# 环境净化：这四个别带进来，否则 server 直接拒绝启动
unset MOBILEGL_TRANSPORT MOBILEGL_IPC_SERVER_PATH MOBILEGL_IPC_RING_MB MOBILEGL_IPC_STAGE_MB
export MOBILEGL_IPC_DIAL=no
export MOBILEGL_IPC_ROLE=server
# 后端：DirectGLES(Espryt) 走系统 libEGL.so -> Mali GLES；
#       DirectVulkan(Magma) 走 libvulkan.so -> Mali Vulkan 1.1（无 dynamic rendering，慎用）
export MOBILEGL_BACKEND_TYPE=${MGL_BACKEND:-DirectVulkan}
# 日志级别
export MOBILEGL_LOG_LEVEL=${MGL_LOGLEVEL:-Info}

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running pid=$(cat "$PIDFILE")"
    exit 0
fi

echo "=== starting MobileGL server $(date) ===" >>"$LOG"
echo "image=$IMAGE endpoint=$ENDPOINT sessions=$SESSIONS backend=$MOBILEGL_BACKEND_TYPE" >>"$LOG"
setsid "$IMAGE" --serve --max-sessions "$SESSIONS" "$ENDPOINT" >>"$LOG" 2>&1 &
echo $! >"$PIDFILE"
sleep 1
echo "pid=$(cat "$PIDFILE")"
tail -5 "$LOG"
