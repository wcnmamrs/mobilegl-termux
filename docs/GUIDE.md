# 给 proot Debian 装真 GPU 加速：MobileGL on Termux（无 root）

> 目标：Android 手机上用 Termux + proot-distro 跑 Debian 桌面／游戏，并且 **GL 真正跑在 Mali GPU 上**，
> 而不是 Mesa 的 `llvmpipe` 软渲染。
>
> 本文所有命令、参数、坑都来自一台实机：
> `TFY-AN00 / 天玑 700 (MT6833V) / Mali-G57 MC2 / Android 12 (SDK 31) / arm64 / 8GB / 无 root`。
> 结果：`OpenGL 4.6.0 MobileGL`，`Magma (MobileGL Core) (Mali-G57 MC2, Vulkan 1.1.177)`，
> glmark2 800×600 得分 **306**（同机 Mesa 软渲染是 99）。

> **只是想装上用？** 不需要看这篇——回 [README](../README.md) 跑 `install.sh` 即可（预编译载荷，1–2 分钟）。
> 本文是**从源码编译**的完整流程：跟上游更新、改补丁、换设备时才用。

---

## 0. 先搞清楚：容器里其实"看不见"GPU

这是整件事的前提，误解了就会一直调 Mesa 参数：

| 检查项 | Termux（bionic） | proot 里（glibc Debian） |
|---|---|---|
| `/dev/mali*` | 不存在 | 不存在 |
| `/dev/dri/*` | `Permission denied` | `Permission denied` |
| `vulkaninfo` | ✅ `Mali-G57 MC2`（走 `/system/lib64/libvulkan.so`） | ❌ 只有 Mesa 的 ICD：`llvmpipe` |
| `glxinfo`（不配 MobileGL） | — | ❌ `llvmpipe (LLVM, 128 bits)` 软渲染 |

原因：Mali 的驱动是 Android 供应商分区里的 bionic 库（`/vendor/lib64/hw/vulkan.mali.so`），靠 Android 的
linker 和 gralloc 通道访问，**glibc 进程加载不了，也打不开那些内核节点**。所以在容器里怎么装 Mesa 都只能软渲染。

结论：**GL 调用必须在容器外（Termux 侧）执行**。MobileGL 的 split 架构正好干这件事：
容器里的 `libMobileGL.so` 把每条 GL 调用序列化，通过 unix 抽象 socket 发给 Termux 侧的
`libMobileGLServer.so`，由它用 Mali Vulkan 真跑，画面用 dma-buf 零拷贝回传。

---

## 1. 架构

```
 ┌─────────────────────────────── proot Debian (glibc) ───────────────────────────────┐
 │  应用 (glxgears / LOVE / PvZ / Chromium)                                            │
 │      ↓ 链接 libGL.so → libMobileGL.so（客户端）                                      │
 │  矩阵/即时模式兼容层 libfixfunc.so（可选，给 GL 1.x 程序）                            │
 │  垂直同步旁路   libnovsync.so（可选）                                                │
 └───────────────────────────────┬────────────────────────────────────────────────────┘
                                 │ unix 抽象 socket  @mobilegl（control + shm 数据环）
 ┌───────────────────────────────┴──────── Termux (bionic) ────────────────────────────┐
 │  libMobileGLServer.so --serve --max-sessions 8 @mobilegl                            │
 │      ↓ Magma 后端（DirectVulkan）                                                    │
 │  /system/lib64/libvulkan.so → /vendor/lib64/hw/vulkan.mali.so → Mali GPU            │
 │      ↓ 渲染结果 AHardwareBuffer(dma-buf)                                             │
 └───────────────────────────────┬────────────────────────────────────────────────────┘
                                 │ DRI3 + Present（termux-x11 把 dma-buf 当 pixmap）
                                 ↓
                        termux-x11 (:0) → Android 屏幕
```

