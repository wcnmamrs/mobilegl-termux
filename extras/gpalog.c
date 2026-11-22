/* 诊断用：拦截 glXGetProcAddress[ARB]，把返回 NULL 的名字打出来。
 * LOVE 0.10 用 GLEW 加载函数；MobileGL 对某些名字返回 NULL 时，
 * GLEW 留下的空指针被直接调用 → SIGSEGV at 0x0。 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static void* (*realGPA)(const unsigned char*);

static void* logMiss(const unsigned char* name, void* fn) {
    if (!fn && name) fprintf(stderr, "GPA-NULL %s\n", (const char*)name);
    return fn;
}

void* glXGetProcAddressARB(const unsigned char* name) {
    if (!realGPA) realGPA = (void* (*)(const unsigned char*))dlsym(RTLD_NEXT, "glXGetProcAddressARB");
    return logMiss(name, realGPA ? realGPA(name) : 0);
}

void* glXGetProcAddress(const unsigned char* name) {
    if (!realGPA) realGPA = (void* (*)(const unsigned char*))dlsym(RTLD_NEXT, "glXGetProcAddress");
    return logMiss(name, realGPA ? realGPA(name) : 0);
}
