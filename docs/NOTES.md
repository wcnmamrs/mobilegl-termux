# MobileGL on Termux + proot 实测记录

TFY-AN00 / 天玑 700 / Mali-G57 MC2 / Android 12 / 无 root
MobileGL `dev` @ `2bdbe052`，bionic server + glibc client，split over `unix:@mobilegl`

## 结论

**技术完全跑通，但在 termux-x11 上性能不如 virpipe。**

MobileGL 拿到 OpenGL **4.6**（virpipe 封顶 4.3 COMPAT），后端 `Magma (MobileGL Core)` 直连
Mali 的 `Vulkan 1.1.177`，`direct rendering: Yes`，扩展含 tessellation / compute / DSA / subgroup。

但 X11 呈现被迫走 readback，大窗口帧率只有 virpipe 的 ~28%。

## 性能实测

glmark2 800×600（同一 X server）：

| 场景 | virpipe | MobileGL |
|---|---|---|
| build use-vbo=false | 119 | 29 |
| texture linear | 132 | 32 |
| shading gouraud | 107 | 33 |
| bump high-poly | 139 | 29 |
| desktop blur | 81 | 29 |
| terrain | 41 | — |
| jellyfish | 127 | — |

glxgears 窗口尺寸扫描（MobileGL）：

| 窗口 | FPS | 有效带宽 |
|---|---|---|
| 200×200 | 187 | 30 MB/s |
| 400×300 | 99 | 47 MB/s |
| 800×600 | 30 | 58 MB/s |
| 1200×900 | 12 | 52 MB/s |

FPS 严格反比于像素数，吞吐恒定 ~50 MB/s —— 固定带宽瓶颈，不是绘制效率问题。

## 根因链

1. MobileGL 正确选择了零拷贝路径，所有前置条件都满足：

   ```
   glx: window 0x1400002 (400x300, depth 24) presented through DRI3+Present shared images
        (DRI3 1.2, Present 1.2, MIT-SHM 1.2, local connection, shared images yes)
   ```

2. termux-x11 拒绝 import：

   ```
   glx: the X server refused a 400x300 shared image as a pixmap (X error 11, major 147 minor 7)
   glx: window 0x1400002 leaves DRI3+Present: the X server refused the shared image as a DRI3
        pixmap; its frames are read back from now on
   ```

   `major 147` = DRI3，`minor 7` = `PixmapFromBuffer`，`X error 11` = BadAlloc。
   termux-x11 无法把 MobileGL 的 dma-buf 导入成 pixmap。

3. 降级到 readback 后，split 架构要搬两次：

   ```
   MobileGL: GPU → server 内存 → IPC ring → client 内存 → X SHM
   virpipe:  GPU → virgl server 内存 → X SHM
   ```

   带宽比 58 vs 211 MB/s ≈ 3.6×，与 FPS 差完全吻合。

## 交叉点

约 300×300 以下 MobileGL 与 virpipe 相当，再大就被反超。
桌面本身（XFCE）不用 OpenGL，两者对桌面体验无差别 —— 差别只在 GL 应用。

## 用法

```bash
~/mgl/switch.sh mobilegl   # 停 virgl，起 MobileGL server
~/mgl/switch.sh virpipe    # 停 MobileGL server，起 virgl_test_server_android
~/mgl/switch.sh status
~/mgl/switch.sh bench
```

client 侧（proot 内）先 `source ~/mgl/env.sh`，或直接用 `~/mgl/xfce-mobilegl.sh` 起整套桌面。

切链路后已启动的 GL 进程仍用旧环境，需要重启那些进程（桌面要重开 XFCE 会话）。

## 文件

| 路径 | 用途 |
|---|---|
| `~/mgl/start-server.sh` | 起 bionic MobileGL server，`@mobilegl` 抽象 socket |
| `~/mgl/env.sh` | proot 侧 client 环境；`source ~/mgl/env.sh stop` 全部 unset |
| `~/mgl/xfce-mobilegl.sh` | 完整 MobileGL 桌面链路 |
| `~/mgl/switch.sh` | 两套链路切换 |
| `~/ahb/abtest.c` | 抽象 socket 连通性测试 |
| `~/src/MobileGL/build-glibc/` | glibc client（含 symlink 与 `libGLX_mobilegl.so.0`） |
| `~/src/MobileGL/build-bionic/` | bionic server（`libMobileGLServer.so`，6 KB main 转发） |

日志：server 写 `/storage/emulated/0/MG/latest.server.log`；
client 需显式 `MOBILEGL_LOG_FILE_PATH=/tmp/x.log`，实际文件是 `/tmp/x.client.log`。

## 踩过的坑

- **server 的 endpoint 参数不剥 `unix:` 前缀**，写 `unix:@mobilegl` 会在 cwd 建一个名为
  `unix:@mobilegl` 的真实 socket 文件，client 连不上。server 侧要写 `@mobilegl`。
