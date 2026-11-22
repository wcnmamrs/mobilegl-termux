# 参考文件说明

这里只放**许可允许再分发**的文件，用来解释"我们为什么这么改"：

| 文件 | 来源 | 许可 |
|---|---|---|
| `DisplayGLX.cpp` | [google/angle](https://github.com/google/angle) `src/libANGLE/renderer/gl/glx/DisplayGLX.cpp` | BSD-3-Clause（保留版权声明） |

**删除的参考文件**：`dri3.c`、`renderer.c` 取自 termux-x11（GPL-3.0），与本仓库的 MIT 许可不兼容，
因此没有随仓库分发。需要对照时请自行从 `termux/termux-x11` 的对应 commit 取，例如：

```bash
curl -sS "https://fastly.jsdelivr.net/gh/termux/termux-x11@<commit>/lorie/dri3.c" -o dri3.c
```

本项目自身代码（`scripts/`、`extras/`、`examples/`、`patches/`、文档）为 MIT；见仓库根目录 `LICENSE`。
对 MobileGL 上游的改动用 `patches/mobilegl-compat.patch` 分发，MobileGL 自身的许可请以其仓库为准。