关键点：两端**同一个 UID**（都是 Termux 的 app uid），所以抽象 socket、共享内存、dma-buf fd 传递全部可用，
不需要 root，也不需要 `android-plugin` 里给"另一个 App"准备的 broker。

---

## 2. 环境要求

- Android 8.0+（实测 Android 12 / SDK 31），arm64
- Termux（F-Droid 版）、Termux:X11、proot-distro
- **不需要 root**，但需要设备有可用的 Vulkan 1.1 驱动（Mali / Adreno / PowerVR 都行）
- 内存：编译阶段至少 2GB 可用，建议不要两边同时编译（见踩坑 6）
- 版本锚点（本文实测通过）：
  - MobileGL `dev` @ `2bdbe052c6a6138d9fccaec034cbc598d5a07b16`
  - Termux:X11 `1.03.01` @ `d366d40`
  - Termux clang 21.1.8、cmake 4.4.5、ninja；Debian trixie gcc 14.2.0、cmake 3.31.6

---

## 3. 装依赖

### 3.1 Termux 侧（服务端 + 工具）

```bash
pkg update
pkg install -y clang cmake ninja git python vulkan-tools \
               x11-repo termux-x11-nightly proot-distro pulseaudio
```

`vulkan-tools` 只在排查时用；确认 Mali 能被看到：

```bash
vulkaninfo --summary | grep deviceName      # 应该输出 Mali-xxx
```

> 注意：`$PREFIX/lib/libvulkan.so` 必须是指向 `/system/lib64/libvulkan.so` 的符号链接
> （由 `vulkan-loader-android` 提供）。如果你装过 `vulkan-loader-generic`，它会把这个链接换成自己的
> loader，服务端会起不来（见踩坑 16）。

### 3.2 Debian 侧（客户端）

```bash
proot-distro install debian
proot-distro login debian --shared-tmp
```

容器内：

```bash
apt update
apt install -y build-essential cmake ninja-build pkg-config git python3 \
               libvulkan-dev libx11-dev libxext-dev libxrandr-dev \
               libxcb1-dev libxcb-dri3-dev libxcb-present-dev libxcb-sync-dev \
               libxcb-shm0-dev libxcb-shape0-dev libxcb-randr0-dev libxcb-xfixes0-dev \
               dbus-x11 xfce4 xfce4-terminal mesa-utils glmark2 x11-apps \
               gdb
```

`mesa-utils` 提供 `glxinfo`（用来验证），`x11-apps` 提供 `xwd`/`xwininfo`（截图排查）。

> **不要**装 `libdrm-dev` / `libgbm-dev`：Debian 的 `libdrm2` 和 `libdrm-dev` 常常版本打架
> （`E: Unable to correct problems, you have held broken packages`）。缺 gbm 头只会让
> `mobilegl_gbm.so` 不编译，而 Termux 场景用不到它。

---

## 4. 拿源码（含网络加速）

`github.com` 直连很慢、`raw.githubusercontent.com` 常常超时，用镜像前缀：

```bash
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
mkdir -p ~/src && cd ~/src
git clone --depth 1 -b dev https://github.com/MobileGL-Dev/MobileGL.git
cd MobileGL
```

然后拉 submodule。官方脚本 `scripts/ci/checkout_submodules.sh library` 的集合就是这些（10 个）：

```bash
for m in 3rdparty/glslang 3rdparty/SPIRV-Cross 3rdparty/SPIRV-Reflect \
         3rdparty/Vulkan-Headers 3rdparty/Vulkan-Utility-Libraries \
         3rdparty/VulkanMemoryAllocator 3rdparty/asio 3rdparty/flatbuffers \
         3rdparty/xxHash include/ska; do
    git submodule update --init --depth 1 "$m" || true
done
```

两个已知缺口，必须手工补：