- **Espryt（DirectGLES）在 bionic server 里起不来**：`EnsureNativeContext: the EGL display
  did not initialize`。Termux 进程（`untrusted_app_27`）连不上 Mali 的 EGL display，
  只有 Vulkan 可用 —— 这正是 `virgl_test_server_android` 必须带 `--angle-vulkan` 的原因。
  **必须用 `MOBILEGL_BACKEND_TYPE=DirectVulkan`**。
- **没有 server 时 client 不会优雅回退**，直接 `Fatal{CapsBeforeFirstSnapshot, "TextureResources"}`
  abort。必须先起 server 再跑任何 GL 客户端。
- **`MOBILEGL_IPC_RING_MB` / `IPC_STAGE_MB` / `IPC_SERVER_PATH` / `MOBILEGL_TRANSPORT`
  不能出现在 server 环境里**，否则退出码 65；`MOBILEGL_IPC_DIAL` 必须是 `no`，否则 64。
- **`pkill -9 -f <pattern>` 会匹配到自己 shell 的命令行**导致自杀。
  用 `pkill -9 -x <comm>` 或 ps+awk 取 pid。
- **`3rdparty/glvnd` 不是 submodule**，是仓库内 tree，rm 掉会编译失败，`git checkout -- 3rdparty/glvnd` 恢复。
- **`include/ska` 在 dev 分支是空 submodule**，需手工 fetch `21c1cec95abee1beef827e4a7c95f692875d9594`
  （源 `MobileGL-Dev/flat_hash_map`）。
- **glslang 的内嵌 spirv-tools 官方 CI 不拉**，缺则 configure 直接 SEND_ERROR。按
  `3rdparty/glslang/known_good.json` 钉版本：SPIRV-Tools `33e02568181e3312f49a3cf33df470bf96ef293a`、
  SPIRV-Headers `2a611a970fdbc41ac2e3e328802aed9985352dca`。
- **bionic 侧 `-O3` 编译会 OOM**（MemAvailable 仅 ~2GB）。用 `-O1` + `-j2`，
  内存紧张时 glibc/bionic 两侧**串行**编，否则 LMK 会连 shell 一起杀。
- **bionic 必须 `-DCMAKE_C(XX)_COMPILER_TARGET=aarch64-linux-android26`**，
  Termux 默认 triple 是 android24，会导致 `AHardwareBuffer_allocate` 等 API 编不过。

---

# DRI3 零拷贝修复（2026-11-21 深夜）

## 四个根因（全部定位并修复）
1. **fd 选错**：`AHardwareBuffer` native handle 里 `fd[0]` 不可 mmap（ENODEV）、`fd[2]` 是 socket，可映射的是 `fd[1]`。原代码取 `fds[0]` → Xlorie `mmap` 失败 → `BadAlloc`。
   修：`SharedImageRegistry.cpp` `AllocateNative` 遍历 fds，`fstat` 跳过 `S_ISSOCK` 与 `st_size<=0`。
2. **modifier 协商**：MobileGL 发真实 modifier（实测 `0xffffffffffffff` = DRM_FORMAT_MOD_INVALID），termux-x11 只认 `RAW_MMAPPABLE_FD`(1274) 与 `AHARDWAREBUFFER_SOCKET_FD`(1255)。
   修：`X11PresentXcb.cpp` `ImportPixmap` 二次尝试，第一发真实 modifier、被拒后退 1274。
3. **AFBC 压缩布局**：GPU-only usage 下 gralloc 给压缩布局，mmap 看到条纹噪声。
   修：颜色 usage 补 `AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN`（只为拿到线性布局）。
4. **通道顺序**：XRGB8888/ARGB8888 的内存序是 B,G,R,A，而 Mali 的 AHB 只能是 RGBA8（BGRA8888 无 VkFormat，实测 "external format only"）。
   修：`WireSharedImage.cpp` 增加 BGRA 中间图——blit 完成 R/B 交换，再 `vkCmdCopyImage` 逐字节搬到 AHB。

## 结果（glxgears 800x600）
| 路径 | FPS | 颜色 |
|---|---|---|
| readback + PutImage | 30.2 | 正确 |
| DRI3 零拷贝（修复前，乱码） | 55.4 | 错误 |
| DRI3 零拷贝（线性后） | 59.4 | R/B 互换 |
| **DRI3 零拷贝 + 通道修复** | **58.6** | **正确** |

即：**零拷贝带来 2× 提升，通道修复几乎无成本（58.6 vs 59.4）**。virpipe 参照 ~110 FPS。

## 验证方法
`~/x11work/glxtest4.c`（GLSL+VBO 渐变三角形，mode 0=swap / 1=自绘 XPutImage / 2=纯红）、`t4.sh`/`t5.sh` 截图脚本。
判据：`xwd` 抓屏后窗口内 `unique` 数量与中心色要与 `glReadPixels` 完全一致；Mesa llvmpipe 同程序作对照基准。
证据图：`~/mgl/dri3_colors_fixed.png`（中心 `srgb(128,64,64)` = GL 读回的 `127,64,64`）。

