/* libnovsync.so —— 强制关闭垂直同步
 *
 * MobileGL 的 Present 是按 X 的 vblank 节拍走的：
 *   MobileGL/MG_Impl/GLXImpl/X11Present.cpp:252
 *     const Uint64 targetMsc = swapInterval > 0 && m_lastMsc != 0
 *                            ? m_lastMsc + static_cast<Uint64>(swapInterval) : 0;
 *   MobileGL/MG_Impl/GLXImpl/X11Present.cpp:253
 *     const Uint32 options = swapInterval > 0 ? 0u : kPresentOptionAsync;
 * 也就是说：swapInterval 只要 > 0 就被锁到 60Hz（800x600 下的 59.x FPS 就是它），
 * 只有 = 0 才走 PRESENT_OPTION_ASYNC 全速。
 *
 * 但很多程序自己不会调 glXSwapInterval*(0)。这个库把三个入口都改成"忽略参数，一律 0"：
 *   glXSwapIntervalEXT(Display*, GLXDrawable, int)   void
 *   glXSwapIntervalMESA(unsigned)                    int
 *   glXSwapIntervalSGI(int)                          int
 * 并且把 glXGetProcAddress[ARB] 查这三个名字的请求也改成返回本库的版本
 * （程序普遍用 glXGetProcAddress 拿扩展函数指针，只覆盖符号是不够的）。
 *
 * 编译：
 *   gcc -O2 -shared -fPIC -o ~/mgl/lib/libnovsync.so novsync.c -ldl
 * 用法：
 *   LD_PRELOAD=~/mgl/lib/libnovsync.so <程序>
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

typedef void* NsDisplay;
typedef unsigned long NsDrawable;

static void* Next(const char* name) { return dlsym(RTLD_NEXT, name); }

void glXSwapIntervalEXT(NsDisplay* display, NsDrawable drawable, int interval) {
    (void)interval;
    static void (*real)(NsDisplay*, NsDrawable, int);
    if (!real) real = (void (*)(NsDisplay*, NsDrawable, int))Next("glXSwapIntervalEXT");
    if (real) real(display, drawable, 0);
}

int glXSwapIntervalMESA(unsigned int interval) {
    (void)interval;
    static int (*real)(unsigned int);
    if (!real) real = (int (*)(unsigned int))Next("glXSwapIntervalMESA");
    return real ? real(0) : 0;
}

int glXSwapIntervalSGI(int interval) {
    (void)interval;
    static int (*real)(int);
    if (!real) real = (int (*)(int))Next("glXSwapIntervalSGI");
    return real ? real(0) : 0;
}

/* 程序大多不主动调 glXSwapInterval*(0)（glxgears 只有加 -swapinterval 才调），
 * 所以再把 glXSwapBuffers 也接管：换目标时先把自己这边的 interval 压成 0。 */
void glXSwapBuffers(NsDisplay* display, NsDrawable drawable) {
    static NsDisplay* lastDisplay;
    static NsDrawable lastDrawable;
    if (display != lastDisplay || drawable != lastDrawable) {
        glXSwapIntervalEXT(display, drawable, 0);
        lastDisplay = display;
        lastDrawable = drawable;
    }
    static void (*real)(NsDisplay*, NsDrawable);
    if (!real) real = (void (*)(NsDisplay*, NsDrawable))Next("glXSwapBuffers");
    if (real) real(display, drawable);
}

void* glXGetProcAddressARB(const unsigned char* name) {
    if (name) {
        if (!strcmp((const char*)name, "glXSwapIntervalEXT")) return (void*)glXSwapIntervalEXT;
        if (!strcmp((const char*)name, "glXSwapIntervalMESA")) return (void*)glXSwapIntervalMESA;
        if (!strcmp((const char*)name, "glXSwapIntervalSGI")) return (void*)glXSwapIntervalSGI;
    }
    static void* (*real)(const unsigned char*);
    if (!real) real = (void* (*)(const unsigned char*))Next("glXGetProcAddressARB");
    return real ? real(name) : 0;
}

void* glXGetProcAddress(const unsigned char* name) {
    if (name) {
        if (!strcmp((const char*)name, "glXSwapIntervalEXT")) return (void*)glXSwapIntervalEXT;
        if (!strcmp((const char*)name, "glXSwapIntervalMESA")) return (void*)glXSwapIntervalMESA;
        if (!strcmp((const char*)name, "glXSwapIntervalSGI")) return (void*)glXSwapIntervalSGI;
    }
    static void* (*real)(const unsigned char*);
    if (!real) real = (void* (*)(const unsigned char*))Next("glXGetProcAddress");
    return real ? real(name) : 0;
}
