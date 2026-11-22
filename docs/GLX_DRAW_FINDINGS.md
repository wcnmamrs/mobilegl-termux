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

## 追加实验二（2026-11-22 21:30）—— 纹理附件 / instanced / fence / scissor / 负高度 viewport

| 测试 | 内容 | 结果 |
|---|---|---|
| `glxprobe12` | 纹理附件 FBO（`glTexStorage2D` + `glTexSubImage2D`）+ `glDrawArraysInstanced` + `glDrawElementsInstanced` + `glFenceSync`/`glClientWaitSync` | 全部 `err=0x0`（该探针把三角形画成红色、底色也是红色，读回自然是红，**结论作废一次**，见下一条） |
| `glxprobe13` | 同上但三角形用绿色：读回 / blit 到默认帧缓冲 / 把纹理采样画出来 | 三条都是 `0,255,0,255` ✅ —— **纹理附件 FBO 完全正常** |
| `glxprobe14` | scissor 全屏 / 10×10 + cull face 正反绕序 | cull 行为正确（CW 被剔除、CCW 画出）；scissor 那两条当时被前面 viewport 错误污染，见 probe16 |
| `glxprobe15` | 负高度 viewport（`0,240,320,-240` 与 `0,0,320,-240`） | **`GL_INVALID_VALUE(0x501)`，viewport 保持 0,0,320,240** —— ES 上下文里负高度非法（符合 ES 规范，但桌面 GL 程序若依赖它就会踩） |
| `glxprobe16` | scissor 状态与裁剪 | `scissortest=1 box=0,0,4,4`，中心像素被裁成 `0,0,0,0` ✅ —— **scissor 确实生效**（另有 `0x502` 错误来自探针自身的前置调用） |

补充结论：
- `BuildVertices`/`glXMakeCurrent` 之后 `GL_VIEWPORT` 仍是 `0,0 0x0`（真 bug，未修）；但后端在 viewport 宽高为 0 时会退化成逻辑分辨率，所以探针仍能画出来 —— 真实程序若查询 `GL_VIEWPORT` 再据此计算，可能出问题。
- 直到这一轮为止，**我们的 GL 层在每一条可构造的路径上都正确**；ANGLE 在 GLX 模式下丢失 WebGL 内容这件事，无法再用"某个 GL 入口坏了"解释，下一步只能进 ANGLE 内部（`RendererGL`/`StateManagerGL` 的调用序列）或给我们自己的 GLX 层加"每次 draw 的 FBO/drawable 记录"来对照。

## 追加实验三（2026-11-22 21:50）—— **找到根因：共享上下文不共享对象**

加了 `MOBILEGL_GLX_TRACE=1` 的 per-draw 记录（`MG_Impl/GLImpl/Drawing/GL_Drawing.cpp` 里打 FBO id / viewport / scissor），
并给 `ReadPixels` 也加了同样的记录（`MG_Impl/GLImpl/Framebuffer/GL_Framebuffer.cpp`）。带
`__GLX_VENDOR_LIBRARY_NAME=mobilegl` 跑 tri3，日志给出决定性两行：

```
glxtrace: DrawArrays mode=0x4 first=0 count=3 fbo=2 vp=0,0,200,200   ← 页面三角形，画进了 fbo=2
glxtrace: ReadPixels 1x1 at 100,100 fbo=2 first=255,0,0,255          ← 紧接着读同一 fbo，只有底色
```

即：**绘制确实发生了、目标 FBO 也对，但读回来是空的**。于是逐个排除同形状的写法：

| 探针 | 内容 | 结果 |
|---|---|---|
| `glxprobe18` | 单采样渲染缓冲 FBO / 多采样 FBO 直读 / 解析后读 / `glDrawBuffers` 后画 | 单采样 ✅、MSAA 直读按规范报 `0x502`、解析后 ✅ |
| `glxprobe19` | `glDrawBuffers([ATTACH0])`、`glDrawBuffer`、`glNamedFramebufferDrawBuffer[s]` 之后绘制 | 五种写法全部 ✅，排除 draw buffer 问题 |
| **`glxprobe20`** | **两个共享上下文（`glXCreateContextAttribsARB(dpy, cfg, shareContext, …)`）操作同一个纹理附件 FBO** | **看到问题** ↓ |

`glxprobe20` 输出：
```
ctx A draw, ctx A read             centre=0,255,0,255 err=0x0     ✅
ctx B read same fbo (share)        centre=0,0,0,0     err=0x502   ← B 眼里这个 FBO 根本没有附件
ctx B draw, ctx B read             centre=0,0,0,0     err=0x0     ← B 画的也进不去
ctx A read after B draw            centre=0,255,0,255 err=0x0     ← A 仍看到自己的旧内容
```