## 更正：glxgears 不能用来评判 MobileGL（2026-11-22 00:40）

之前"MobileGL 58 FPS vs virpipe 110 FPS"的结论**是错的**，因为 glxgears 在 MobileGL 上根本画不出东西：

```
Stub function: glVertex3f / glTranslatef / glRotatef / glNewList / glShadeModel / glNormal3f / glPushMatrix / glPopMatrix
```

Magma（DirectVulkan）把 GL 1.x 固定管线立即模式实现成空 stub，glxgears 全靠 `glBegin/glVertex3f/glEnd` 画齿轮 → 窗口全黑，那 59.7 FPS 只是"清屏 + swap"的呈现节奏（稳定贴在 60 附近），不是渲染性能。

### 换 glmark2（现代 GL：VBO + GLSL）重新对比，800x600，同机同 X server
| 场景 | virpipe (virgl+ANGLE) | MobileGL (Magma, DRI3 零拷贝) | 倍数 |
|---|---|---|---|
| build use-vbo=false | 114 | **251** | 2.2× |
| texture | 115 | **407** | 3.5× |
| shading | 117 | **403** | 3.4× |
| desktop | 56 | **169** | 3.0× |
| **glmark2 Score** | **99** | **306** | **3.1×** |

glxgears 800x600 对照（仅供参考，MobileGL 侧为空转）：virpipe 107.9 FPS / MobileGL 59.7 FPS。

### 结论
- **现代 GL 应用（VBO + 着色器）：MobileGL 约为 virpipe 的 3 倍**，因为 Mali Vulkan 直连 + dma-buf 零拷贝呈现，比 virpipe 的 `GL → virgl 命令流 → GLES → ANGLE → Vulkan` 少三层转译。
- **老式固定管线应用（glBegin / 显示列表 / glVertexPointer 客户端数组）：MobileGL 画不出来（stub），必须留在 virpipe。**
- XFCE 桌面本身走 XRender 不走 GL，两条链路无差别。

## 解决方案：给 Magma 补上固定管线（libfixfunc.so）

Magma（DirectVulkan）把整个 OpenGL 1.x 固定管线实现成 stub：

```
Stub function: glBegin / glVertex3f / glEnd / glNewList / glRotatef
Stub function: glTranslatef / glNormal3f / glShadeModel / glVertexPointer ...
```

所以 glxgears 这类老程序在 MobileGL 上一个三角形都画不出来。**不动 MobileGL 一行代码**的解法：
一个 `LD_PRELOAD` 兼容层（源码 `~/x11work/fixfunc/fixfunc.c`，产物 `~/mgl/lib/libfixfunc.so`，76 KB）。

它把固定管线翻译成核心 profile 已有的能力：

| 拦截的 API | 翻译成 |
|---|---|
| `glBegin/glVertex*/glColor*/glNormal*/glEnd` | 记录顶点 → `glDrawArrays` + 一个 GLSL 1.20 着色器 |
| `GL_QUADS`/`GL_QUAD_STRIP`/`GL_POLYGON` | 展开成三角形 |
| `glMatrixMode/glLoadIdentity/glTranslatef/Rotatef/Scalef/Ortho/Frustum/MultMatrixf` | CPU 矩阵栈（投影/模型视图/纹理各一套，深度 64）→ `uMVP` uniform |
| `glPushMatrix/glPopMatrix` | 同上（含显示列表内重放） |
| `glNewList/glCallList/glCallLists/glGenLists/glDeleteLists` | 录制命令脚本（矩阵操作 + 绘制），调用时重放 |
| `glVertexPointer/glColorPointer/glNormalPointer` + `glDrawArrays` | 客户端数组拷进 VBO 再画（VBO 绑定非 0 时原样转发） |
| `glMaterialfv/glColorMaterial` + `glEnable(GL_LIGHTING)` | 用材质漫反射色当基色，片元做简单头灯着色 |
| `glXGetProcAddress` | 为上述名字返回本库的入口，其余转发 |

### 效果（800×600，同机同 X server）
| | FPS |
|---|---|
| virpipe（virgl+ANGLE）glxgears | 108 |
| MobileGL 无 shim | 画不出来（黑屏），swap 空转 59 |
| MobileGL + libfixfunc，默认 swapInterval=1 | 59（vsync 节拍） |
| **MobileGL + libfixfunc，`-swapinterval 0`** | **342** |

glmark2（现代 GL，带 preload）Score 337 vs 306 → shim 对现代程序零影响。

**关键发现**：那个稳定的 59 FPS 不是性能上限，是 `X11Present.cpp:252` 的
`targetMsc = m_lastMsc + swapInterval` 在按 X 的 vblank 走；`glXSwapIntervalEXT/MESA(0)` 立刻就解锁。

### 用法
```bash
~/mgl/legacy.sh glxgears -geometry 800x600          # 单个老程序
MGL_LEGACY=1 source ~/mgl/env.sh                    # 整个会话都带上兼容层
```