```bash
# (a) include/ska 在 dev 分支是空 submodule，但 Includes.h 无条件 include 它
cd include/ska && git init -q . \
  && git fetch --depth 1 origin 21c1cec95abee1beef827e4a7c95f692875d9594 \
  && git checkout -q FETCH_HEAD && cd ../..

# (b) glslang 需要 External/spirv-tools + spirv-headers（版本见 its known_good.json）
cd 3rdparty/glslang/External
git init -q spirv-tools && cd spirv-tools \
  && git fetch --depth 1 origin 33e02568181e3312f49a3cf33df470bf96ef293a \
  && git checkout -q FETCH_HEAD
git init -q external/spirv-headers && cd external/spirv-headers \
  && git fetch --depth 1 origin 2a611a970fdbc41ac2e3e328802aed9985352dca \
  && git checkout -q FETCH_HEAD
```

> `3rdparty/glvnd` **不是** submodule，是仓库里直接带的目录（提供 `<glvnd/libeglabi.h>`）。
> 别当垃圾删掉，删了要 `git checkout -- 3rdparty/glvnd` 才能回来。

---

## 5. 打补丁

仓库里两个补丁是本次实机验证过的必要修改，按顺序 apply：

```bash
cd ~/src/MobileGL
git apply /path/to/mobilegl-dri3-fix.patch     # DRI3 零拷贝（fd 选择 / modifier 回退 / 线性布局 / 通道交换）
git apply /path/to/mobilegl-compat.patch       # GetProcAddress 兜底 / 兼容档矩阵栈 / 亮度纹理格式 / gl_FragData 冲突
```

补丁解决的都是"不补就跑不起来"的级别：

| 补丁 | 解决什么 |
|---|---|
| `mobilegl-dri3-fix.patch` | termux-x11 拒绝 dma-buf（BadAlloc）：取错 fd、modifier 不被接受、gralloc 给的是 AFBC 压缩布局、BGRA 通道顺序 |
| `mobilegl-compat.patch` | GLAD 拿到 NULL 指针崩溃（查找表只覆盖 1399/2952 个导出）、`gl_ModelViewMatrix` 这族兼容档内建缺失、`GL_LUMINANCE8_ALPHA8` 等格式返回 `GL_INVALID_ENUM`、`gl_FragData` 撞车 |

---

## 6. 编客户端（proot / glibc）

**客户端和服务端必须是同一个 source revision**，wire layout 不匹配会直接拒会话。

```bash
proot-distro login debian --shared-tmp
cd /data/data/com.termux/files/home/src/MobileGL
cmake -S . -B build-glibc -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DMOBILEGL_BUILD_TEST=OFF -DMOBILEGL_BUILD_BENCHMARK=OFF \
  -DMOBILEGL_ENABLE_TRACY=OFF -DMOBILEGL_BUILD_INTEGRATION_TEST=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
ninja -C build-glibc -j2        # 内存小就 -j2，别贪
```

产物：`build-glibc/libMobileGL.so`（约 22 MB）+ 自动生成的
`libEGL.so`、`libEGL.so.1`、`libGL.so`、`libGL.so.1`、`libGLX_mobilegl.so.0`（全是指向它的符号链接）。
`nm -D --defined-only libMobileGL.so | grep -cE " T glX| T egl"` ≈ 103。

---

## 7. 编服务端（Termux / bionic）

在 Termux 里（不要进 proot）：

```bash
cd ~/src/MobileGL
cmake -S . -B build-bionic -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$PREFIX/bin/clang -DCMAKE_CXX_COMPILER=$PREFIX/bin/clang++ \
  -DCMAKE_C_COMPILER_TARGET=aarch64-linux-android26 \
  -DCMAKE_CXX_COMPILER_TARGET=aarch64-linux-android26 \
  -DANDROID_PLATFORM=android-26 \
  -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG" \
  -DMOBILEGL_BUILD_TEST=OFF -DMOBILEGL_BUILD_BENCHMARK=OFF \
  -DMOBILEGL_ENABLE_TRACY=OFF -DMOBILEGL_BUILD_INTEGRATION_TEST=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
ninja -C build-bionic -j4
```

三个参数都不是可有可无的：

