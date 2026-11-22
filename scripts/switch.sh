#!/data/data/com.termux/files/usr/bin/bash
# MobileGL / virpipe 链路一键切换
#
#   switch.sh mobilegl   停 virgl，起 MobileGL server（bionic 侧，直连 Mali Vulkan）
#   switch.sh virpipe    停 MobileGL server，起 virgl_test_server_android
#   switch.sh status     显示两边进程与当前 socket
#   switch.sh bench      跑 800x600 glxgears 对比（需 X server 在跑）
#   switch.sh ensure     server 自愈（探测 socket，杀掉半死实例再拉起）
#   switch.sh desktop    起 XFCE 桌面（MobileGL 链路）
#
# 用法：在 Termux 里 source 对应 env 后再启动 GL 应用：
#   source ~/mgl/env.sh ; startxfce4

set -u
MG=/storage/emulated/0/MG
ENDPOINT=@mobilegl

title() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

stop_virgl() {
  for p in $(ps -eo pid,comm 2>/dev/null | awk '$2 ~ /^virgl/ {print $1}'); do
    kill -9 "$p" 2>/dev/null
  done
}

stop_mgl() {
  if [ -f ~/mgl/server.pid ]; then
    kill "$(cat ~/mgl/server.pid)" 2>/dev/null
    sleep 1
    rm -f ~/mgl/server.pid
  fi
  for p in $(ps -eo pid,args 2>/dev/null | grep '[l]ibMobileGLServer' | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
  done
}

case "${1:-status}" in
mobilegl)
  title "切到 MobileGL"
  stop_virgl
  rm -f ~/mgl/server.pid
  stop_mgl
  bash ~/mgl/start-server.sh 2>&1 | tail -3
  sleep 2
  if ps -eo args 2>/dev/null | grep -q '[l]ibMobileGLServer'; then
    echo "server 就绪：$ENDPOINT"
    echo "客户端请 source ~/mgl/env.sh"
  else
    echo "server 启动失败，检查 $MG/latest.server.log"
  fi
  ;;

virpipe)
  title "切到 virpipe"
  stop_mgl
  stop_virgl
  sleep 1
  nohup virgl_test_server_android --angle-vulkan >~/virgl.log 2>&1 &
  sleep 3
  if ps -eo comm 2>/dev/null | grep -q '^virgl'; then
    echo "virgl_test_server_android 就绪"
    echo "客户端需要：export GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.3COMPAT MESA_GLSL_VERSION_OVERRIDE=430"
  else
    echo "virgl 启动失败，看 ~/virgl.log"
  fi
  ;;

status)
  title "进程"
  ps -eo pid,args 2>/dev/null | grep -E '[l]ibMobileGLServer|[v]irgl_test_server' | head -4 || echo "（两个都没在跑）"
  title "X server socket"
  ls -la "$PREFIX/tmp/.X11-unix/" 2>/dev/null | head -4
  title "MobileGL server 日志尾部"
  tail -3 "$MG/latest.server.log" 2>/dev/null
  ;;

desktop)
  title "起 XFCE 桌面（GL 走 MobileGL/Magma）"
  exec bash "$HOME/mgl/xfce-mobilegl.sh"
  ;;

ensure)
  title "server 自愈"
  bash "$HOME/mgl/ensure-server.sh"
  bash "$HOME/mgl/ensure-server.sh" status
  ;;

bench)
  title "glxgears 800x600 @ $(date +%T)"
  proot-distro login debian --shared-tmp -- /bin/bash -c '
    export DISPLAY=:0
    if [ -n "${MGL_BENCH:-}" ]; then
      if [ -f /opt/mobilegl/lib/libMobileGL.so ]; then
          export LD_LIBRARY_PATH=/opt/mobilegl/lib
      else
          export LD_LIBRARY_PATH=/data/data/com.termux/files/home/src/MobileGL/build-glibc
      fi
      export __GLX_VENDOR_LIBRARY_NAME=mobilegl MOBILEGL_TRANSPORT=spawn
      export MOBILEGL_IPC_CONTROL=unix:@mobilegl MOBILEGL_IPC_DATA=auto
      export MOBILEGL_BACKEND_TYPE=DirectVulkan MOBILEGL_IPC_STAGE_MB=256
    else
      export GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.3COMPAT MESA_GLSL_VERSION_OVERRIDE=430
    fi
    timeout 16 glxgears -geometry 800x600 2>/dev/null | grep "frames in" | tail -2 | head -1
  ' 2>&1 | grep -v "^proot warning" | tail -2
  ;;

*)
  sed -n '2,14p' "$0"
  exit 1
  ;;
esac
