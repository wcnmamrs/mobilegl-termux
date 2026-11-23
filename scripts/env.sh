#!/bin/bash
# MobileGL client 环境 —— proot Debian(glibc) 侧 source 这个
#   . ~/mgl/env.sh          # 连 Termux 侧的常驻 server
#   . ~/mgl/env.sh stop     # 退出 MobileGL，回到系统 Mesa
# 客户端库目录：安装版在 /opt/mobilegl/lib；开发版在源码树
if [ -z "${MGL_BUILD:-}" ]; then
    if [ -f /opt/mobilegl/lib/libMobileGL.so ]; then
        MGL_BUILD=/opt/mobilegl/lib
    else
        MGL_BUILD=/data/data/com.termux/files/home/src/MobileGL/build-glibc
    fi
fi

if [ "${1:-}" = "stop" ]; then
    unset MOBILEGL_TRANSPORT MOBILEGL_IPC_CONTROL MOBILEGL_IPC_DATA MOBILEGL_BACKEND_TYPE
    unset __GLX_VENDOR_LIBRARY_NAME __EGL_VENDOR_LIBRARY_FILENAMES
    echo "MobileGL 已关闭（回到系统 GL）"
    return 0 2>/dev/null || exit 0
fi

# --- 自愈检查：只探测，不在这里拉起 server ---
# 拉起必须发生在 Termux 侧。原因：PRoot 用 ptrace 盯着子进程，从 proot 里 setsid 起的
# server 会随 proot 会话退出一起被杀（实测 glxinfo 当次能跑通，退出后 server 就没了）。
# 正确用法：在 Termux 侧跑 ~/mgl/mgl-run.sh <命令> 或 ~/mgl/legacy.sh <命令>。
# 设 MGL_CHECK=0 可跳过这次探测。
if [ "${MGL_CHECK:-1}" = "1" ]; then
    if ! /usr/bin/env -i \
            PATH=/data/data/com.termux/files/usr/bin:/system/bin \
            HOME=/data/data/com.termux/files/home \
            MGL_HOME=/data/data/com.termux/files/home \
            MGL_ENDPOINT="${MGL_ENDPOINT:-@mobilegl}" \
            /data/data/com.termux/files/usr/bin/bash \
            /data/data/com.termux/files/home/mgl/ensure-server.sh status 2>/dev/null |
        grep -q 'server: ready\|server: foreign'; then
        echo "  warn: MobileGL server 不在 —— 先跑 ~/mgl/ensure-server.sh，或用 ~/mgl/mgl-run.sh <命令>"
    fi
fi

# --- 传输：spawn 表示"要 split"，但 CONTROL 不是 fork 时只连接、不拉进程 ---
export MOBILEGL_TRANSPORT=spawn
export MOBILEGL_IPC_CONTROL=${MGL_ENDPOINT:-unix:@mobilegl}
export MOBILEGL_IPC_DATA=${MGL_DATA:-auto}
export MOBILEGL_IPC_PROBE_TIMEOUT_MS=${MGL_PROBE_MS:-250}

# --- 后端（server 侧才是真正执行的那个，client 侧仅协商能力）---
export MOBILEGL_BACKEND_TYPE=${MGL_BACKEND:-DirectVulkan}

# --- 库路径：让 glvnd/ld 找到 MobileGL ---
export LD_LIBRARY_PATH="$MGL_BUILD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# --- GLX：glvnd 靠这个变量选 vendor 库 libGLX_mobilegl.so.0 ---
export __GLX_VENDOR_LIBRARY_NAME=mobilegl

# --- EGL：glvnd 读 vendor JSON；直接把 MobileGL 列为唯一 vendor（注意：Espryt 会递归，
#     EGL 应用请优先用 Magma 或干脆走 GLX）---
if [ "${MGL_EGL:-0}" = "1" ]; then
    export __EGL_VENDOR_LIBRARY_FILENAMES="$MGL_BUILD/10_mobilegl.json"
fi

echo "MobileGL client env:"
echo "  build     = $MGL_BUILD"
echo "  transport = $MOBILEGL_TRANSPORT / $MOBILEGL_IPC_CONTROL (data=$MOBILEGL_IPC_DATA)"
echo "  backend   = $MOBILEGL_BACKEND_TYPE"
echo "  glvnd     = __GLX_VENDOR_LIBRARY_NAME=$__GLX_VENDOR_LIBRARY_NAME"

# 老式 OpenGL 1.x 程序（glBegin/glEnd、显示列表、客户端数组）：Magma 把这些入口实现成 stub，
# 直接跑会黑屏。libfixfunc.so 把它们翻译成 VBO + 着色器绘制。设 MGL_LEGACY=1 打开。
# 关垂直同步：MobileGL 默认按 X 的 vblank 节拍走（X11Present.cpp:252），实测锁 59.x FPS。
# libnovsync.so 把 glXSwapInterval*/glXSwapBuffers 的 interval 压成 0 → PRESENT_OPTION_ASYNC。
# 实测 glxgears 800x600：59.7 → 376.7 FPS。
if [ "${MGL_NOVSYNC:-0}" = "1" ]; then
    export LD_PRELOAD="/data/data/com.termux/files/home/mgl/lib/libnovsync.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

if [ "${MGL_LEGACY:-0}" = "1" ]; then
    export LD_PRELOAD="/data/data/com.termux/files/home/mgl/lib/libfixfunc.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi
