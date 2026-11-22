#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot —— 开机把 MobileGL 的 GPU 服务端拉起来，这样容器里任何程序一起手就有 Mali 可用。
#
# 只做一件事：等 Termux 会话环境就绪后确保 @mobilegl 在监听。
# 起不来也不算失败（只是容器里的 GL 会退回 Mesa/llvmpipe），所以全部静默并记录到日志。

export HOME=/data/data/com.termux/files/home
export PREFIX=/data/data/com.termux/files/usr
export PATH=$PREFIX/bin:$HOME/bin:/system/bin:/system/xbin

LOG=$HOME/mgl/boot.log
mkdir -p "$HOME/mgl"

# 开机瞬间 /storage、/dev 节点可能还没就绪，给系统一点时间（Termux:Boot 本身已经是开机后触发）。
for i in $(seq 1 30); do
    [ -x /system/bin/app_process64 ] && break
    sleep 2
done

{
    echo "=== $(date '+%F %T') boot: ensuring MobileGL server ==="
    bash "$HOME/mgl/ensure-server.sh" 2>&1
    bash "$HOME/mgl/ensure-server.sh" status 2>&1
    echo "=== $(date '+%F %T') done ==="
} >>"$LOG" 2>&1