- `-D..._COMPILER_TARGET=...android26`：Termux 默认 triple 是 android24，而 `AHardwareBuffer_*`
  在 API 26 才可用，不写就是一堆 `unavailable: introduced in Android 26`。
- `-O1`：默认 `-O3` 下 `3rdparty/glslang/External/spirv-tools` 要编十几分钟；`-O1` 两分钟出库，
  服务端热路径开销可以忽略（真正的开销在 Mali 驱动里）。
- `-DANDROID_PLATFORM=android-26`：CMake 会从 triple 尾数读 API level，读不到就 `FATAL_ERROR`。

产物：

- `build-bionic/libMobileGL.so`（约 22 MB，导出 ≈60 个 `egl*`/`glX*`；Android 构建会把
  `GLXImpl.cpp` 整体排除，所以比客户端少）
- `build-bionic/libMobileGLServer.so`（**6 KB**，它是 `add_executable` 出来的可执行文件，
  带 `$ORIGIN` rpath，只是把 `main` 转发到库里的 `mobilegl_server_main`）

---

## 8. 跑起来

### 8.1 起服务端（Termux 侧，必须在这里起）

```bash
cd ~/mgl && bash start-server.sh
```

脚本做的事等价于：

```bash
unset MOBILEGL_TRANSPORT MOBILEGL_IPC_SERVER_PATH MOBILEGL_IPC_RING_MB MOBILEGL_IPC_STAGE_MB
export MOBILEGL_IPC_DIAL=no
export MOBILEGL_IPC_ROLE=server
export MOBILEGL_BACKEND_TYPE=DirectVulkan
setsid ~/src/MobileGL/build-bionic/libMobileGLServer.so --serve --max-sessions 8 @mobilegl
```

两条硬性要求：

- `MOBILEGL_IPC_DIAL` **必须显式 `no`**，否则 `return 64`
- 不能带 `MOBILEGL_TRANSPORT` / `MOBILEGL_IPC_SERVER_PATH` / `MOBILEGL_IPC_RING_MB` / `MOBILEGL_IPC_STAGE_MB`
  任何一个，否则 `envp scrub FAILED` → `return 65`
- endpoint 写 `@mobilegl`，**不要**写 `unix:@mobilegl` —— 服务端不剥前缀，会在当前目录建一个真文件，
  客户端连抽象地址就 `errno=111`

就绪标志：`MG_Remote server: pid=... listening on @mobilegl`。

> 为什么不能在 proot 里起：PRoot 用 ptrace 盯着子进程，proot 会话退出时会把里面 `setsid` 起来的
> server 一起带走（实测当次能用，退出后 socket 就 111）。所以 `ensure-server.sh` 只在 Termux 侧调用。

### 8.2 客户端环境（proot 侧）

```bash
. ~/mgl/env.sh          # 之后 glxinfo / 游戏都走 Mali
. ~/mgl/env.sh stop     # 撤销，回到容器里的 Mesa
```

等价内容：

```bash
export MOBILEGL_TRANSPORT=spawn
export MOBILEGL_IPC_CONTROL=unix:@mobilegl     # client 这里要带 unix: 前缀
export MOBILEGL_IPC_DATA=auto
export MOBILEGL_BACKEND_TYPE=DirectVulkan      # DirectGLES 在 bionic 上起不来，见踩坑 4
export LD_LIBRARY_PATH=/data/data/com.termux/files/home/src/MobileGL/build-glibc
export __GLX_VENDOR_LIBRARY_NAME=mobilegl
```

验证：

```bash
proot-distro login debian --shared-tmp -- bash -c '. ~/mgl/env.sh && DISPLAY=:0 glxinfo -B'
```

期望：

```
OpenGL renderer string: Magma (MobileGL Core) (Mali-G57 MC2, Vulkan 1.1.177, Driver 32.1.0)
OpenGL core profile version string: 4.6.0 MobileGL 26.11-dev, Direct (Vulkan) Backend
direct rendering: Yes
```

不想手动配环境，直接用启动器：

