#!/data/data/com.termux/files/usr/bin/bash
# 停 MobileGL server

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

PIDFILE=$HOME/mgl/server.pid
if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 0.5
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        echo "stopped pid=$pid"
    else
        echo "pid=$pid not running"
    fi
    rm -f "$PIDFILE"
else
    echo "no pidfile"
fi
killeq libMobileGLServer.so
echo "done"