### 纹理（已支持，2026-11-22 上午）
| 拦截的 API | 处理方式 |
|---|---|
| `glTexCoord1f/2f/3f/4f/2d/2fv/2dv/1fv` + `glMultiTexCoord*`（仅 unit 0） | 记进顶点，进 shader 的 `aTexCoord` |
| `glBindTexture` / `glActiveTexture` | 记账当前 2D 纹理，绘制时临时绑到 unit 0 再还原 |
| `glTexEnvi/f(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, ...)` | 记 MODULATE/REPLACE/DECAL/BLEND，片元里按模式混合 |
| `glTexImage2D` 的**未定尺寸内部格式**（`GL_RGBA`/`GL_RGB`/`GL_BGRA`） | 翻译成 `GL_RGBA8`/`GL_RGB8`（核心 profile 拒绝旧写法，这是老程序上传纹理必踩的坑） |
| `glTexCoordPointer` + `glEnableClientState(GL_TEXTURE_COORD_ARRAY)` | 客户端数组拷进 VBO |

验证程序 `~/x11work/fixfunc/texquad.c`（老写法：`glBegin(GL_QUADS)` + `glTexCoord2f` + 未定尺寸 `GL_RGBA` 上传 2×2 棋盘）：
- `glReadPixels`：`BL=255,0,0` / `BR=0,255,0` / `TL=0,0,255`，与预期一致
- `xwd` 截图裁窗：`unique=4`（四个纯色象限，无串色无渗漏），证据图 `~/mgl/texquad_shot.png`

### 已知未覆盖
- 多纹理单元只接 unit 0（`glMultiTexCoord*` 对 unit≠0 忽略）
- 纹理矩阵（`glMatrixMode(GL_TEXTURE)` 有栈但不参与 shader）、`GL_COMBINE`/`GL_ADD` 纹理环境、1D/3D 纹理、`glCopyTexImage`
- 光照是头灯近似，不是完整 GL 光照模型（多光源/聚光/衰减没有）
- `glDrawPixels`/`glRasterPos`/`glBitmap` 未实现

---

## 日用化（2026-11-22 上午）

让 MobileGL 从"能跑"变成"随手能用"。三件事：

### 1. server 自愈：`ensure-server.sh`

```bash
bash ~/mgl/ensure-server.sh          # 活着就退出 0，死了/半死就重启
bash ~/mgl/ensure-server.sh status   # 只报告
```

探测方式是连抽象 socket（Python `AF_UNIX` + `\0` 前缀），**不是看 pidfile**——server 可能在 listen 之前就挂了，pid 还活着但 socket 没人应答。

**为什么必须做这件事**：split 链路里 server 缺席时 MobileGL 不优雅回退，而是
`Fatal{CapsBeforeFirstSnapshot, "TextureResources"}` → abort。根因在
`MobileGL/MG_Backend/Init.cpp:372` `InitSplitRolesBeforeState()`：
`if (Transport == Monolith) return false; InitSplitBackend(); return true;` —— 无条件返回 true。

### 2. 通用启动器：`mgl-run.sh`

```bash
~/mgl/mgl-run.sh glmark2 -s 800x600
~/mgl/mgl-run.sh <proot 里任意 GL 程序> [参数...]
```

顺序：Termux 侧 `ensure-server` → 进 proot → `source env.sh` → `exec 目标`。

**踩坑（重要）**：**不能在 proot 内部拉起 server**。PRoot 用 ptrace 盯着子进程，从 proot 里
`setsid` 起的 server 会随 proot 会话退出一起被杀——实测当次 `glxinfo` 能跑通，退出后
server 就没了（`pidfile` 指向的进程已消失，socket 拒绝连接）。所以 `env.sh` 现在只**探测**并
警告，拉起动作一律放在 Termux 侧。

### 3. 关垂直同步：`libnovsync.so`

```bash
MGL_NOVSYNC=1 ~/mgl/mgl-run.sh glxgears -geometry 800x600
```

MobileGL 的 Present 按 X 的 vblank 节拍走（`X11Present.cpp:252`
`targetMsc = lastMsc + swapInterval`、`:253` `options = swapInterval > 0 ? 0 : kPresentOptionAsync`），
默认 swapInterval=1 就是硬锁 60Hz。`libnovsync.so`（源码 `~/x11work/fixfunc/novsync.c`）
接管 `glXSwapIntervalEXT/MESA/SGI` 与 `glXSwapBuffers`，把 interval 一律压成 0。

实测 glxgears 800x600：**59.7 → 376.7 FPS**（走 `mgl-run.sh`：393 / 222 FPS）。

只覆盖 `glXGetProcAddress` 查这几个名字是不够的——glxgears 这类程序只有在
`-swapinterval` 参数下才主动调，所以还要在 `glXSwapBuffers` 里自己压一次。

### 组合

