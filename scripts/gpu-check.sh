#!/data/data/com.termux/files/usr/bin/bash
# gpu-check.sh —— 桌面/程序到底有没有走 Mali（MobileGL）？
#
# 用法：
#   ~/mgl/gpu-check.sh                  # 体检：服务端 + GLX + EGL 三条路各报一个渲染器串
#   ~/mgl/gpu-check.sh <命令> [参数...]  # 用完整 MobileGL 环境跑这个命令
#
# 全 GPU 的判据：GLX 与 EGL 两条路都出现 "Magma (MobileGL Core)"。哪条写 llvmpipe/SwiftShader，
# 就是那条路退回了容器里的 Mesa 软渲染。
set -u

MGL_DIR="${MGL_DIR:-$HOME/mgl}"
PREFIX_BIN="${PREFIX:-/data/data/com.termux/files/usr}/bin"
PROOT="${PROOT_DISTRO_BIN:-$PREFIX_BIN/proot-distro}"
EGL_VENDORS=/usr/share/glvnd/egl_vendor.d/10_mobilegl.json:/usr/share/glvnd/egl_vendor.d/50_mesa.json

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }

# 容器里跑一条命令：环境显式给全，不依赖 /etc/profile.d（非登录 shell 不读它）
proot_sh() {
    "$PROOT" login debian --shared-tmp -- env DISPLAY=:0 \
        __GLX_VENDOR_LIBRARY_NAME=mobilegl \
        __EGL_VENDOR_LIBRARY_FILENAMES="$EGL_VENDORS" \
        MOBILEGL_TRANSPORT=spawn MOBILEGL_IPC_CONTROL=unix:@mobilegl MOBILEGL_IPC_DATA=auto \
        MOBILEGL_IPC_RING_MB=64 MOBILEGL_IPC_STAGE_MB=256 MOBILEGL_IPC_SPIN_US=200 \
        MOBILEGL_IPC_PROBE_TIMEOUT_MS=250 MOBILEGL_BACKEND_TYPE=DirectVulkan \
        /bin/bash -c "$1" 2>/dev/null
}

if [ $# -gt 0 ]; then
    exec "$MGL_DIR/mgl-run.sh" "$@"
fi

echo "=== 1. GPU 服务端 ==================================="
SERVER_STATE=$(bash "$MGL_DIR/ensure-server.sh" 2>&1 | tail -1)
[ -z "$SERVER_STATE" ] && SERVER_STATE="server: $( [ -f "$MGL_DIR/server.pid" ] && printf 'pid %s 在跑' "$(cat "$MGL_DIR/server.pid")" || echo 未在跑 )"
printf '  %s\n' "$SERVER_STATE"

echo
echo "=== 2. GLX（glxinfo）================================"
GLX_OUT=$(proot_sh 'glxinfo -B 2>/dev/null' | grep -E 'OpenGL (renderer|vendor|core profile version)' || true)
if [ -z "$GLX_OUT" ]; then
    red "  未取到（X 没开？先跑 ~/xfce.sh）"
else
    echo "$GLX_OUT" | sed 's/^/  /'
    case "$GLX_OUT" in
        *Magma*) green "  GLX → Mali ✅" ;;
        *) red "  GLX → 软渲染 ❌（查 __GLX_VENDOR_LIBRARY_NAME 与 /usr/lib/*/libGLX_mobilegl.so.0）" ;;
    esac
fi

echo
echo "=== 3. EGL（es2_info：EGL 显示 + 上下文）============"
EGL_OUT=$(proot_sh 'command -v es2_info >/dev/null && timeout 25 es2_info 2>/dev/null | grep -E "EGL_VENDOR|GL_RENDERER"')
if [ -z "$EGL_OUT" ]; then
    dim "  es2_info 未安装（apt install mesa-utils-extra）或 EGL 起不来，跳过"
else
    echo "$EGL_OUT" | sed 's/^/  /'
    case "$EGL_OUT" in
        *Magma*) green "  EGL → Mali ✅（EGL 窗口表面也走 DRI3 零拷贝）" ;;
        *) red "  EGL → 软渲染 ❌（查 10_mobilegl.json 与 __EGL_VENDOR_LIBRARY_FILENAMES）" ;;
    esac
fi

echo
echo "=== 4. 桌面会话继承到的 GL 环境 ====================="
"$PROOT" login debian --shared-tmp -- bash -lc '
  echo "  __GLX_VENDOR_LIBRARY_NAME=${__GLX_VENDOR_LIBRARY_NAME:-（未设置）}"
  echo "  MOBILEGL_TRANSPORT=${MOBILEGL_TRANSPORT:-（未设置）}  IPC_CONTROL=${MOBILEGL_IPC_CONTROL:-（未设置）}"
  echo "  MOBILEGL_BACKEND_TYPE=${MOBILEGL_BACKEND_TYPE:-（未设置）}"
' 2>/dev/null | grep -E '^  (__GLX|MOBILEGL)'

echo
dim "跑单个程序：~/mgl/gpu-check.sh glmark2 -s 800x600"
