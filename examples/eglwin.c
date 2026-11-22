// EGL + X11 window test: does an EGL window surface actually reach the X window?
// Build (inside proot Debian):
//   gcc -O1 -o ~/eglwin ~/eglwin.c -l:libEGL.so.1 -l:libGLESv2.so.2 -lX11
#include <stdio.h>
#include <unistd.h>
#include <X11/Xlib.h>

typedef void* EGLDisplay;
typedef void* EGLConfig;
typedef void* EGLSurface;
typedef void* EGLContext;
typedef int EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;

extern EGLDisplay eglGetDisplay(void*);
extern EGLBoolean eglInitialize(EGLDisplay, EGLint*, EGLint*);
extern EGLBoolean eglChooseConfig(EGLDisplay, const EGLint*, EGLConfig*, EGLint, EGLint*);
extern EGLSurface eglCreateWindowSurface(EGLDisplay, EGLConfig, unsigned long, const EGLint*);
extern EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const EGLint*);
extern EGLBoolean eglMakeCurrent(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
extern EGLBoolean eglSwapBuffers(EGLDisplay, EGLSurface);
extern EGLint eglGetError(void);
extern const char* eglQueryString(EGLDisplay, EGLint);
extern EGLBoolean eglBindAPI(EGLenum);

extern void glClearColor(float, float, float, float);
extern void glClear(unsigned int);
extern void glFinish(void);
extern const unsigned char* glGetString(unsigned int);

#define EGL_NONE 0x3038
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_ALPHA_SIZE 0x3021
#define EGL_BLUE_SIZE 0x3022
#define EGL_GREEN_SIZE 0x3023
#define EGL_RED_SIZE 0x3024
#define EGL_DEPTH_SIZE 0x3025
#define EGL_SURFACE_TYPE 0x3033
#define EGL_WINDOW_BIT 0x0004
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_ES2_BIT 0x0004
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_VENDOR 0x3053
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02

int main(int argc, char** argv) {
    Display* dpy = XOpenDisplay(NULL);
    if (!dpy) {
        puts("NO-X-DISPLAY");
        return 1;
    }
    const int screen = DefaultScreen(dpy);
    Window win = XCreateSimpleWindow(dpy, RootWindow(dpy, screen), 120, 120, 400, 300, 0, BlackPixel(dpy, screen),
                                     BlackPixel(dpy, screen));
    XStoreName(dpy, win, "EGL window test");
    XSelectInput(dpy, win, ExposureMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    XFlush(dpy);
    usleep(300000);

    const int useDefault = argc > 1 && argv[1][0] == 'd'; // "default": ask for EGL_DEFAULT_DISPLAY
    EGLDisplay edpy = eglGetDisplay(useDefault ? NULL : (void*)dpy);
    printf("display source=%s\n", useDefault ? "EGL_DEFAULT_DISPLAY" : "X Display*");
    printf("eglGetDisplay=%p err=0x%x\n", edpy, eglGetError());
    EGLint major = 0, minor = 0;
    printf("eglInitialize=%d err=0x%x\n", eglInitialize(edpy, &major, &minor), eglGetError());
    printf("EGL %d.%d vendor=%s\n", major, minor, eglQueryString(edpy, EGL_VENDOR));
    eglBindAPI(EGL_OPENGL_ES_API);

    const EGLint cfgAttribs[] = {EGL_RED_SIZE,   8,           EGL_GREEN_SIZE,     8,
                                 EGL_BLUE_SIZE,  8,           EGL_ALPHA_SIZE,     8,
                                 EGL_DEPTH_SIZE, 24,          EGL_SURFACE_TYPE,   EGL_WINDOW_BIT,
                                 EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE};
    EGLConfig cfg = 0;
    EGLint numCfg = 0;
    printf("eglChooseConfig=%d n=%d err=0x%x\n", eglChooseConfig(edpy, cfgAttribs, &cfg, 1, &numCfg), numCfg,
           eglGetError());

    EGLSurface surf = eglCreateWindowSurface(edpy, cfg, (unsigned long)win, NULL);
    printf("eglCreateWindowSurface=%p err=0x%x\n", surf, eglGetError());
    const EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(edpy, cfg, EGL_NO_CONTEXT, ctxAttribs);
    printf("eglCreateContext=%p err=0x%x\n", ctx, eglGetError());
    printf("eglMakeCurrent=%d err=0x%x\n", eglMakeCurrent(edpy, surf, surf, ctx), eglGetError());
    if (glGetString(GL_VENDOR) != NULL) {
        printf("GL_VENDOR=%s\nGL_RENDERER=%s\nGL_VERSION=%s\n", glGetString(GL_VENDOR), glGetString(GL_RENDERER),
               glGetString(GL_VERSION));
    } else {
        puts("GL strings unavailable");
    }

    for (int frame = 0; frame < 240; ++frame) {
        glClearColor(0.2f, 0.6f, 0.9f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glFinish();
        if (!eglSwapBuffers(edpy, surf)) {
            printf("eglSwapBuffers failed err=0x%x at frame %d\n", eglGetError(), frame);
            break;
        }
        usleep(16000);
    }
    puts("EGL-WINDOW-TEST-DONE");
    return 0;
}