```bash
# 老程序 + 全速
MGL_LEGACY=1 MGL_NOVSYNC=1 ~/mgl/legacy.sh glxgears -geometry 800x600
# 现代程序 + 全速
MGL_NOVSYNC=1 ~/mgl/mgl-run.sh glmark2 -s 800x600
```

---

## 三个真实游戏跑通（2026-11-22 中午）

用户的实际用法：**proot 里跑游戏和桌面**（`/root/pvz`、`/root/HumanResourceMachine`、`/root/Kingdom_Rush`）。
三款全部在 MobileGL（Magma + DRI3 零拷贝）下出画面：

| 游戏 | 引擎 | 结果 | 备注 |
|---|---|---|---|
| 植物大战僵尸 `/root/pvz/pvz` | 原生 arm64 + SDL2 | **Avg FPS 183**，标题界面正常 | 游戏自带计数器 |
| 王国保卫战 `/root/Kingdom_Rush` | LOVE 0.10.2 | 设置界面正常、字体清晰 | 原 `run.sh` 强制 llvmpipe，需去掉 |
| 人力资源机器 `/root/HumanResourceMachine` | Mono/FNA + box64 | 标题界面正常 | `box64 ./HumanResourceMachine.bin.x86_64` |

### 为此补的三处 MobileGL 兼容缺口（`~/mgl/mobilegl-compat.patch`）

1. **GetProcAddress 覆盖度**（`MobileGL/MG_Impl/GetProcAddress.cpp`）
   库导出 2952 个 `gl*` 符号，查找表只有 1399 条 → GLAD/GLEW 逐个询问时拿到 NULL，call NULL 崩。
   兜底：名字以 `gl` 开头就 `dlsym(RTLD_DEFAULT, ...)`。
   *没有这条，LOVE 0.10 在 `setupContext()` 里 `glMatrixMode(GL_MODELVIEW)` 就 SIGSEGV。*

2. **兼容档矩阵栈**（`MG_Impl/GLImpl/Exporting/Definitions.cpp` + `MG_Util/ShaderTranspiler/ShaderSourceProcessor.cpp`）
   原实现把 `glMatrixMode/glLoadIdentity/glOrtho/glPushMatrix/...` 全做成空 stub；Vulkan 的 glslang 也不提供
   `gl_ModelViewProjectionMatrix` 这族内建 → 兼容档 shader 直接 `undeclared identifier`。
   现在：CPU 侧维护 proj/mv/tex 三套 4×4 矩阵栈（含 push/pop、Ortho/Frustum/Rotate/Scale/Translate），
   shader 侧把内建名改写成 `mg_*` uniform，每次 draw 前按 program 缓存上传（mvp = P×MV、normal = MV 逆转置）。
   *注意：上传走内部 `MG_Impl::GLImpl::` 入口，公开入口会再取一把非递归锁 → 自死锁。*

3. **亮度纹理格式**（`MG_Util/Converters/GLToMG/TextureEnumConverter.cpp` + `MG_Impl/GLImpl/Texture/GL_Texture.cpp`）
   `GL_LUMINANCE / GL_LUMINANCE_ALPHA / GL_LUMINANCE8_ALPHA8 / GL_ALPHA8` 原先返回 `GL_INVALID_ENUM`。
   LOVE 的 TrueType 字体图集正是 `GL_LUMINANCE8_ALPHA8` + `GL_LUMINANCE_ALPHA`，于是
   `newFont` 抛 `Could not create font texture!`。
   现在：存储降级到 R8/RG8，采样时用 VkComponentMapping 重排 —— LA → (R,R,R,G)、L → (R,R,R,1)、A → (0,0,0,R)。

另外修了 `gl_FragColor` 与 `gl_FragData` 同时声明导致的
`Fragment output 'mg_FragColor' location range [8, 9) exceeds GL_MAX_DRAW_BUFFERS 8`：
宏别名（`#define love_Canvases gl_FragData`）没有下标访问时不再为它声明 8 个输出。

### 用法
```bash
~/mgl/ensure-server.sh                      # 起/复活 server（Termux 侧）
~/mgl/mgl-run.sh glxinfo -B                 # 任意 GL 程序
~/mgl/legacy.sh glxgears -info              # 带固定管线兼容层（glBegin 那一族）
# 王国保卫战：先去掉 run.sh 里的 LIBGL_ALWAYS_SOFTWARE/GALLIUM_DRIVER 两行
~/mgl/mgl-run.sh box64 /root/HumanResourceMachine/HumanResourceMachine.bin.x86_64
```

---

## Chromium 里的 GPU（2026-11-22 中午）

容器里 `chrome://gpu` 全灰不是"没有 GPU"，是它拿不到 GL：Chromium 的 ANGLE 用 **GLX** 要
上下文，而 MobileGL 的 GLX 层有三处不满足它，任何一处失败 ANGLE 就退到 SwiftShader。

