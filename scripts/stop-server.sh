#!/data/data/com.termux/files/usr/bin/bash
# 停 MobileGL server

# 按名字精确杀进程：先看 /proc/<pid>/exe 的基本名，再看 /proc/<pid>/comm。
# 为什么不用 pkill -f：它匹配整条命令行，会把"命令行里恰好含有这个名字"的 shell 一起杀掉
# （实测踩到过：卸载脚本把自己的父 shell 打成 SIGKILL）。
# 为什么要看 comm：proot 里的子进程被 ptrace 盯住，从 Termux 侧 readlink /proc/<pid>/exe
# 会失败；而 termux-x11 这类 shell 包装器的 exe 是 /system/bin/sh，只有 comm 才对得上。
killeq() {
    local name="$1" p exe comm
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        exe=$(readlink "$p/exe" 2>/dev/null) && [ "$(basename "$exe")" = "$name" ] && {
            kill -9 "${p#/proc/}" 2>/dev/null || true; continue; }
        comm=$(cat "$p/comm" 2>/dev/null) || continue
        [ "$comm" = "$name" ] && kill -9 "${p#/proc/}" 2>/dev/null || true
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
