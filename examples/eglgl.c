// Probe: does a DESKTOP-OpenGL (non-ES) EGL context come up at all?
// Build: gcc -O1 -o eglgl eglgl.c -l:libEGL.so.1 -lX11
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
extern EGLSurface eglCreatePbufferSurface(EGLDisplay, EGLConfig, const EGLint*);
extern EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const EGLint*);
extern EGLBoolean eglMakeCurrent(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
extern EGLint eglGetError(void);
extern EGLBoolean eglBindAPI(EGLenum);
extern const char* eglQueryString(EGLDisplay, EGLint);

#define EGL_NONE 0x3038
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_BIT 0x0008
#define EGL_PBUFFER_BIT 0x0001
#define EGL_SURFACE_TYPE 0x3033
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define EGL_CONTEXT_MAJOR_VERSION 0x3098
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD
#define EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT 0x0001
#define EGL_OPENGL_API 0x30A2

int main(void) {
    Display* dpy = XOpenDisplay(NULL);
    if (!dpy) { puts("NO-X-DISPLAY"); return 1; }
    EGLDisplay e = eglGetDisplay((void*)dpy);
    EGLint major = 0, minor = 0;
    printf("init=%d %d.%d err=0x%x\n", eglInitialize(e, &major, &minor), major, minor, eglGetError());
    eglBindAPI(EGL_OPENGL_API);
    const EGLint cfgAttribs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
    EGLConfig cfg = 0;
    EGLint n = 0;
    printf("choose=%d n=%d err=0x%x\n", eglChooseConfig(e, cfgAttribs, &cfg, 1, &n), n, eglGetError());
    const EGLint pb[] = {EGL_WIDTH, 320, EGL_HEIGHT, 240, EGL_NONE};
    EGLSurface s = eglCreatePbufferSurface(e, cfg, pb);
    printf("pbuffer=%p err=0x%x\n", s, eglGetError());
    const EGLint ca[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
                         EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    EGLContext c = eglCreateContext(e, cfg, EGL_NO_CONTEXT, ca);
    printf("context=%p err=0x%x\n", c, eglGetError());
    printf("makecurrent=%d err=0x%x\n", eglMakeCurrent(e, s, s, c), eglGetError());
    puts("DONE");
    return 0;
}