### 三处根因（都已补进 MobileGL）
| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | `Could not find a decent GLX FBConfig to create the context` | ANGLE 传 `GLX_DRAWABLE_TYPE = WINDOW\|PBUFFER\|PIXMAP`，原 chooser 见到窗口位以外的位就整排否决 | 只把"没有窗口位"当不匹配；配置对外报 `WINDOW\|PBUFFER` |
| 2 | `Could not create the initialization pbuffer` | ANGLE 初始化时建一个 1×1 pbuffer 并 `glXMakeCurrent` 上去问版本，而 `glXCreatePbuffer` 是返回 0 的 stub | 实现 pbuffer drawable（尺寸表 + 走同一套 EGL pbuffer 表面），`glXDestroyPbuffer` 一并实现 |
| 3 | `Invalid visual ID requested`（窗口模式） | Chromium 通过 `EGL_X11_VISUAL_ID_ANGLE` 指名窗口的 visual，ANGLE 遍历所有 FBConfig 比对 `GLX_VISUAL_ID`；原来两个固定配置只报默认 visual | 按 server 的 TrueColor visual 逐 visual 建表（24/32 位 × stencil 8/0），`GLX_VISUAL_ID` 报自己的 visual |

### 用法
```sh
# 桌面会话里直接跑（env.sh 已由 xfce.sh 注入）；后端由 /etc/chromium.d/50-mobilegl 决定
chromium
chromium --app=https://example.com
```
开关写在 `/etc/chromium.d/50-mobilegl`（唯一事实来源）：
`--use-gl=angle --use-angle=gles --ignore-gpu-blocklist --no-sandbox --disable-dev-shm-usage`。

> **`--use-angle=gles` 不能换成 `gl`。** ANGLE 的桌面 GL 后端在 Linux 走 GLX：上下文能创建、
> `glClear` 也生效，但 `glDrawArrays` 的几何**不落进 canvas**（`readPixels=0,0,0,255`），
> 所有真 3D 站点因此空白。换 GLES 后端后 `readPixels=0,255,0,255`，get.webgl.org 正常出立方体。
>
> **桌面会话里必须 `unset __GLX_VENDOR_LIBRARY_NAME`。** 这个变量由 `/etc/profile.d/mobilegl.sh` 设成
> `mobilegl`，让 GLX 程序走我们的 GLX 层——但 Chromium 的 GL 初始化会先尝试 "GLX 上的 OpenGL ES"，
> 而我们的 GLX 层没有 `GLX_EXT_create_context_es_profile`，于是这条尝试失败并连带整条 EGL 初始化链
> 全灭（页面看到的就是 `BindToCurrentSequence failed`、`VENDOR = 0xffff`）。所以
> `/etc/chromium.d/50-mobilegl` 第一行就是 `unset __GLX_VENDOR_LIBRARY_NAME`：
> Chromium 改走 glvnd EGL → MobileGL EGL，合成与 WebGL 都仍在 Mali 上。
>
> `/usr/local/bin/chromium-gpu` 现在**只做透传**（`exec /usr/bin/chromium "$@"`）。早先它自己也写了一套
> `--use-angle=gl`，与 `chromium.d` 里的旗标打架——两套旗标谁生效取决于 Chromium 的解析顺序，
> 于是同一个浏览器有时候能画、有时候报 `BindToCurrentSequence failed`。现在只留一处。

### 实测
WebGL 渲染器串：`ANGLE (MobileGL-Dev (BZLZHH Swung0x48 Tungsten), Magma (MobileGL Core) (Mali-G57 MC2 Vulkan 1.1.177 Driver 32.1.0), OpenGL 4.6.0)`
截图 `~/mgl/chromium_gpu_window.png`（紫色 WebGL 画布 + 绿色 HUD 打的就是这串）；`/tmp/cg*.log` 里 EGL 错误数为 0。

### 仍然拿不到 GPU 的部分（不是这次能修的）
- **Video Decode / Video Encode**：要走 Mali 的硬件编解码器，容器里没有那条通路；视频仍是 CPU 解。
- **Vulkan / WebGPU**：容器里没有 Mali 的 Vulkan ICD（Mali 的 Vulkan 只在 bionic 侧），ANGLE 的 Vulkan 后端只会看到 lavapipe。
- 任何不用 GL 的部分（Skia CPU 光栅、字体、DOM）本来就不碰 GPU。

---

## 通用安装：让容器里所有程序自动用 GPU（2026-11-22 中午）

关键事实：**没有为 Chromium 单独打补丁**。三处修复都在 MobileGL 的 GLX 层（`MG_Impl/GLXImpl/`），
任何走 GLX 的程序（SDL2、GLFW、GTK 的 GtkGLArea、ANGLE、游戏）都吃同一份。
剩下的问题只是"怎么让系统自动挑到 MobileGL"，这件事做成了系统级安装：

```sh
bash ~/mgl/install-system.sh          # 安装/更新
bash ~/mgl/install-system.sh remove   # 卸载，回到纯 Mesa
```

