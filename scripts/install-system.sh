#!/data/data/com.termux/files/usr/bin/bash
#
# 把 MobileGL 装成"系统级"的 GL 实现：容器里的任何程序 —— 不认识的、新装的、别人的 ——
# 只要走 GLX/EGL，就自动落到 MobileGL 上，既不用改程序也不用带环境变量。
#
# 为什么这样是通用的：
#   * GLX 走 libglvnd：容器里 libGL.so.1 本来就是 libglvnd 的分发器，把 libGLX_mobilegl.so.0
#     放到它的库目录、再用 __GLX_VENDOR_LIBRARY_NAME 指过去，所有 GLX 程序（SDL2、GLFW、
#     GTK 的 GtkGLArea、Chromium 的 ANGLE、游戏）都吃这一份。
#   * EGL 走 egl_vendor.d：与 Mesa 的 50_mesa.json 并列，谁的 display 建得起来用谁。
#   * 服务端没起的时候 MobileGL 会主动"让位"（ImplementationAvailable() 返回 0），
#     glvnd 自动落到下一个实现（Mesa/llvmpipe），所以装它是安全的，不会把程序搞崩。
#
# 用法：bash ~/mgl/install-system.sh          # 安装/更新（改了 MobileGL 源码重编后重跑）
#       bash ~/mgl/install-system.sh remove   # 卸载，回到纯 Mesa
set -eu

MGL_HOME=${MGL_HOME:-$HOME/mgl}
if [ -z "${MGL_CLIENT_LIB:-}" ]; then
    if [ -f "$PROOT_DIR/opt/mobilegl/lib/libMobileGL.so" ]; then
        MGL_CLIENT_LIB="$PROOT_DIR/opt/mobilegl/lib/libMobileGL.so"
    else
        MGL_CLIENT_LIB="$HOME/src/MobileGL/build-glibc/libMobileGL.so"
    fi
fi
PROOT_DIR=${PROOT_DIR:-$PREFIX/var/lib/proot-distro/containers/debian/rootfs}
DEBIAN=${DEBIAN:-debian}
ACTION=${1:-install}

in_debian() {
    proot-distro login "$DEBIAN" --shared-tmp -- /bin/bash -c "$1" 2>&1 | grep -v '^proot warning' || true
}

if [ "$ACTION" = "remove" ]; then
    in_debian '
        rm -f /usr/share/glvnd/egl_vendor.d/10_mobilegl.json
        rm -f /usr/lib/aarch64-linux-gnu/libGLX_mobilegl.so.0 /usr/lib/aarch64-linux-gnu/libGLX_0mobilegl.so.0
        ldconfig
        rm -f /etc/profile.d/mobilegl.sh /etc/environment.d/10-mobilegl.conf
        rm -f /etc/chromium.d/50-mobilegl
        rm -rf /opt/mobilegl /etc/mobilegl
        echo "MobileGL 已从容器里移除（Mesa 恢复接管）"
    '
    exit 0
fi

[ -f "$MGL_CLIENT_LIB" ] || { echo "缺少客户端库：$MGL_CLIENT_LIB（先编 build-glibc）" >&2; exit 1; }

echo "==> 复制客户端库到容器 /opt/mobilegl/lib"
mkdir -p "$PROOT_DIR/opt/mobilegl/lib"
install -m 755 "$MGL_CLIENT_LIB" "$PROOT_DIR/opt/mobilegl/lib/libMobileGL.so"

echo "==> 注册 glvnd 厂商（GLX + EGL）"
mkdir -p "$PROOT_DIR/usr/share/glvnd/egl_vendor.d" "$PROOT_DIR/etc/profile.d" \
         "$PROOT_DIR/etc/environment.d" "$PROOT_DIR/etc/chromium.d"
cat > "$PROOT_DIR/usr/share/glvnd/egl_vendor.d/10_mobilegl.json" <<'JSON'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "/opt/mobilegl/lib/libMobileGL.so"
    }
}
JSON

