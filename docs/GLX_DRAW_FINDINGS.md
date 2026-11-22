# GLX 绘制路径调查（2026-11-22 晚）

## 目标
去掉 Chromium 的 per-app `unset __GLX_VENDOR_LIBRARY_NAME`，让"桌面环境里任何程序都自动走 MobileGL"这件事对浏览器也成立。

## 已做的库层改动（本机已部署，未进载荷）
`MobileGL/MG_Impl/GLXImpl/GLXImpl.cpp`：
- 扩展串加 `GLX_EXT_create_context_es_profile` / `GLX_EXT_create_context_es2_profile`
- `CreateContextFromEGLAttribs(..., Bool esApi)`：ES 时 `BindAPI(EGL_OPENGL_ES_API)` + `EGL_OPENGL_ES2_BIT`
- `CreateContextAttribsARB`：识别 `GLX_CONTEXT_ES_PROFILE_BIT_EXT (0x4)`，用 `EGL_CONTEXT_CLIENT_VERSION` 建 ES2/ES3 上下文

## 实测（决定性）
探针 `~/x11work/glxprobe3.c`（五种 profile 建上下文）：
```
compat-4.6  ctx ok  make=1  renderer=Magma (MobileGL Core) (Mali-G57 MC2 …)
core-3.3    ctx ok  make=1
core-4.6    ctx ok  make=1
es-2.0      ctx ok  make=1
es-3.0      ctx ok  make=1
```
探针 `~/x11work/glxprobe4.c`（每种 profile 清红底 + 画全屏绿三角 + 读中心像素）：
```
compat-4.6  err_draw=0x0    centre=0,255,0,255   ✅ 画出来了
core-3.3    err_draw=0x502  centre=255,0,0,255   （探针用了 client-side array，core 下非法，探针问题）
core-4.6    同上
es-2.0      err_draw=0x0    centre=0,255,0,255   ✅
es-3.0      err_draw=0x0    centre=0,255,0,255   ✅
```
→ **我们的 GLX 层本身能建 ES 上下文、也能把几何画出来**。

## 但 ANGLE 仍然不行
带桌面环境（`__GLX_VENDOR_LIBRARY_NAME=mobilegl`）跑 Chromium：
- 补丁前：`Cannot create an OpenGL ES platform on GLX without the GLX_EXT_create_context_es_profile extension` → `EGL_NOT_INITIALIZED` → WebGL 报 `BindToCurrentSequence failed`
- 补丁后：**不再报错**，但 canvas 只有背景色（`readPixels=255,0,0,255`），整窗截图 `unique=1 gray(0)` —— **整个浏览器窗口全黑**，说明 ANGLE 走 GLX 后连合成结果都没上屏
- 清掉该变量（走 EGL + `--use-angle=gles`）：`readPixels=0,255,0,255`，aquarium 正常出鱼

## 结论与下一步
- 已修掉的：`GLX_EXT_create_context_es_profile` 缺失导致的"初始化直接判死"。
- 剩下的：ANGLE 在 GLX 上的**绘制/呈现**链路。最可疑的是"我们只在 `glXSwapBuffers` 里 present"——ANGLE 合成完可能不 swap（它直接画进 GLX drawable），于是永远没有画面。
- 下一步（按成本排序）：
  1. 在 `glXWaitGL` / `glFinish` / `XFlush` 尾部补一次 present（只对当前 drawable），验证是否变好；
  2. 给 GLX 路径补初始 viewport（已发现 `glXMakeCurrent` 后 `GL_VIEWPORT` 是 0x0）；
  3. 若仍不行，按 ANGLE `DisplayGLX`/`RendererGL` 的调用序列逐段对齐。

## 追加实验（2026-11-22 21:00）—— 逐层排除完毕

| 测试 | 内容 | 结果 |
|---|---|---|
| glxprobe3 | 五种 profile 建 GLX 上下文 | compat-4.6 / core-3.3 / core-4.6 / es-2.0 / es-3.0 **全部成功** |
| glxprobe4 | 各 profile 画三角形 + 读中心 | compat / es2 / es3 `0,255,0,255` ✅（core 档当时用了 client array，非法，属探针问题） |
| glxprobe5 | core-3.3 + VAO + VBO 画三角形 | `err_draw=0x0 centre=0,255,0,255` ✅ |
| glxprobe8 | blit 三方向（READ/DRAW 显式绑定） | FBO→FBO、FBO→默认、默认→FBO **全部正确** ✅ |
| glxprobe9 | ES3 `glDrawArrays` vs `glDrawElements` | 两者都 `0,255,0,255` ✅ |
| swap 计数（临时日志） | Chromium 静态页 | 只有 1 次 glx swap（静态页本就只该 1 帧，非故障） |
| swap 计数 | Chromium 动画页（aquarium） | 18 次 glx swap + 18 次 egl swap（**呈现确实在跑**） |

### ANGLE 后端矩阵（`__GLX_VENDOR_LIBRARY_NAME=mobilegl` 存在时，tri3 探针）
| `--use-angle=` | 结果 |
|---|---|
| `gl` | `readPixels=255,0,0,255`（只有背景）❌ |
| `gles` | `readPixels=255,0,0,255` ❌ |
| `vulkan` | `readPixels=0,255,0,255` ✅（走 Mesa llvmpipe，不是我们的库） |
| 默认 | `readPixels=255,0,0,255` ❌ |
同一页面在 aquarium 上：HUD 显示 `fps: 30 canvas 1024x1024`，但画布是纯青色 —— 帧在走，内容没进去。

### 结论（排除法）
1. 我们的 GLX 层：上下文创建（含 ES）、绘制（arrays/elements）、FBO、blit、present **逐项都正确**。
2. 我们的 EGL 层（含 EGL X11 窗口表面）：mpv、Chromium（无 GLX 变量时）都正确。
3. 只要 `__GLX_VENDOR_LIBRARY_NAME=mobilegl` 存在，ANGLE 会把 WebGL 画到**它自己那套 GLX 表面上**，而内容进不去 canvas —— 且 chromium 自己的窗口内容（HUD/文字）能出来，说明合成与呈现是通的，丢的是 WebGL 那一层的绘制结果。

### 剩下的可疑点（下一轮从这里开始）
- ANGLE 在 GLX 模式下把 WebGL 渲染进 **它自己的离屏表面/FBO**，再合成；我们的统计里 glx swap 与 egl swap 数量一致，说明两条呈现路都在跑，但读到的是空帧 → 需要按 ANGLE `RendererGL`/`StateManagerGL` 的实际调用序列（`glBindFramebuffer` + `glViewport` + `glDrawElementsInstanced` + `glBlitFramebuffer` 或 `glCopyImageSubData`）逐步复刻一次，找出第一个"结果没落地"的调用。
- 也可能与 **每 drawable 一个 EGL pbuffer 表面 + 多线程多上下文** 有关（Chromium 的 raster 线程与 compositor 线程各自 MakeCurrent），需要给 surface 绑定加日志确认。