它往容器里写这些东西（一次，之后所有程序都不用管）：

| 位置 | 作用 |
|---|---|
| `/opt/mobilegl/lib/libMobileGL.so` | 客户端库（从 `build-glibc` 复制） |
| `/usr/share/glvnd/egl_vendor.d/10_mobilegl.json` | EGL 厂商注册；glvnd 按文件名顺序试，`10_` 在 `50_mesa` 之前 |
| `/usr/lib/aarch64-linux-gnu/libGLX_mobilegl.so.0` | GLX 厂商库（指向同一个 `.so`，导出 `__glx_Main`） |
| `/etc/mobilegl/client.conf` | MobileGL 自己读的配置（transport/endpoint/ring/stage/spin/backend）——**程序不用带环境变量** |
| `/etc/profile.d/mobilegl.sh` + `/etc/environment.d/10-mobilegl.conf` | `__GLX_VENDOR_LIBRARY_NAME=mobilegl`（libglvnd 的选择器，只有环境变量这入口）+ `__EGL_VENDOR_LIBRARY_FILENAMES` |
| `/etc/chromium.d/50-mobilegl` | Chromium 的 `--use-gl=angle --use-angle=gl --ignore-gpu-blocklist --no-sandbox --disable-dev-shm-usage`，Debian 启动器自动读 |

### 验证（都不带任何命令行旗标、不 source 任何脚本）
```
$ proot-distro login debian --shared-tmp -- bash -lc 'glxinfo -B'
OpenGL vendor string: MobileGL-Dev (BZLZHH, Swung0x48, Tungsten)
OpenGL renderer string: Magma (MobileGL Core) (Mali-G57 MC2, Vulkan 1.1.177, Driver 32.1.0)

$ proot-distro login debian --shared-tmp -- bash -lc '/usr/bin/chromium --app=file:///tmp/gltest.html'
窗口 HUD：ANGLE (MobileGL-Dev ..., Magma (MobileGL Core) (Mali-G57 MC2 Vulkan 1.1.177 Driver 32.1.0), OpenGL 4.6.0)  64 fps
```
截图 `~/mgl/chromium_stock.png`（原版 `chromium`，无封装）。

### 优雅退化（装它是安全的）
服务端不在时 MobileGL 的 `ImplementationAvailable()` 返回 0，`__glx_Main` 主动让位，
libglvnd 落到下一个实现（Mesa/llvmpipe）：`glxinfo -B` 显示 `llvmpipe` 而不是崩溃 —— 只掉性能，不掉可用性。

### 通用方案覆盖不到的部分（都属"新功能"，不是"每个程序打补丁"）
- **EGL + X11 的程序**（Firefox 默认路径、部分 SDL2 程序）：MobileGL 的 EGL 只有 Wayland 与
  `EGL_MESA_platform_surfaceless`，**没有 X11 platform**，这类程序会退回 Mesa 软渲染。
  要通用就得给 EGL 补 `EGL_EXT_platform_x11` 的 WSI（呈现可以复用 GLX 那套 DRI3/dma-buf 代码）。
- **Vulkan / WebGPU**：容器里没有 Mali 的 Vulkan ICD（Mali 的 Vulkan 只在 bionic 侧），只能看到 lavapipe。
- **视频硬解/硬编**：要走 Mali 的 V4L2/编解码器，容器里没有那条通路。

## EGL 窗口表面：让走 EGL 的程序也上 GPU（2026-11-22 下午）

### 问题
GLX 程序（glxinfo / glmark2 / Chromium）11:52 起就全 GPU 了，但**默认走 EGL+X11 的程序**
（Firefox、部分 SDL2/Qt/GTK 程序、`es2_info`/`eglinfo`）仍然软渲染或直接起不来：
`es2_info` 报 `eglMakeCurrent() failed`。原因是 MobileGL 的 EGL 只有 Wayland/GBM/surfaceless 平台，
X11 的 EGL 窗口表面根本没有呈现通路（`GetPlatformDisplay` 收到 X11 平台也只是建了个 display）。

### 做法（不新增第二套呈现逻辑）
1. 新文件 `MG_Impl/GLXImpl/X11WindowPresent.h`（+ 追加在 `GLXImpl.cpp` 末尾的实现）：
   把 EGL 的窗口表面接到 GLX 那条链上（`X11Present::Chain`：DRI3+Present → MIT-SHM → PutImage）。
   - `QueryGeometry`：运行时 `dlopen("libX11.so.6")` 取 `XGetGeometry`，不做链接依赖
   - `DefaultXDisplay`：客户端传 `EGL_DEFAULT_DISPLAY` 时 `XOpenDisplay(NULL)`，进程内缓存
   - `Attach/Present/Detach`：按 EGLSurface 记一份 `DrawableSurface`，呈现时把**X 窗口 id**（不是
     surface 句柄）交给链；窗口尺寸变化时 `SyncSurfaceSize(..., force)` 跟上
