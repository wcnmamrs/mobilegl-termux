# MobileGL Termux 工具链 —— 让 proot Linux 容器直接用上手机 GPU

在**无 root** 的 Android 设备上，把 Mali（或任何厂商）GPU 的 Vulkan 借给 proot 里跑的 glibc 程序：
容器内的 OpenGL 4.6 / GLES 调用经 `MobileGL` 的 split 传输送到 Termux 侧的常驻服务端，
服务端用厂商 Vulkan 渲染，帧再经 **dma-buf 零拷贝**（DRI3+Present）送回 X 服务器。

**装的时候不需要编译。** 预编译好的库随 [Releases](https://github.com/wcnmamrs/mobilegl-termux/releases) 分发（arm64，单包约 8.7MB），
`install.sh` 下载并三重校验后直接装进容器；只有想跟上游更新或改补丁的人，才需要按 `docs/GUIDE.md`
自己编（那一趟是整夜的活，不是 20 分钟）。

---

## 为什么需要它

Android 的 `/dev/mali*`、`/dev/dri/*` 对 `untrusted_app` 域不可读，proot 容器（glibc 进程）里
`vulkaninfo` 只能看到 Mesa 的软件 ICD：

| 检查项 | Termux（bionic） | proot Debian（glibc） |
|---|---|---|
| `vulkaninfo` | ✅ `Mali-G57 MC2` | ❌ 只有 Mesa ICD（llvmpipe） |
| `glxinfo`（未配置前） | — | ❌ `llvmpipe (LLVM 22.1.8, 128 bits)` |
| `/dev/dri/*` | Permission denied | Permission denied |

所以 GL 调用必须在容器**外**执行 —— 这正是 `MOBILEGL_TRANSPORT=spawn` 的 split 架构。
本项目把它接线到「装好就能用」的状态：容器里任何程序一起手就是 Mali。

---

## 实测结果（本机：天玑 700 / Mali-G57 MC2 / Android 12 / 无 root）

| 项目 | 软件渲染（Mesa llvmpipe） | 本项目（Magma + Mali Vulkan） |
|---|---|---|
| `glmark2 -s 800x600` 总分 | 99 | **264 ~ 337** |
| glmark2 纹理 / 着色场景 | 115 左右 | **300 ~ 400 FPS** |
| GL 版本 | 4.3（GLES 仿真） | **4.6 core / GLSL 4.60** |
| 呈现路径 | 命令流 → GLES → ANGLE → Vulkan → 回读 | Vulkan → **dma-buf → DRI3+Present 零拷贝** |
| Chromium WebGL | SwiftShader / llvmpipe | `ANGLE (MobileGL-Dev …, Magma (MobileGL Core) …)` |
| mpv 视频渲染 | — | `VO: [gpu] 2392x1080 yuv420p`，30 fps 不丢帧 |

`glxinfo -B` 现在输出：

```
OpenGL vendor string:   MobileGL-Dev (BZLZHH, Swung0x48, Tungsten)
OpenGL renderer string: Magma (MobileGL Core) (Mali-G57 MC2, Vulkan 1.1.177, Driver 32.1.0)
OpenGL core profile version string: 4.6.0 MobileGL 26.11-dev, Direct (Vulkan) Backend, GIT@2bdbe05
```

---

## 目录

```
patches/mobilegl-compat.patch   上游 MobileGL 的全部改动（31 文件，+1634/−135）
scripts/                        服务端、启动器、体检、系统级安装、桌面启动
extras/                         GL1.x 兼容层 / 关垂直同步 / GetProcAddress 诊断（LD_PRELOAD）
examples/                       EGL X11 窗口表面探针、桌面 GL 上下文探针
docs/GUIDE.md                   从零编译的完整指南（含 25 条踩坑总表）
docs/NOTES.md                   调试笔记与逐项实测数据（很长，按需查）
docs/reference/                 逆向参考（仅许可允许再分发的：ANGLE DisplayGLX.cpp；GPL 文件不随仓库分发，见 docs/reference/README.md）
shots/                          实拍证据（Chromium / mpv / DRI3 通道顺序校验；不含游戏画面）
```

---

## 它装什么，装完怎么验

安装脚本做四件事，全部可重入、失败自动回滚：

1. **自检**：架构（只认 aarch64）、Termux 环境、proot 容器、必需命令、磁盘余量、
   容器里是否已有 `libGL/libGLX/libEGL`（缺了自动 apt 装）、`termux-x11` 是否存在。
2. **取载荷并三重校验**：整包 `sha256` → 包内 `MANIFEST.sha256` → 逐文件 `sha256sum -c`。
   三个下载源（GitHub 直连 + 两个镜像）依次重试，本地包可用 `--payload` 指定。
3. **装两侧**：
   - Termux：`~/mgl/`（12 个脚本、兼容层、服务端二进制、库）、`~/mgl/xfce.sh`+`~/mgl/xfce-d.sh`、Termux:Boot 自启。
   - 容器：`/opt/mobilegl/lib/libMobileGL.so`、glvnd EGL 描述、`libGLX_mobilegl.so.0`、
     `/etc/profile.d/mobilegl.sh`、`/etc/environment.d/10-mobilegl.conf`、
     `/etc/mobilegl/client.conf`、`/etc/chromium.d/50-mobilegl`、`ldconfig`。
4. **实测验收**：先让服务端应答，然后**同时**验 GLX（`glxinfo -B`）与 EGL（`es2_info`），
   两条路都必须报出 `Magma (MobileGL Core)`。没有运行中的 X 时，脚本会临时起一个
   display，验完立刻关掉。任一条不通过 → 判定失败 → 自动回滚。

`--uninstall` 按安装清单逐项删除，删完再校验一遍容器里是否还有残留。

### 实测（本机，TFY-AN00 / Mali-G57 MC2 / Android 12）

删掉旧安装 → 把源码树整个藏起来 → 只跑安装脚本：

```
== 启动 GPU 服务端（Termux 侧） ==
[OK] 服务端二进制 → /data/data/com.termux/files/home/mgl/lib/libMobileGLServer.so（16M）
[OK] server: ready (endpoint=@mobilegl pidfile=9798)
== 验证（GLX + EGL 两条路） ==
[OK] GLX → Magma (MobileGL Core) (Mali-G57 MC2, Vulkan 1.1.177, Driver 32.1.0)
[OK] EGL → Magma (MobileGL Core) (Mali-G57 MC2, Vulkan 1.1.177, Driver 32.1.0)
== 安装完成 ==
```

服务端进程确认跑的是 `~/mgl/lib/libMobileGLServer.so` —— 也就是说**用户机器上不需要源码、
不需要编译器、不需要 NDK**。

## 版本策略与溯源

仓库本体就是"一键安装 + 补丁 + 文档"。发版的原因只有一个：**载荷变了**。
载荷 = 预编译库 + 脚本 + 配置模板，`install.sh` 里钉死了它的 sha256；
只要脚本改一个字符，载荷就变，版本号必须跟着走，否则老脚本会下到新载荷然后校验失败。

- `v1.0.x`：只修安装/运行脚本，二进制接口不变（可直接覆盖安装）
- `v1.1.x`：新增能力（如新的 GL 路径、新的验收项）
- `v2.0.0`：载荷布局或配置项不兼容

**历史版本一律保留**：每发一版就打 tag、传资产、留 release，方便回退与溯源。
（`v1.0.0`–`v1.0.6` 是项目早期的试错版本，已清理，不留二进制；从 `v1.0.7` 起全部保留。）
每个版本的改动与载荷 sha256 记在 `docs/CHANGELOG.md`。已经装过旧版的机器直接跑新版 `install.sh` 覆盖即可；
要回到"没有任何加速"的状态跑 `--uninstall`。

## 支持范围

| 项 | 要求 |
|---|---|
| 设备 | arm64-v8a（aarch64）手机/平板，Android 8.0+（API 26+，库按 26 构建） |
| Termux | 官方 Termux（bionic）；服务端就跑在 Termux 这一侧，直接 dlopen 系统 `libvulkan.so` 拿 Mali |
| 容器 | 自动探测（唯一就直用、多个就列出来让你选、也可 `--distro` 指定）；需 **glibc 系**，**Debian 13 / Ubuntu 24.04 及以上**；载荷需要 `glibc ≥ 2.38`、`GLIBCXX ≥ 3.4.32`（`install.sh` 会预检并给出中文提示） |
| proot-distro | v4 的容器路径布局（`$PREFIX/var/lib/proot-distro/containers/<名字>`）；容器名可用 `--distro NAME` 指定（或 `DISTRO_NAME=` 环境变量） |
| 桌面/窗口程序 | 需要 `termux-x11`（可选；只跑离屏 GL 不需要） |
| 已知不适用 | Alpine（musl）、未适配的 Arch/Fedora 容器 —— 多架构库目录会自动探测，但 `apt` 安装步骤与 glibc 版本需自行处理 |

`install.sh` 会先探测容器里 `libGL.so.1` 的实际目录（不同发行版 `usr/lib/aarch64-linux-gnu` / `usr/lib64` / `usr/lib` 各不相同），
再比对载荷与容器的 `GLIBC` / `GLIBCXX` 版本；任一项不满足就直接退出，而不是让动态链接器甩一屏 `version not found`。

## 快速开始

装好 Termux 基础件（`proot-distro`、一个 Debian 容器、`termux-x11` 可选），然后一条命令：

```bash
git clone https://github.com/wcnmamrs/mobilegl-termux.git ~/mgl-src
bash ~/mgl-src/install.sh
```

安装脚本会：自检环境 → 下载预编译载荷并三重校验（整包 sha256 / 清单 / 逐文件）→
把库和配置装进容器与 Termux → 起服务端 → **实测 GLX 与 EGL 两条路都走到 GPU** 才算成功。
任何一步失败都会自动回滚。

```bash
bash ~/mgl-src/install.sh --check        # 只体检，不改文件
bash ~/mgl-src/install.sh --uninstall    # 卸载（按清单逐项删除并校验）
bash ~/mgl-src/install.sh --payload x.tar.xz   # 离线安装
bash ~/mgl-src/install.sh --distro ubuntu      # 指定容器（不指定且存在多个时会列出来让你选）
```

想自己从源码编（改补丁、换设备、看细节）：照 `docs/GUIDE.md` 走一遍，产物在
`~/src/MobileGL/build-{glibc,bionic}`。`install.sh` **不会**自动采用它们——自己编的库要覆盖两处：

```bash
# 客户端（容器里所有 glibc 程序）
install -m 755 ~/src/MobileGL/build-glibc/libMobileGL.so \
  "$PREFIX/var/lib/proot-distro/containers/debian/rootfs/opt/mobilegl/lib/libMobileGL.so"
# 服务端（Termux 侧常驻进程）
install -m 755 ~/src/MobileGL/build-bionic/libMobileGL.so       ~/mgl/lib/
install -m 755 ~/src/MobileGL/build-bionic/libMobileGLServer.so ~/mgl/lib/
~/mgl/stop-server.sh; ~/mgl/start-server.sh
```

或者用 `scripts/install-system.sh` 重新部署一遍（它读的就是这两个 build 目录）。

日常：

```bash
~/mgl/xfce.sh                      # 开桌面（自动确保服务端与 X）
bash ~/mgl/gpu-check.sh            # 体检：两条路都出现 Magma 即正常
bash ~/mgl/gpu-check.sh 程序名      # 用完整 GPU 环境跑任意程序
```

---

## 脚本一览

| 脚本 | 作用 |
|---|---|
| `start-server.sh` | 起 bionic 服务端（`@mobilegl`，默认 8 个会话），日志 `/storage/emulated/0/MG/latest.server.log` |
| `ensure-server.sh` | **探测式**自愈：连抽象 socket 看是否真应答，不通就重启（pidfile 活着≠能用） |
| `stop-server.sh` | 停服务端 |
| `env.sh` | 容器侧环境（`source` 用）；`source env.sh stop` 全部取消 |
| `mgl-run.sh` | 通用启动器：先 ensure-server，再带着完整环境进容器跑任意命令 |
| `install-system.sh` | 把库和配置装进容器（`/opt/mobilegl`、glvnd JSON、`/etc/profile.d`、`/etc/mobilegl/client.conf`、`/etc/chromium.d`）；`remove` 卸载 |
| `gpu-check.sh` | 四段体检；`gpu-check.sh <程序>` 用完整环境跑单个程序 |
| `legacy.sh` | 带 GL1.x 兼容层跑老程序 |
| `xfce.sh` / `xfce-d.sh` | 起 / 停整台桌面（在 `~/mgl/` 里，不在 `$HOME` 放软链）；可选钩子 `MGL_AUDIO_HOOK=<可执行文件>`（不设就没有这一步；有 `yad` 时弹选择框，`MGL_AUDIO_TIMEOUT` 默认 60 秒）|

改路径就看脚本开头的变量：`MGL_BUILD`、`MGL_GLIBC`、`MGL_HOME`、`MGL_ENDPOINT`、`MGL_SESSIONS`、`PROOT_DIR`。
默认值按 Termux 标准布局写死（`/data/data/com.termux/files/home`），换设备时改这几行即可。

---

## 补丁解决了什么

上游 MobileGL 在两类场景下还接不住真实程序，`patches/mobilegl-compat.patch` 修的就是这些：

1. **`GetProcAddress` 覆盖度**：库导出 2952 个 GL 符号，但查找表只列了 1399 条；GLAD/GLEW 这类
   "逐个询问"的加载器拿到 `NULL` 后直接 `call NULL` 崩溃（LOVE 引擎的 `glMatrixMode` 就是这么死的）。
   → 找不到的名字回落到 `dlsym(RTLD_DEFAULT)`。
2. **兼容档矩阵栈**：`gl_ModelViewProjectionMatrix` 这一族在 Vulkan/glslang 里不存在，MobileGL 也不处理。
   → 补 CPU 侧矩阵栈 + `glMatrixMode/glOrtho/glPushMatrix/...`，并在 draw 前把 `mg_*Matrix` uniform 上传
   （走内部 API，避免 `GLStreamScope` 的非递归锁死锁）；shader 侧注入同名 uniform。
3. **亮度纹理格式**：`GL_LUMINANCE8_ALPHA8` / `GL_ALPHA8` 等返回 `GL_INVALID_ENUM`（LOVE 的字体图集必挂）。
   → 降到 `R8`/`RG8` 存储 + swizzle 还原语义。
4. **`gl_FragColor` / `gl_FragData` 冲突**：宏别名 `#define love_Canvases gl_FragData` 没有任何下标访问，
   却为它声明 8 个输出，把 `mg_FragColor` 挤到 location 8 而链接失败。→ 只在真有下标访问时才声明数组。
5. **DRI3 零拷贝三个根因**：gralloc 句柄里第一个 fd 不可 `mmap`；发给 X 服务器的 modifier 是真 DRM modifier
   而 termux-x11 只认 `RAW_MMAPPABLE_FD(1274)`；GPU-only usage 下拿到的是 AFBC 压缩布局。
   → 选可映射 fd + modifier 回退 + 补 `CPU_READ_OFTEN` 换线性布局；通道顺序用一张 BGRA 中间图
   （`vkCmdBlitImage` 转换 + `vkCmdCopyImage` 搬运）解决，避免给 Mali 喂它不认的 BGRA AHB。
6. **GLX 三处缺口**（Chromium/ANGLE 走 GLX 才暴露）：`GLX_DRAWABLE_TYPE` 过滤过严、
   `glXCreatePbuffer` 是返回 0 的 stub、FBConfig 只有两条写死的配置且 `GLX_VISUAL_ID` 恒为默认 visual
   （`eglInitialize: Invalid visual ID requested`）。→ 按 visual 动态建表 + pbuffer drawable 支持。
7. **EGL 的 X11 窗口表面**（mpv、Firefox 这类不走 GLX 的程序）：原来把 X 窗口 id 直接发给 Android 服务端
   → 会话段错误。→ 新增 `X11WindowPresent`，EGL 窗口表面复用 GLX 那条呈现链：离屏 pbuffer 渲染 +
   `eglSwapBuffers` 时把帧送进 X 窗口；`eglCreatePlatformWindowSurface` 同样处理，并容忍
   "native_window 是指向 Window 的指针"（mpv/ANGLE 的实际行为）。

---

## extras/（可选）

| 文件 | 作用 | 构建 |
|---|---|---|
| `fixfunc.c` | GL 1.x 固定管线兼容层（`glBegin/glVertex*/glMatrixMode/显示列表/客户端数组/光照/纹理` → 现代 GL） | `bash extras/build-extras.sh` |
| `novsync.c` | 强制 `glXSwapInterval*(0)`，解开 60 Hz 限制（glxgears 59 → 376 FPS） | 同上 |
| `gpalog.c` | 记录 `glXGetProcAddress` 返回 `NULL` 的名字，排查加载器问题 | 同上 |

用法：`LD_PRELOAD=~/mgl/lib/libfixfunc.so <程序>`，或 `scripts/legacy.sh <程序>`。

---

## 边界（明确不做的事）

- **视频解码**：不走 GL。容器里没有 MediaCodec（那是 bionic 才有的），也没有 `/dev/video*`、`/dev/dri`，
  所以 `ffmpeg/mpv` 在容器内始终软解 —— 本项目不改变这一点，也不打算改变。
  想要硬解只能在 Termux 侧（`mpv --hwdec=mediacodec-copy` 可用，CPU 占用约 1/3）。
- **原生 Vulkan 程序**：容器内 `vulkaninfo` 仍只有 Mesa ICD，Vulkan 应用看不到 Mali（GL 调用是被代理的，
  Vulkan 不是）。
- **WebGPU / WebNN**：Chromium 的 Vulkan 后端同上。

优雅退化：服务端不在时，`ImplementationAvailable()` 会让 glvnd 落到 Mesa（llvmpipe），程序不崩、只是变慢。

---

## 环境与兼容性

- 本仓库的补丁基于 MobileGL `2bdbe05`（dev 分支）与 Termux:X11 `d366d40`；上游更新后可能需要重新适配。
- 实测设备：TFY-AN00（天玑 700 / Mali-G57 MC2 / Android 12 / arm64-v8a / 无 root）。
- 换到 Adreno / PowerVR 时，主要差异在 AHB 的 fd 布局与 modifier 语义，`docs/GUIDE.md` §12 的
  DRI3 相关三条请重新验证。
- 构建侧：容器内 gcc 14 + CMake 3.31；Termux 侧 clang 21（`-DANDROID_PLATFORM=android-26`）。

---

## 许可

| 部分 | 许可 |
|---|---|
| 本仓库的脚本、文档、`extras/`、`examples/` | MIT（见 `LICENSE`） |
| `patches/mobilegl-compat.patch` 与载荷里的 `libMobileGL.so` | 衍生自 [MobileGL](https://github.com/MobileGL-Dev/MobileGL)，**LGPL-3.0** |
| `docs/reference/DisplayGLX.cpp` | [ANGLE](https://chromium.googlesource.com/angle/angle) BSD-3-Clause（保留版权声明） |

载荷里的二进制是对 MobileGL 的修改版，**对应源码** = 上游 commit `2bdbe05` + `patches/mobilegl-compat.patch`
（`docs/GUIDE.md` 有完整重建步骤）；LGPL-3.0 要求的源码可得性由此满足。
其它上游：[Termux:X11](https://github.com/termux/termux-x11)（GPL-3.0，其源码文件不随本仓库分发）、
[libglvnd](https://gitlab.freedesktop.org/glvnd/libglvnd)、[Mesa](https://gitlab.freedesktop.org/mesa/mesa)（仅运行时依赖）。