```bash
~/mgl/mgl-run.sh glxinfo -B            # Termux 侧一行，自动 ensure-server + 进 proot + 注入环境
~/mgl/mgl-run.sh env LD_PRELOAD= ./game
```

---

## 9. 桌面（XFCE）

本项目不提供桌面启动器。要起图形桌面，自己按下面三步来（顺序不能反）：

```bash
bash ~/mgl/ensure-server.sh                       # 1. GPU 服务端
termux-x11 :0 -listen unix &                      # 2. X 服务器
proot-distro login debian --shared-tmp -- /bin/bash -lc 'DISPLAY=:0 startxfce4'   # 3. 桌面
```

```bash
bash ~/mgl/ensure-server.sh   # 起服务端
bash ~/mgl/stop-server.sh   # 停 GPU 服务端（桌面与 X 由你自己的脚本管）
```

桌面本身不用 OpenGL（XFCE 走 XRender），GPU 加速只影响桌面里跑的 GL 程序。所以截图验证请用
`glxinfo` / `glmark2` / 游戏，别指望壁纸变快。

想给桌面里所有 GL 程序关掉垂直同步（默认贴 60Hz）：

```bash
MGL_NOVSYNC=1 <你的桌面启动命令>
```

---

## 10. 老式 GL 程序（GL 1.x 兼容层）

Magma 把固定管线入口（`glBegin/glVertex3f/glEnd`、显示列表、客户端数组）实现成 **stub 空函数**，
所以 `glxgears`、老游戏会"黑窗口但有帧率"。两种解法：

1. **程序还在用 SDL/GLAD 动态取指针**（如 LOVE 引擎）→ 必须在 MobileGL 内部补实现（见 `mobilegl-compat.patch`），
   因为 LD_PRELOAD 拦不到它们（它们 dlsym 自己的 libGL 句柄）。
2. **程序是普通链接 OpenGL 的** → 用 `libfixfunc.so` 在 GL 之上做翻译：

```bash
cd <仓库>/extras && gcc -O2 -shared -fPIC -o ~/mgl/lib/libfixfunc.so fixfunc.c -lm -ldl
~/mgl/legacy.sh glxgears            # = 注入 env + LD_PRELOAD=libfixfunc.so
```

`libfixfunc.so` 覆盖：`glBegin/End`、`glVertex*/Color*/Normal*/TexCoord*`、矩阵栈（`glMatrixMode/glLoadIdentity/
glMultMatrixf/glTranslatef/glRotatef/glScalef/glOrtho/glFrustum/glPushMatrix/glPopMatrix`）、显示列表、
客户端数组、`glMaterial*/glLight*`（头灯近似）、纹理（`glTexImage2D` + `GL_MODULATE/REPLACE/DECAL/BLEND`）。
实测 `glxgears` 三个彩色齿轮正常，`-swapinterval 0` 下 342 FPS。

未覆盖：多纹理单元（只接 unit 0）、纹理矩阵、`GL_COMBINE/GL_ADD`、1D/3D 纹理、`glCopyTexImage`、
`glDrawPixels/glRasterPos/glBitmap`。

---

## 11. 性能实测（同机同 X server，1280×1024）

| 场景 | Mesa 软渲染 | MobileGL（Magma+DRI3） | 倍数 |
|---|---|---|---|
| glmark2 Score @800×600 | 99 | **306** | 3.1× |
| glmark2 build use-vbo=false | 114 | **251** | 2.2× |
| glmark2 texture | 115 | **407** | 3.5× |
| glmark2 shading | 117 | **403** | 3.4× |
| glmark2 desktop | 56 | **169** | 3.0× |
| glxgears @800×600 | ~108 | 30.2（readback）→ **58.6**（DRI3 零拷贝） | 0.5× |

`glxgears` 在 MobileGL 上**没有参考价值**：它全靠 `glBegin/glVertex3f`，Magma 里是 stub，
那个 FPS 只是"清屏+swap"的空转节奏。判断性能请用 `glmark2` 这类 VBO+GLSL 的现代负载。