2. `MG_Impl/EGLImpl/EGLImpl.cpp`：
   - `ResolveX11WindowTarget()`：平台是 `EGL_NONE`（自己传了 Display*）或 `EGL_PLATFORM_X11_KHR(0x31D5)`
     且 `XGetGeometry` 成功，才算 X 窗口
   - `CreateWindowSurface`：X11 窗口改为**建 pbuffer 表面**（尺寸取窗口几何）+ `Attach`。
     关键教训：直接走窗口表面会把 X 窗口 id 发给服务端，而服务端在 Android 上 —— 那是无意义的
     native window，**会话当场 SIGSEGV**（`session pid=… reaped signal=11`）。GLX 早就因为这个原因
     只在 `MakeCurrent` 时懒建 pbuffer 表面，这里照做。
   - `SwapBuffersWithDamage`：在真正的 swap **之前**调 `Present`（链拷的是当前 draw framebuffer）
   - `DestroySurface`：`Detach`

### 验证
- `es2_info`：之前 `eglMakeCurrent() failed` → 现在 `EGL_VENDOR: MobileGL` / `GL_RENDERER: Magma (MobileGL Core) (Mali-G57 MC2, …)`
- 自写 `~/x11work/eglwin.c`（Xlib 建窗 + `eglCreateWindowSurface` + clear + swap）：
  - `eglGetDisplay(Display*)`：`eglMakeCurrent=1`，截图裁窗 `unique=1 center=srgb(51,153,229)`
    （正是 `glClearColor(0.2,0.6,0.9)`）
  - `eglGetDisplay(EGL_DEFAULT_DISPLAY)`：同样 `unique=1 center=srgb(51,153,229)`
  - 日志：`egl: window 0x1400001 (400x300, depth 24) presents through the DRI3/MIT-SHM path of the X server`
    → `glx: … presented through DRI3+Present shared images` → modifier 被拒后 `imported under the mmappable-descriptor name`
- 回归：`glxinfo -B` 与 Chromium headless WebGL 探针仍是 `Magma (MobileGL Core)`，没被改坏

### 体检工具
`~/mgl/gpu-check.sh` 一次报三条路：服务端状态、GLX 渲染器串、EGL 渲染器串（都是 `Magma` 才叫全 GPU）；
`~/mgl/gpu-check.sh <命令>` 用完整环境跑单个程序。

### 仍然不是 GPU 的
视频解码（VA-API 无 Mali ICD）、Vulkan 应用（`vulkaninfo` 在容器里只有 Mesa ICD）、WebGPU/Vulkan 后端。
这些要等 Mali 的 Vulkan 在容器内可见 —— 那是 Android 权限问题，不是 MobileGL 的事。

### EGL 的第二个入口：`eglCreatePlatformWindowSurface`
mpv（`--vo=gpu --gpu-context=x11egl`）、Firefox 一类程序不走 `eglCreateWindowSurface`，
而是走平台变体。同一套 X11 处理也已经接进 `CreatePlatformWindowSurface`。

两个额外踩到的点：

- **客户端可能传"指向 Window 的指针"**。`EGL_EXT_platform_x11` 规范里 `native_window` 就是 `Window`，
  但 mpv / ANGLE 这一系实际传的是指针。`ResolveX11WindowTarget` 因此加了回退：X id 只有 32 位，
  高 32 位非零就当指针，依次试 `*(uint64*)`、`*(uint32*)`，哪个 `XGetGeometry` 成功用哪个。
  实测 mpv 传 `0x7744001ca8` → 解引用得到真窗口 `0x1400002`。
- mpv 自己仍会打 `[vo/gpu/x11] X11 error: BadDrawable … request code: e`（它自己的 Xlib 调用），
  不影响出画面。

### 实测：mpv 播视频
```
mpv --vo=gpu --gpu-context=x11egl av://lavfi:testsrc=size=320x240:rate=30
→ VO: [gpu] 320x240 rgb24
→ 窗口 0x1400002 "…- mpv" 320x240+5+29，截图 unique=1110，中心 srgb(0,255,255)
```
截图 `~/mgl/mpv_egl_window.png` —— ffmpeg testsrc 的彩条 + 渐变 + 圆圈全部正确，颜色无 R/B 互换。

### 全部四条路一起验（2026-11-22 13:20）
| 路径 | 命令 | 结果 |
|---|---|---|
| GLX | `glxinfo -B` | `Magma (MobileGL Core) (Mali-G57 MC2, Vulkan 1.1.177, Driver 32.1.0)` / GL 4.6 |
| EGL | `eglwin` | `GL_RENDERER=Magma (MobileGL Core) …` |
| ANGLE（Chromium） | `chromium --use-gl=angle --use-angle=gl --dump-dom` | `ANGLE (MobileGL-Dev …, Magma …, OpenGL 4.6.0)` |
| EGL 平台窗口（mpv） | `mpv --gpu-context=x11egl` | `VO: [gpu] 320x240 rgb24` |
