#!/data/data/com.termux/files/usr/bin/bash
# 确保 MobileGL server 活着，并且抽象 socket 真的应答。
#
# 为什么需要它：client 侧（proot 里）一旦把 MOBILEGL_TRANSPORT=spawn + CONTROL=unix:@mobilegl
# 设上，server 不在时 MobileGL 不会优雅回退，而是
#   Fatal{CapsBeforeFirstSnapshot, "TextureResources"} → abort
# 所以每个要用 GL 的进程启动前先过一遍这里。
#
#   ensure-server.sh          # 活着就退出 0，死了/半死就重启
#   ensure-server.sh status    # 只报告，不动手
#
# 探测方式：连抽象 socket（Python AF_UNIX，'\0' 前缀即抽象命名空间）。
# 注意 pidfile 活着不等于 socket 应答——server 可能在 listen 前就挂了。

# proot 里 $HOME 是 /root，所以允许外部指定 MobileGL 脚本根目录
ROOT=${MGL_HOME:-$HOME}
set -u
PIDFILE=$ROOT/mgl/server.pid
ENDPOINT=${MGL_ENDPOINT:-@mobilegl}
NAME=${ENDPOINT#@}
PROBE_TIMEOUT=${MGL_PROBE_SEC:-1}

probe() {
    python3 - "$NAME" "$PROBE_TIMEOUT" <<'PY' 2>/dev/null
import socket, sys
name, timeout = sys.argv[1], float(sys.argv[2])
s = socket.socket(socket.AF_UNIX)
s.settimeout(timeout)
try:
    s.connect("\0" + name)
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
}

pid_alive() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

state() {
    if pid_alive && probe; then echo "ready"; return 0; fi
    if pid_alive; then echo "stale-pid"; return 1; fi
    if probe; then echo "foreign"; return 0; fi
    echo "down"; return 1
}

if [ "${1:-ensure}" = "status" ]; then
    printf 'server: %s (endpoint=%s pidfile=%s)\n' "$(state)" "$ENDPOINT" \
        "$(cat "$PIDFILE" 2>/dev/null || echo -)"
    exit 0
fi

case "$(state)" in
ready)
    exit 0
    ;;
foreign)
    # 有人在监听但没有 pidfile（例如手动起的别的实例）：不动它。
    exit 0
    ;;
stale-pid)
    rm -f "$PIDFILE"
    ;;
esac

bash "$ROOT/mgl/stop-server.sh" >/dev/null 2>&1 || true
MGL_ENDPOINT="$ENDPOINT" bash "$ROOT/mgl/start-server.sh" >/dev/null 2>&1 || true

for _ in $(seq 1 40); do
    if probe; then exit 0; fi
    sleep 0.15
done

printf 'ensure-server: server 未能应答 %s，检查 /storage/emulated/0/MG/latest.server.log\n' \
    "$ENDPOINT" >&2
exit 1