呈现路径对帧率影响很大（800×600 glxgears）：

| 呈现方式 | FPS | 颜色 |
|---|---|---|
| readback + PutImage | 30.2 | ✅ |
| DRI3 零拷贝（修 fd/modifier 前） | 55.4 | ❌ 乱码 |
| DRI3 零拷贝（线性布局） | 59.4 | ❌ R/B 互换 |
| DRI3 零拷贝（补丁后） | **58.6** | ✅ |

实测跑通的真实程序：**植物大战僵尸**（原生 arm64，游戏自带计数器 `Avg FPS 183`）、
**王国保卫战**（LOVE 0.10.2，中文正常）、**人力资源机器**（Mono/FNA + box64）。

---

## 12. 踩坑总表

| # | 现象 | 原因 | 对策 |
|---|---|---|---|
| 1 | 服务端 `return 64` / `65` | 环境变量约束 | 必须 `MOBILEGL_IPC_DIAL=no`；不能继承 `MOBILEGL_TRANSPORT`/`IPC_SERVER_PATH`/`IPC_RING_MB`/`IPC_STAGE_MB` |
| 2 | 客户端 `errno=111` | 服务端 endpoint 写了 `unix:@x`，它不剥前缀，建成了真文件 | 服务端写 `@x`，客户端写 `unix:@x` |
| 3 | 客户端 `Fatal{CapsBeforeFirstSnapshot, "TextureResources"}` 直接 abort | server 不在时 MobileGL 不会优雅回退 | 跑任何 GL 程序前先 `ensure-server.sh` |
| 4 | `glXCreateContext failed`，日志 `EnsureNativeContext: the EGL display did not initialize` | `DirectGLES`（Espryt）在 bionic 进程里连不上 Mali 的 EGL display | 用 `MOBILEGL_BACKEND_TYPE=DirectVulkan`（Magma） |
| 5 | 编不过：`AHardwareBuffer_allocate ... unavailable: introduced in Android 26` | Termux 默认 triple 是 android24 | `-DCMAKE_{C,CXX}_COMPILER_TARGET=aarch64-linux-android26` |
| 6 | 编译把手机内存吃光，LMK 连 shell 一起杀 | 两侧同时 `-j` 编译 | 串行编译；单侧 `-j2`~`-j4`；`pkill -9 -x clang`（**不要** `pkill -f clang`，会杀掉自己的 shell） |
| 7 | 配置报 `ENABLE_OPT set but SPIR-V tools not found` | glslang 的 `External/spirv-tools` 缺失 | 按 `known_good.json` 拉 spirv-tools + spirv-headers（见 §4） |
| 8 | 配置报 `<ska/flat_hash_map.hpp>` 找不到 | `include/ska` 是空 submodule | 手工 `git fetch` 到 `21c1cec` |
| 9 | 编不过 gbm 相关 | 缺 gbm 头 | 不装 `libdrm-dev`/`libgbm-dev`，让 CMake 自己跳过 gbm 模块 |
| 10 | `ninja` 每次都把 700 个目标当脏，10 分钟编不完 | `.ninja_log` 不同步 | 改单文件时从 `compile_commands.json` 取原始命令单编，再用 `ninja -t commands <target> \| tail -1` 单链接 |
| 11 | 改了 `ShaderSourceProcessor` 只重编服务端，错误照旧 | shader 文本两侧都处理 | **glibc 和 bionic 都要重编** |
| 12 | 服务端建会话 SIGSEGV | 给 `VulkanRenderer` 加了数据成员却只重编了两个 TU（`sizeof` 变了两边不一致） | 加状态别动类布局，放到文件内 `static` |
| 13 | X 服务器拒绝共享图像：`X error 11, major 147 minor 7` | `PixmapFromBuffers`（DRI3 1.4 带 modifier）被 termux-x11 拒 | 补丁：modifier 先试真值，失败回退 `1274 (RAW_MMAPPABLE_FD)` |
| 14 | pixmap 导入成功但画面是条纹噪声 | `AHardwareBuffer` 的 `fd[0]` 不可 mmap（`ENODEV`），可映射的是 `fd[1]`；且 GPU-only usage 给的是 AFBC 压缩布局 | 补丁：`fstat` 挑非 socket 且大小 >0 的 fd；颜色 usage 加 `CPU_READ_OFTEN` 逼平台给线性布局 |
| 15 | 画面正常但 R/B 互换 | X 侧按 BGRA 解释，MobileGL 的 AHB 是 `R8G8B8X8_UNORM`；把 AHB 直接申请成 BGRA 又不行（Mali 不提供 VkFormat，`external format only`） | 补丁：先 `vkCmdBlitImage` 进 BGRA 中间图（做通道交换）再 `vkCmdCopyImage` 搬字节 |
| 16 | 服务端起不来：`cannot locate symbol "vkCreateAndroidSurfaceKHR"` | `vulkan-loader-generic` 顶替了 `$PREFIX/lib/libvulkan.so`（不再是 → `/system/lib64/libvulkan.so`） | `pkg uninstall vulkan-loader-generic`，装回 `vulkan-loader-android` |
| 17 | GLAD/GLEW 类程序 `call NULL` 崩（LOVE 的 `glMatrixMode`） | `GetProcAddress` 表只列了 1399 个名字，实际导出 2952 个 | 补丁：查不到时 `dlsym(RTLD_DEFAULT, name)` 兜底 |
| 18 | `'gl_ModelViewProjectionMatrix' : undeclared identifier` | MobileGL 不提供兼容档内建矩阵，Vulkan 的 glslang 也没有 | 补丁：把 `gl_*Matrix` 改名成 `mg_*` 并注入 uniform，矩阵由 CPU 矩阵栈上传 |
| 19 | `Fragment output 'mg_FragColor' location range [8, 9) exceeds GL_MAX_DRAW_BUFFERS 8` | 只要出现 `gl_FragData` 字样（哪怕只是 `#define` 别名）就声明 8 个输出 | 补丁：只有真正带下标 `gl_FragData[` 才声明数组 |
| 20 | `Could not create font texture!`（LOVE 字体） | `GL_LUMINANCE8_ALPHA8` 等亮度格式返回 `GL_INVALID_ENUM` | 补丁：内部格式映射到 `R8`/`RG8`，采样期靠 swizzle 还原语义 |
| 21 | 帧率稳定贴 60 | Present 按 X 的 vblank 节拍走 | `libnovsync.so` 拦 `glXSwapInterval*`/`glXSwapBuffers` 强制 interval=0 |
| 22 | `CANNOT LINK EXECUTABLE "dbus-launch": library "libc.so.6" not found` | proot 的 `PATH` 末尾有 Termux bin，容器里没装 `dbus-x11` 时用了 bionic 版 dbus-launch，又继承了 glibc 的 `LD_PRELOAD` | 容器装 `dbus-x11`；桌面会话默认不要预载 glibc shim |
| 23 | App 显示"未连接" | X 服务器被脚本退出带走；App 缓存旧连接 | X 服务器用 `setsid` 脱离脚本；起 Activity 前 `am force-stop` |
| 24 | 脚本以为 X 在跑，结果 `Can't open display` | socket 文件残留但服务器已死 | 探测要真 `connect()` 一次，别只看文件存在 |
| 25 | `if ! cmd \| tail -3` 永远成功 | 管道退出码是最后一个命令的 | 先捕获输出和 `$?` 再判断 |

