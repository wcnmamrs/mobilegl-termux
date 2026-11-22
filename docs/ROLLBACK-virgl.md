# 回退到 VirGL（旧链路）

本工具链不修改任何系统级组件，回退只是"不再用它"，没有要撤销的安装。
如果你确实想换回 VirGL + ANGLE 那套：

```bash
pkg install virglrenderer-android angle-android
```

然后在启动桌面的脚本里用回这些设置：

```bash
virgl_test_server_android --angle-vulkan &
termux-x11 :0 -listen unix &
# proot 内
export GALLIUM_DRIVER=virpipe
export MESA_GL_VERSION_OVERRIDE=4.3COMPAT
export MESA_GLSL_VERSION_OVERRIDE=430
export XDG_RUNTIME_DIR=/tmp/runtime-root
dbus-launch --exit-with-session startxfce4
```

注意：VirGL 链路的 GL 版本上限是 4.3（Compatibility），且比本工具链多两层转译
（virpipe → virglrenderer → ANGLE → 厂商 Vulkan）。
