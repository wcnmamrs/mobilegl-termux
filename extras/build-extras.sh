#!/usr/bin/env bash
# 构建 extras/ 里的三个 LD_PRELOAD 层。必须在容器（glibc）里跑。
#
#   bash extras/build-extras.sh            # 产物落到 ~/mgl/lib/
#   OUT=/somewhere bash extras/build-extras.sh
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HOME/mgl/lib}
mkdir -p "$OUT"

need() { command -v "$1" >/dev/null || { echo "缺 $1" >&2; exit 1; }; }
need gcc

# libfixfunc：GL 1.x 固定管线 → GLSL/VBO 翻译层（老游戏、老工具）
gcc -O2 -shared -fPIC -o "$OUT/libfixfunc.so" "$SRC/fixfunc.c" -lm -ldl
# libnovsync：强制 glXSwapInterval*(0)，解开 vblank 节拍
gcc -O2 -shared -fPIC -o "$OUT/libnovsync.so" "$SRC/novsync.c" -ldl
# libgpalog：记录 glXGetProcAddress 返回 NULL 的名字（诊断用）
gcc -O2 -shared -fPIC -o "$OUT/libgpalog.so" "$SRC/gpalog.c" -ldl

echo "产物："
ls -l "$OUT"
