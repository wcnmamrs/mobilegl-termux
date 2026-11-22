#!/data/data/com.termux/files/usr/bin/bash
# 用 MobileGL 跑"老式 OpenGL 1.x"程序（glBegin/glEnd、显示列表、客户端数组）。
# Magma 后端把这些入口都实现成 stub，直接跑会黑屏；libfixfunc.so 把它们翻译成
# VBO + 着色器绘制，于是老程序也能在 Magma 上出画面。
#
# 用法：  ~/mgl/legacy.sh glxgears -geometry 800x600
#         ~/mgl/legacy.sh <任意老 GL 程序> [参数...]
# 关闭垂直同步（跑分用）：MGL_NOVSYNC=1 ~/mgl/legacy.sh glxgears -swapinterval 0

set -u
MGL_ROOT="${MGL_ROOT:-$HOME/mgl}"
MGL_SO="${MGL_SO:-$MGL_ROOT/lib/libfixfunc.so}"

if [ ! -f "$MGL_SO" ]; then
    echo "legacy.sh: 找不到 $MGL_SO" >&2
    exit 127
fi

if ! command -v proot-distro >/dev/null 2>&1 || [ -z "${MGL_INNER:-}" ]; then
    # 从 Termux 侧进来：直接交给 proot 里的 bash 重新执行自己
    exec proot-distro login debian --shared-tmp -- env MGL_INNER=1 MGL_ROOT="$MGL_ROOT" MGL_SO="$MGL_SO" \
        MGL_NOVSYNC="${MGL_NOVSYNC:-0}" \
        bash /data/data/com.termux/files/home/mgl/legacy.sh "$@"
fi

. "$MGL_ROOT/env.sh" >/dev/null 2>&1 || true
export DISPLAY="${DISPLAY:-:0}"
export LD_PRELOAD="$MGL_SO${LD_PRELOAD:+:$LD_PRELOAD}"
exec "$@"