---

## 13. 卸载 / 回退

```bash
. ~/mgl/env.sh stop          # 容器里撤销 GL 覆写，回到 Mesa
bash ~/mgl/stop-server.sh    # 停 GPU 服务端
pkill termux-x11             # 停 X（桌面随之退出）
```

想彻底不用 split（省内存、但只能软渲染）：把 `MOBILEGL_TRANSPORT` 设成 `monolith` 即可同进程运行，
注意那时 server 进程和客户端是同一个（这种情况下 GL 也在 bionic 侧执行，容器里跑不了）。

---

## 14. 文件清单（部署到 `~/mgl/`）

```
~/mgl/
├── start-server.sh       起服务端（Termux 侧）
├── ensure-server.sh      探测 + 自愈（连抽象 socket，不看 pidfile）
├── stop-server.sh        停服务端
├── env.sh                客户端环境（. env.sh / . env.sh stop）
├── mgl-run.sh            Termux 侧一行跑任意 GL 程序：ensure-server + 进 proot + 注入
├── legacy.sh             同上，额外注入 libfixfunc.so（GL 1.x 程序）
├── lib/libfixfunc.so     GL 1.x 兼容层
├── lib/libnovsync.so     垂直同步旁路
├── cc_server.sh          单文件重编（从 compile_commands.json 取原始命令）
├── cc_backend.sh         同上，后端目录用
├── link_so.sh / link_srv.sh   单目标重链
└── mobilegl-*.patch      MobileGL 源码补丁
```

