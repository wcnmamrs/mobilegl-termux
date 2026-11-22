#!/data/data/com.termux/files/usr/bin/bash
# 用 MobileGL 跑任意 GL 程序（现代路径：VBO + 着色器，Magma 直连 Mali Vulkan）。
#
#   ~/mgl/mgl-run.sh glmark2 -s 800x600
#   ~/mgl/mgl-run.sh blender          # 任意 proot 里的程序
#   MGL_NOVSYNC=1 ~/mgl/mgl-run.sh glxgears -swapinterval 0   # 关垂直同步
#
# 做的事（顺序有讲究）：
#   1. 在 Termux 侧 ensure-server —— 必须在 proot 外面拉，否则 server 会随 proot 退出被杀
#   2. 进 proot，source env.sh（传输/后端/glvnd 变量）
#   3. exec 目标程序
#
# 老式固定管线程序（glBegin/glEnd 那一代）请用 ~/mgl/legacy.sh，或在这里加 MGL_LEGACY=1。

set -u
MGL_ROOT="${MGL_ROOT:-$HOME/mgl}"
MGL_HOME_TERMUX="${MGL_HOME_TERMUX:-$HOME}"

if [ $# -eq 0 ]; then
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

if ! command -v proot-distro >/dev/null 2>&1 || [ -z "${MGL_INNER:-}" ]; then
    # ---- Termux 侧 ----
    if ! bash "$MGL_ROOT/ensure-server.sh"; then
        echo "mgl-run.sh: MobileGL server 起不来，GL 程序会 abort" >&2
        echo "            看 /storage/emulated/0/MG/latest.server.log" >&2
        exit 1
    fi
    exec proot-distro login debian --shared-tmp -- \
        env MGL_INNER=1 \
        MGL_ROOT="/data/data/com.termux/files/home/mgl" \
        MGL_NOVSYNC="${MGL_NOVSYNC:-0}" \
        MGL_LEGACY="${MGL_LEGACY:-0}" \
        MGL_BACKEND="${MGL_BACKEND:-DirectVulkan}" \
        bash /data/data/com.termux/files/home/mgl/mgl-run.sh "$@"
fi

# ---- proot 侧 ----
# shellcheck disable=SC1090
. "$MGL_ROOT/env.sh" >/dev/null 2>&1 || true
export DISPLAY="${DISPLAY:-:0}"

exec "$@"