echo "==> libGLX_mobilegl.so.0 指向它（libglvnd 按名字找厂商库）"
ln -sfn /opt/mobilegl/lib/libMobileGL.so "$PROOT_DIR/usr/lib/aarch64-linux-gnu/libGLX_mobilegl.so.0"

echo "==> 会话环境（GLX 厂商选择 + 传输参数）"
cat > "$PROOT_DIR/etc/profile.d/mobilegl.sh" <<'SH'
# MobileGL：把 GL 调用转出容器，交给 Termux 里的 server（它用 Mali 的 Vulkan）
# 没有 server 时 MobileGL 会主动让位，glvnd 退回 Mesa —— 装了不影响正常使用。
__glx_vendor=mobilegl
export __GLX_VENDOR_LIBRARY_NAME="$__glx_vendor"
# EGL 侧：把 MobileGL 的 vendor json 放到 Mesa 前面（libglvnd 会依次尝试）
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_mobilegl.json:/usr/share/glvnd/egl_vendor.d/50_mesa.json
export MOBILEGL_TRANSPORT=spawn
export MOBILEGL_IPC_CONTROL=unix:@mobilegl
export MOBILEGL_IPC_DATA=auto
export MOBILEGL_IPC_RING_MB=64
export MOBILEGL_IPC_STAGE_MB=256
export MOBILEGL_IPC_SPIN_US=200
export MOBILEGL_BACKEND_TYPE=DirectVulkan
export MOBILEGL_IPC_PROBE_TIMEOUT_MS=250
unset __glx_vendor
SH
# /etc/environment.d 只给读它的东西（systemd 类）用；GUI 会话真靠 profile.d + xfce.sh
cat > "$PROOT_DIR/etc/environment.d/10-mobilegl.conf" <<'CONF'
__GLX_VENDOR_LIBRARY_NAME=mobilegl
MOBILEGL_TRANSPORT=spawn
MOBILEGL_IPC_CONTROL=unix:@mobilegl
MOBILEGL_IPC_DATA=auto
MOBILEGL_BACKEND_TYPE=DirectVulkan
CONF

echo "==> /etc/mobilegl/client.conf（MobileGL 自己读的配置，程序不用带环境变量）"
mkdir -p "$PROOT_DIR/etc/mobilegl"
cat > "$PROOT_DIR/etc/mobilegl/client.conf" <<'CONF'
# 让任何链接 libGL/libEGL 的程序把 GL 转出容器 —— 这是配置文件，不是环境变量，
# 所以程序从菜单、终端、脚本里起来都一样。进程环境里的同名变量优先级更高，
# 想临时换后端：export MOBILEGL_BACKEND_TYPE=DirectGLES
MOBILEGL_TRANSPORT=spawn
MOBILEGL_IPC_CONTROL=unix:@mobilegl
MOBILEGL_IPC_DATA=auto
MOBILEGL_IPC_RING_MB=64
MOBILEGL_IPC_STAGE_MB=256
MOBILEGL_IPC_SPIN_US=200
MOBILEGL_IPC_PROBE_TIMEOUT_MS=250
MOBILEGL_BACKEND_TYPE=DirectVulkan
CONF

echo "==> Chromium 的开关落到 /etc/chromium.d（Debian 的 chromium 启动器会读）"
cat > "$PROOT_DIR/etc/chromium.d/50-mobilegl" <<'CHR'
# ANGLE 走 GLX（MobileGL 提供），其余是容器里跑 Chromium 的必要开关
CHROMIUM_FLAGS="$CHROMIUM_FLAGS --use-gl=angle --use-angle=gl --ignore-gpu-blocklist --no-sandbox --disable-dev-shm-usage"
CHR

echo "==> 完成。验证（应该看到 MobileGL / Magma）："
in_debian 'ls -l /usr/share/glvnd/egl_vendor.d/ /usr/lib/aarch64-linux-gnu/libGLX_mobilegl.so.0 2>&1 | tail -5'
echo "    proot-distro login $DEBIAN --shared-tmp -- bash -lc 'glxinfo -B | head -6'"
echo "    proot-distro login $DEBIAN --shared-tmp -- bash -lc 'chromium --version'   # 之后直接 chromium 即可"