**结论：split 模式下共享上下文（share group）里的对象没有真正共享。** 每个上下文在服务端是独立会话，
纹理/FBO/缓冲的名字空间互相看不见；客户端也没有把共享对象镜像到对方会话。

这正好解释 ANGLE 的现象：ANGLE 的 GL 后端会开**两个共享上下文**（一个做渲染、一个负责 display/readback），
WebGL 的 canvas FBO 在 A 里画、在 B 里读 → 永远是空的，而 clear 色因为两边各自清过所以"看起来正常"。
EGL 模式下 WebGL 能用，是因为 ANGLE 走的是单上下文路径（或共享对象只在同一上下文内被读写）。

### 修的方向（下一轮）
1. `MobileGL/MG_State/GLState/ShareGroupState.*` 已有 share-group 概念，检查前端是否把"同一 share group 的上下文"登记到一起；
2. split 传输层：`MG_Remote/Client/*` 里对象 id 目前按会话编码，需要改成"共享组内同一逻辑 id 在多会话内路由"，
   或者让服务端为同一 share group 的会话共享一份对象表；
3. 拿 `glxprobe20` 作为回归用例（四个断言全部为绿才算修好）。

### 顺带修掉的真 bug（已编译部署）
- `glXMakeCurrent` 成功后把 viewport 初始化成 drawable 的逻辑尺寸（`GLXImpl.cpp`），
  之前是 `0,0 0x0`；`glxprobe15` 复查：`viewport 0,0,320,240 -> vp=0,0,320,240` ✅
- per-draw / per-readpixels 诊断日志，`MOBILEGL_GLX_TRACE=1` 打开（默认关闭，零开销）

## 追加实验四（2026-11-22 22:20）—— 共享上下文修好了；Chromium 的 GLX 路径仍差一层

### 真 bug 与修复（已验证）
`glxprobe22/23` 用 `glGetTexLevelParameteriv` 直接问"B 眼里那个纹理是多大"：
修复前 `B: tex 1 = 0x0`、B 自己的 FBO `0x8cd7`（附件不完整）；`eglctx` 日志显示
`token=2 shareCtx=(nil) … group=2`（第二个上下文根本没收到 share，另起一组）。

根因在 `MG_Impl/GLXImpl/GLXImpl.cpp` 的 `CreateContextAttribsARB`：`wantsEs` 分支
**一律传 `nullptr` 当 share**（当时的注释写"共享上下文跨 API 不支持，直接不共享"）。
ANGLE 在 GLX 上开的正是"两个 ES 上下文共享一个组"，于是 A 里画、B 里读。

修法：`ContextObject` 记 `Bool EsApi`；ES 分支里只有当 share 自己也是 ES 时才递下去。
修复后同一探针：
```
eglctx: token=2 shareCtx=0x1 found=1 group=1
A: tex 1 = 200x200 … B: tex 1 = 200x200（共享了）
B reads A's texture via own FBO   centre=0,255,0,255 err=0x0   ✅
```
`glTexImage2D` 与 `glTexStorage2D` 两种附件写法都验过（`glxprobe25`）。

### Chromium 仍未通（同一上下文内丢内容）
`MOBILEGL_GLX_TRACE=1` 下窗口跑 `file:///tmp/tri3.html`，只有**一个**上下文（`token=1 api=12448` = ES）：
```
glxtrace: DrawArrays mode=0x4 first=0 count=3 fbo=2 vp=0,0,200,200 scissorTest=0 box=0,0,200,200
          prog=3 vao=2 idx=0 mask=1111 blend=0 depth=0 cull=0
glxtrace: ReadPixels 1x1 at 100,100 fbo=2 first=255,0,0,255
```
状态全对（程序/VAO/颜色掩码/无 blend/无 depth/无 cull/viewport 正确），画完立刻读只有底色。
所以既不是共享问题，也不是状态问题 —— 剩下的是"同一个上下文里，ANGLE 的 canvas FBO
恰好落不进内容"，而自己写的同形状探针（ES3 + FBO + VAO + VBO）是全绿的。
下一步要往 backend 走：在 Magma 的 `DrawArrays` 里打一次"当前 framebuffer/渲染通道"，
确认 Vulkan 侧收到的是不是同一张图，再决定是 FBO 物化（twin）还是 render pass 的问题。