---

## 15. 许可与致谢

- MobileGL：<https://github.com/MobileGL-Dev/MobileGL>（dev 分支）
- Termux:X11：<https://github.com/termux/termux-x11>
- 本文的补丁基于 MobileGL `2bdbe05` 与 Termux:X11 `d366d40`，**上游更新后可能需要重新适配**；
  diff 都很小（DRI3 4 文件、兼容性 12 文件），照着上面的坑位表改不困难。
- 所有内容都在本机无 root 环境下实测；换设备（Adreno / PowerVR）时主要差异在
  AHB 的 fd 布局和 modifier 语义，§12 的 13~15 条请重新验证。

## 16. EGL 程序（视频播放器、部分浏览器）

MobileGL 的 EGL 原本只有 Wayland 与 surfaceless 平台，X11 下的 EGL 窗口表面会直接把 X 窗口 id
交给服务端 —— 而服务端在 Android 上，那个 id 毫无意义，会话当场段错误。§2 的架构决定了：
**客户端只负责把帧送到 X 服务器**，所以 EGL 窗口表面也要照 GLX 那套走。

- 新增 `MG_Impl/GLXImpl/X11WindowPresent.{h,cpp}`：X11 窗口对 GLX 与 EGL 是同一个可绘制对象，
  EGL 窗口表面复用 `X11Present` 链（DRI3+Present / MIT-SHM / PutImage 三级回退）。
- `eglCreateWindowSurface` 与 `eglCreatePlatformWindowSurface` 在识别出 X11 目标后，
  建一个**同尺寸的 pbuffer** 离屏渲染，再 `Attach` 到窗口上；`eglSwapBuffers` 时把当前
  draw framebuffer 拷进链里送到 X 服务器。`eglDestroySurface` 时摘掉。
- 平台变体的 `native_window` 有时是**指向 Window 的指针**（mpv、ANGLE 这类），
  解析器会按"高 32 位非零即指针"解引用重试。

验证（本机）：

| 程序 | 结果 |
|---|---|
| `eglwin`（自有探针） | `GL_RENDERER=Magma (MobileGL Core) …`，清屏色 `srgb(51,153,229)` 与 `glClearColor(0.2,0.6,0.9)` 一致 |
| `es2_info` | `EGL_VENDOR: MobileGL`、`GL_RENDERER: Magma …` |
| `mpv --vo=gpu --gpu-context=x11egl` | `VO: [gpu] 320x240 rgb24`，testsrc 彩条正确（`~/mgl/mpv_egl_window.png`） |
| Chromium（ANGLE→GLX） | 仍是 Magma，未被改坏 |

体检：`~/mgl/gpu-check.sh` 会把 GLX 与 EGL 两条路的渲染器串都打出来，两处都是 `Magma` 才算全 GPU。
