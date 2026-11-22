#!/data/data/com.termux/files/usr/bin/bash
# 停 MobileGL server
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
pkill -9 -f "libMobileGLServer.so" 2>/dev/null
echo "done"
