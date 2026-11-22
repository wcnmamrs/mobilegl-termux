# 变更记录

- **install.sh 真 bug（实机全卸载重装时发现）**：`write_file_atomic` 只接受一个内容参数，
  写 `/etc/chromium.d/50-mobilegl` 时却传了两个字符串，`printf '%s\n' "$2"` 只落第一个，
  `CHROMIUM_FLAGS` 那行被静默丢弃 → 浏览器退回默认后端、WebGL 全废。
  修法：两行合成一个多行字符串；并在安装阶段加自检（缺 `unset __GLX_VENDOR_LIBRARY_NAME`
  或 `--use-angle=gles` 就直接 `[E]` 并退出 5，不再"装完看起来 OK"）。

## v1.0.2 之后的脚本修正（续）

- **Chromium 在桌面会话里报 `BindToCurrentSequence failed` 的根因**：会话继承了
  `__GLX_VENDOR_LIBRARY_NAME=mobilegl`，Chromium 初始化 GL 时先试 "OpenGL ES on GLX"，
  而我们的 GLX 层不提供 `GLX_EXT_create_context_es_profile`，失败后 `eglInitialize` 全线返回
  `EGL_NOT_INITIALIZED`，WebGL 拿不到 context（`VENDOR = 0xffff`）。
  修法：`/etc/chromium.d/50-mobilegl` 里 `unset __GLX_VENDOR_LIBRARY_NAME`，只影响 Chromium；
  桌面会话里的其它程序照旧用 GLX 走 MobileGL。

## v1.0.2 之后的脚本修正（载荷未变，仍是 v1.0.2）

`install.sh` 不在载荷里，所以只改安装器的修正不需要发新版；记录在此以免断档：

- **Chromium 后端 `--use-angle=gl` → `--use-angle=gles`**：ANGLE 的桌面 GL 后端在 Linux 走 GLX，
  画几何时结果不落进 canvas（`readPixels=0,0,0,255`，只有 clear 生效）；换成 GLES 后端后
  get.webgl.org 的方块正常显示（`readPixels=0,255,0,255`）。
- 容器内新增 `/usr/local/bin/legacy`：GL 1.x 程序（glxgears、老游戏）用 `legacy <命令>` 启动，
  通过 LD_PRELOAD 把立即模式翻译成 VBO + 着色器（Magma 的 `glBegin` 是空 stub）。
- README 改正"需要自行编译（约 20 分钟）"与"install.sh 会自动优先用本地 build"两处与事实不符的说法。

版本号只描述**载荷**（预编译库 + 脚本 + 配置模板）的集合。`install.sh` 里钉死了载荷的
sha256，所以脚本一改、载荷就变、版本号就必须跟着走 —— 否则老脚本会去下新载荷然后校验失败。

历史版本一律保留（tag + release + 说明），删掉就断了溯源链。二进制资产若不可得，
release 说明里会写清重建方法。

## v1.0.2 — 2026-11-22

桌面常驻可用。载荷 sha256 `d3a0037bbb234409208fc89f4015a76ea247d478fd81da466898a4700c4bc1c4`。

- `killeq` 改为 exe 基本名 + `/proc/<pid>/comm` 双匹配：proot 子进程被 ptrace 盯住，
  从 Termux 侧读不到 exe；`termux-x11` 的 exe 是 `/system/bin/sh`，只有 comm 对得上。
- `xfce.sh` / `xfce-d.sh` 新增 `kill_desktop_in_container`：桌面进程从容器内 `pkill -x` 清掉。
  修掉「重复会话 + Another Window Manager is already running」与 `xfce-d.sh` 停不干净。

## v1.0.1 — 2026-11-22

安装脚本稳健性修复。载荷 sha256 `394b4ab8bb59edbb2f333007a88008ede223a32c3edbcc42f49eca926dbf5f11`
（该 tag 下的 `install.sh` 里写的就是这个值；更早一版 `18b22a1` 的 `99832fea…` 已被本版取代）。

- `free_mb` 改用 `df -Pk`：Termux 的 `df` 是 toybox，不认 `-m`，v1.0.0 会在自检阶段失败。
- 界面消息全部走 stderr，stdout 只留数据（否则载荷路径被 `[OK] …` 污染）。
- 验证改用登录 shell（顺带证明 `/etc/profile.d` 接线）；无运行中 X 时临时起一个 display，验完关闭。
- `pkill -f` 换成按 `/proc/<pid>/exe` 精确匹配的 `killeq`（`pkill -f` 会把命令行里恰好含该
  字符串的 shell 打成 SIGKILL，实测踩到过）。
- 脚本改为安装目录优先（`~/mgl/lib`、`/opt/mobilegl/lib`），普通用户不再需要源码树。

## v1.0.0 — 2026-11-22

首个可安装版本。载荷 sha256 `480a520674145e555b63b003b0518d0fad9b1b9816448d260ef1d3216f04af5d`。

- `install.sh`：环境自检 / 载荷三重校验 / 幂等安装 / 失败回滚 / `--check` / `--uninstall`。
- 载荷：glibc 客户端库、bionic 服务端库与可执行、`libfixfunc.so`、`libnovsync.so`、12 个脚本。
- 已知问题：自检阶段 `df -m` 失败（v1.0.1 修）；提示文字污染 stdout（v1.0.1 修）；
  `pkill -f` 误杀（v1.0.1 修）；重启桌面撞窗口管理器（v1.0.2 修）。
