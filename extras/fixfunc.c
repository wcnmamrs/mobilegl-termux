// libfixfunc.so - fixed-function (OpenGL 1.x) compatibility layer on top of a core-profile GL.
//
// Magma (MobileGL's DirectVulkan backend) implements the whole fixed-function surface as stubs:
// glBegin/glVertex3f/glEnd/glNewList/glRotatef... do nothing, so legacy apps draw nothing at all.
// This library intercepts those entry points (LD_PRELOAD) and translates them into buffered
// vertex-array draws, which the core profile does support:
//
//   glBegin/glVertex*/glColor*/glNormal*/glEnd   -> record, then glDrawArrays with a shader
//   glMatrixMode/glTranslatef/...                -> a CPU matrix stack feeding a mvp uniform
//   glNewList/glCallList                         -> a recorded command script, replayed
//   glVertexPointer/... + glDrawArrays           -> client arrays copied into a VBO
//
// Everything else (buffers, textures, shaders, framebuffers, glClear, glViewport...) is left to
// the real driver: this library only fills in what the driver does not implement.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef unsigned int GLbitfield;
typedef int GLint;
typedef int GLsizei;
typedef unsigned char GLubyte;
typedef unsigned char GLboolean;
typedef unsigned short GLushort;
typedef float GLfloat;
typedef double GLdouble;
typedef void GLvoid;
typedef char GLchar;
typedef ptrdiff_t GLsizeiptr;
typedef ptrdiff_t GLintptr;

/* ---- enums ---------------------------------------------------------------- */
#define GL_POINTS 0x0000
#define GL_LINES 0x0001
#define GL_LINE_LOOP 0x0002
#define GL_LINE_STRIP 0x0003
#define GL_TRIANGLES 0x0004
#define GL_TRIANGLE_STRIP 0x0005
#define GL_TRIANGLE_FAN 0x0006
#define GL_QUADS 0x0007
#define GL_QUAD_STRIP 0x0008
#define GL_POLYGON 0x0009

#define GL_MODELVIEW 0x1700
#define GL_PROJECTION 0x1701
#define GL_TEXTURE 0x1702

#define GL_VERTEX_ARRAY 0x8074
#define GL_NORMAL_ARRAY 0x8075
#define GL_COLOR_ARRAY 0x8076
#define GL_TEXTURE_COORD_ARRAY 0x8078

#define GL_COMPILE 0x1300
#define GL_COMPILE_AND_EXECUTE 0x1301

#define GL_FLOAT 0x1406
#define GL_UNSIGNED_BYTE 0x1401
#define GL_UNSIGNED_SHORT 0x1403
#define GL_UNSIGNED_INT 0x1405
#define GL_INT 0x1404
#define GL_SHORT 0x1402
#define GL_DOUBLE 0x140A

#define GL_CURRENT_PROGRAM 0x8B8D
#define GL_VERTEX_ARRAY_BINDING 0x85B5
#define GL_ARRAY_BUFFER 0x8892
#define GL_ARRAY_BUFFER_BINDING 0x8894
#define GL_STREAM_DRAW 0x88E0
#define GL_LIGHTING 0x0B50
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE_ENV 0x2300
#define GL_TEXTURE_ENV_MODE 0x2200
#define GL_MODULATE 0x2100
#define GL_DECAL 0x2101
#define GL_BLEND 0x0BE2
#define GL_REPLACE 0x1E01
#define GL_SAMPLER_2D 0x8B5E
#define GL_TEXTURE0 0x84C0

#define GL_FALSE 0
#define GL_TRUE 1

#define MAX_STACK 64

#ifndef EXPORT
#define EXPORT __attribute__((visibility("default")))
#endif

/* ---- GL entry points we need from the real driver -------------------------- */
static void *(*p_glXGetProcAddress)(const GLubyte *) = NULL;
static void *(*p_glXGetProcAddressARB)(const GLubyte *) = NULL;

static void *Resolve(const char *name) {
    void *fn = NULL;
    if (p_glXGetProcAddressARB) fn = p_glXGetProcAddressARB((const GLubyte *)name);
    if (!fn && p_glXGetProcAddress) fn = p_glXGetProcAddress((const GLubyte *)name);
    if (!fn) fn = dlsym(RTLD_NEXT, name);
    return fn;
}

#define DECL(ret, name, args) typedef ret(*PFN_##name) args; static PFN_##name p_##name = NULL;
DECL(void, glGetIntegerv, (GLenum, GLint *))
DECL(GLenum, glGetError, (void))
DECL(GLboolean, glIsEnabled, (GLenum))
DECL(void, glGenBuffers, (GLsizei, GLuint *))
DECL(void, glBindBuffer, (GLenum, GLuint))
DECL(void, glBufferData, (GLenum, GLsizeiptr, const void *, GLenum))
DECL(GLuint, glCreateShader, (GLenum))
DECL(void, glShaderSource, (GLuint, GLsizei, const GLchar *const *, const GLint *))
DECL(void, glCompileShader, (GLuint))
DECL(void, glGetShaderiv, (GLuint, GLenum, GLint *))
DECL(void, glGetShaderInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *))
DECL(GLuint, glCreateProgram, (void))
DECL(void, glAttachShader, (GLuint, GLuint))
DECL(void, glBindAttribLocation, (GLuint, GLuint, const GLchar *))
DECL(void, glLinkProgram, (GLuint))
DECL(void, glGetProgramiv, (GLuint, GLenum, GLint *))
DECL(void, glGetProgramInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *))
DECL(void, glUseProgram, (GLuint))
DECL(GLint, glGetUniformLocation, (GLuint, const GLchar *))
DECL(void, glUniformMatrix4fv, (GLint, GLsizei, GLboolean, const GLfloat *))
DECL(void, glUniformMatrix3fv, (GLint, GLsizei, GLboolean, const GLfloat *))
DECL(void, glUniform1i, (GLint, GLint))
DECL(void, glEnableVertexAttribArray, (GLuint))
DECL(void, glDisableVertexAttribArray, (GLuint))
DECL(void, glVertexAttribPointer, (GLuint, GLint, GLenum, GLboolean, GLsizei, const void *))
DECL(void, glGenVertexArrays, (GLsizei, GLuint *))
DECL(void, glBindVertexArray, (GLuint))
DECL(void, glDrawArrays, (GLenum, GLint, GLsizei))
DECL(void, glDrawElements, (GLenum, GLsizei, GLenum, const void *))
DECL(void, glEnable, (GLenum))
DECL(void, glActiveTexture, (GLenum))
DECL(void, glBindTexture, (GLenum, GLuint))
DECL(void, glTexImage2D, (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *))
DECL(void, glDisable, (GLenum))

static void InitFns(void) {
    if (!p_glXGetProcAddress && !p_glXGetProcAddressARB) {
        p_glXGetProcAddress = (void *(*)(const GLubyte *))dlsym(RTLD_NEXT, "glXGetProcAddress");
        p_glXGetProcAddressARB =
            (void *(*)(const GLubyte *))dlsym(RTLD_NEXT, "glXGetProcAddressARB");
    }
#define LOAD(name)                                                                                 \
    if (!p_##name) p_##name = (PFN_##name)Resolve(#name);
    LOAD(glGetIntegerv) LOAD(glGetError) LOAD(glIsEnabled) LOAD(glGenBuffers) LOAD(glBindBuffer)
    LOAD(glBufferData) LOAD(glCreateShader) LOAD(glShaderSource) LOAD(glCompileShader)
    LOAD(glGetShaderiv) LOAD(glGetShaderInfoLog) LOAD(glCreateProgram) LOAD(glAttachShader)
    LOAD(glBindAttribLocation) LOAD(glLinkProgram) LOAD(glGetProgramiv) LOAD(glGetProgramInfoLog)
    LOAD(glUseProgram) LOAD(glGetUniformLocation) LOAD(glUniformMatrix4fv) LOAD(glUniformMatrix3fv)
    LOAD(glUniform1i) LOAD(glEnableVertexAttribArray) LOAD(glDisableVertexAttribArray)
    LOAD(glVertexAttribPointer) LOAD(glGenVertexArrays) LOAD(glBindVertexArray) LOAD(glDrawArrays)
    LOAD(glDrawElements) LOAD(glEnable) LOAD(glDisable) LOAD(glActiveTexture) LOAD(glBindTexture)
    LOAD(glTexImage2D)
#undef LOAD
}

/* ---- vertex / matrix ------------------------------------------------------- */
typedef struct {
    GLfloat pos[3];
    GLfloat col[4];
    GLfloat nrm[3];
    GLfloat uv[2];
} Vertex;

static void MatIdentity(GLfloat *m) {
    memset(m, 0, 16 * sizeof(GLfloat));
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

static void MatMul(GLfloat *out, const GLfloat *a, const GLfloat *b) { /* out = a * b */
    GLfloat r[16];
    for (int c = 0; c < 4; ++c)
        for (int rw = 0; rw < 4; ++rw) {
            GLfloat s = 0.0f;
            for (int k = 0; k < 4; ++k) s += a[k * 4 + rw] * b[c * 4 + k];
            r[c * 4 + rw] = s;
        }
    memcpy(out, r, sizeof(r));
}

typedef struct {
    GLenum mode;
    GLfloat mat[MAX_STACK][16];
    int depth;
} MatStack;

static GLenum g_matrixMode = GL_MODELVIEW;
static MatStack g_proj, g_mv, g_tex;
static Vertex *g_verts = NULL;
static size_t g_vertCount = 0, g_vertCap = 0;
static GLenum g_beginMode = 0;
static GLboolean g_inBegin = GL_FALSE;
static GLfloat g_color[4] = {1, 1, 1, 1};
static GLfloat g_normal[3] = {0, 0, 1};
static GLfloat g_texCoord[2] = {0, 0};
static GLboolean g_texture2D = GL_FALSE;
static GLuint g_boundTex2D = 0;
static GLint g_texEnvMode = GL_MODULATE;
static GLfloat g_matDiffuse[4] = {1, 1, 1, 1};
static GLboolean g_colorMaterial = GL_FALSE;
static GLboolean g_litAtBegin = GL_FALSE;
static GLboolean g_lighting = GL_FALSE;
static int g_dbg = -1;
static void Dbg(const char *fmt, ...) {
    if (g_dbg == -1) { const char *e = getenv("FIXFUNC_DEBUG"); g_dbg = e && *e == '1'; }
    if (!g_dbg) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static MatStack *CurrentStack(void) {
    switch (g_matrixMode) {
    case GL_PROJECTION: return &g_proj;
    case GL_TEXTURE: return &g_tex;
    default: return &g_mv;
    }
}

static void InitMatrices(void) {
    static GLboolean done = GL_FALSE;
    if (done) return;
    done = GL_TRUE;
    g_proj.mode = GL_PROJECTION;
    g_mv.mode = GL_MODELVIEW;
    g_tex.mode = GL_TEXTURE;
    MatIdentity(g_proj.mat[0]);
    MatIdentity(g_mv.mat[0]);
    MatIdentity(g_tex.mat[0]);
    g_proj.depth = g_mv.depth = g_tex.depth = 0;
}

/* ---- the shader ------------------------------------------------------------ */
static GLuint g_program = 0, g_vbo = 0, g_vao = 0;
static GLint g_uMVP = -1, g_uNorm = -1, g_uLit = -1, g_uTex = -1, g_uTexMode = -1;
static GLboolean g_pipelineReady = GL_FALSE, g_pipelineFailed = GL_FALSE;

static GLuint Compile(GLenum type, const char *src) {
    GLuint s = p_glCreateShader(type);
    p_glShaderSource(s, 1, &src, NULL);
    p_glCompileShader(s);
    GLint ok = 0;
    p_glGetShaderiv(s, 0x8B81 /*GL_COMPILE_STATUS*/, &ok);
    if (!ok) {
        char log[1024] = {0};
        p_glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "[fixfunc] shader compile failed: %s\n", log);
        return 0;
    }
    return s;
}

static void PreparePipeline(void) {
    if (g_pipelineReady || g_pipelineFailed) return;
    InitFns();
    if (!p_glCreateShader || !p_glGenBuffers || !p_glDrawArrays) {
        g_pipelineFailed = GL_TRUE;
        return;
    }
    static const char *vs =
        "#version 120\n"
        "attribute vec3 aPos; attribute vec4 aColor; attribute vec3 aNormal;\n"
        "attribute vec2 aTexCoord;\n"
        "uniform mat4 uMVP; uniform mat3 uNorm; uniform int uLit;\n"
        "varying vec4 vColor; varying vec2 vTex;\n"
        "void main(){\n"
        "  gl_Position = uMVP * vec4(aPos, 1.0);\n"
        "  vTex = aTexCoord;\n"
        "  if (uLit != 0) { vec3 n = normalize(uNorm * aNormal);\n"
        "    float d = clamp(abs(n.z), 0.0, 1.0) * 0.75 + 0.25;\n"
        "    vColor = vec4(aColor.rgb * d, aColor.a); }\n"
        "  else vColor = aColor;\n"
        "}\n";
    static const char *fs =
        "#version 120\n"
        "varying vec4 vColor; varying vec2 vTex;\n"
        "uniform sampler2D uTex; uniform int uTexMode;\n"
        "void main(){\n"
        "  vec4 c = vColor;\n"
        "  if (uTexMode != 0) {\n"
        "    vec4 t = texture2D(uTex, vTex);\n"
        "    if (uTexMode == 0x2100) c = vColor * t;\n"                    /* MODULATE */
        "    else if (uTexMode == 0x1E01) c = vec4(t.rgb, vColor.a * t.a);\n" /* REPLACE */
        "    else if (uTexMode == 0x2101) c = vec4(mix(vColor.rgb, t.rgb, t.a), vColor.a);\n" /* DECAL */
        "    else if (uTexMode == 0x0BE2) c = vec4(mix(vColor.rgb, t.rgb, t.rgb), vColor.a);\n" /* BLEND */
        "    else c = vColor * t;\n"
        "  }\n"
        "  gl_FragColor = c;\n"
        "}\n";
    GLuint v = Compile(0x8B31 /*VERTEX_SHADER*/, vs);
    GLuint f = Compile(0x8B30 /*FRAGMENT_SHADER*/, fs);
    if (!v || !f) {
        g_pipelineFailed = GL_TRUE;
        return;
    }
    g_program = p_glCreateProgram();
    p_glAttachShader(g_program, v);
    p_glAttachShader(g_program, f);
    p_glBindAttribLocation(g_program, 0, "aPos");
    p_glBindAttribLocation(g_program, 1, "aColor");
    p_glBindAttribLocation(g_program, 2, "aNormal");
    p_glBindAttribLocation(g_program, 3, "aTexCoord");
    p_glLinkProgram(g_program);
    GLint ok = 0;
    p_glGetProgramiv(g_program, 0x8B82 /*LINK_STATUS*/, &ok);
    if (!ok) {
        char log[1024] = {0};
        p_glGetProgramInfoLog(g_program, sizeof(log), NULL, log);
        fprintf(stderr, "[fixfunc] program link failed: %s\n", log);
        g_pipelineFailed = GL_TRUE;
        return;
    }
    g_uMVP = p_glGetUniformLocation(g_program, "uMVP");
    g_uNorm = p_glGetUniformLocation(g_program, "uNorm");
    g_uLit = p_glGetUniformLocation(g_program, "uLit");
    g_uTex = p_glGetUniformLocation(g_program, "uTex");
    g_uTexMode = p_glGetUniformLocation(g_program, "uTexMode");
    p_glGenBuffers(1, &g_vbo);
    if (p_glGenVertexArrays) {
        p_glGenVertexArrays(1, &g_vao);
        p_glBindVertexArray(g_vao);
        p_glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        p_glEnableVertexAttribArray(0);
        p_glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                                (const void *)offsetof(Vertex, pos));
        p_glEnableVertexAttribArray(1);
        p_glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                                (const void *)offsetof(Vertex, col));
        p_glEnableVertexAttribArray(2);
        p_glVertexAttribPointer(2, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                                (const void *)offsetof(Vertex, nrm));
        p_glEnableVertexAttribArray(3);
        p_glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                                (const void *)offsetof(Vertex, uv));
    }
    g_pipelineReady = GL_TRUE;
}

/* Draw n vertices of `mode` through the shader with the current matrices. */
static void DrawVertices(GLenum mode, const Vertex *verts, size_t n) {
    if (n == 0) return;
    PreparePipeline();
    if (!g_pipelineReady) return;
    InitFns();

    GLint prevProgram = 0, prevVao = 0, prevBuf = 0;
    p_glGetIntegerv(GL_CURRENT_PROGRAM, &prevProgram);
    p_glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &prevVao);
    p_glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &prevBuf);

    if (g_vao) p_glBindVertexArray(g_vao);
    p_glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    p_glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(n * sizeof(Vertex)), verts, GL_STREAM_DRAW);
    if (!g_vao) {
        p_glEnableVertexAttribArray(0);
        p_glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                                (const void *)offsetof(Vertex, pos));
        p_glEnableVertexAttribArray(1);
        p_glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                                (const void *)offsetof(Vertex, col));
        p_glEnableVertexAttribArray(2);
        p_glVertexAttribPointer(2, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                                (const void *)offsetof(Vertex, nrm));
        p_glEnableVertexAttribArray(3);
        p_glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                                (const void *)offsetof(Vertex, uv));
    }

    const GLfloat *proj = g_proj.mat[g_proj.depth];
    const GLfloat *mv = g_mv.mat[g_mv.depth];
    GLfloat mvp[16];
    MatMul(mvp, proj, mv);
    GLfloat nrm[9] = {mv[0], mv[1], mv[2], mv[4], mv[5], mv[6], mv[8], mv[9], mv[10]};
    GLint lit = 0;
    if (p_glIsEnabled && p_glIsEnabled(GL_LIGHTING)) lit = 1;

    /* bind the app's texture on unit 0 while we draw, then put the binding back */
    GLboolean useTex = (g_texture2D && g_boundTex2D != 0 && p_glGetIntegerv) ? GL_TRUE : GL_FALSE;
    GLint prevActive = GL_TEXTURE0, prevTex = 0;
    if (useTex) {
        p_glGetIntegerv(0x84E0 /*GL_ACTIVE_TEXTURE*/, &prevActive);
        p_glGetIntegerv(0x8069 /*GL_TEXTURE_BINDING_2D*/, &prevTex);
        p_glActiveTexture(GL_TEXTURE0);
        p_glBindTexture(GL_TEXTURE_2D, g_boundTex2D);
    }

    p_glUseProgram(g_program);
    p_glUniformMatrix4fv(g_uMVP, 1, GL_FALSE, mvp);
    p_glUniformMatrix3fv(g_uNorm, 1, GL_FALSE, nrm);
    p_glUniform1i(g_uLit, lit);
    if (g_uTex >= 0) p_glUniform1i(g_uTex, 0);
    if (g_uTexMode >= 0) p_glUniform1i(g_uTexMode, useTex ? g_texEnvMode : 0);
    p_glDrawArrays(mode, 0, (GLsizei)n);

    if (useTex) {
        p_glBindTexture(GL_TEXTURE_2D, (GLuint)prevTex);
        if (p_glActiveTexture) p_glActiveTexture((GLenum)prevActive);
    }
    if (g_vao) p_glBindVertexArray((GLuint)prevVao);
    p_glBindBuffer(GL_ARRAY_BUFFER, (GLuint)prevBuf);
    p_glUseProgram((GLuint)prevProgram);
}

/* ---- display lists --------------------------------------------------------- */
enum { CMD_PUSH, CMD_POP, CMD_LOADID, CMD_LOAD, CMD_MULT, CMD_MODE, CMD_DRAW };

typedef struct {
    int type;
    GLenum mode;      /* CMD_MODE */
    GLfloat mat[16];  /* CMD_LOAD / CMD_MULT */
    GLenum prim;      /* CMD_DRAW */
    size_t n;
    Vertex *verts;
} Cmd;

typedef struct {
    Cmd *cmds;
    size_t count, cap;
} List;

static List **g_lists = NULL;
static GLuint g_listCap = 0;
static GLuint g_listBase = 1; /* names [base, base+n) */
static GLuint g_listCount = 0;
static List *g_recording = NULL;
static GLboolean g_recordingExecute = GL_FALSE;
static GLuint g_pendingBase = 0;

static void ListPush(List *l, const Cmd *c) {
    if (l->count == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 64;
        l->cmds = (Cmd *)realloc(l->cmds, l->cap * sizeof(Cmd));
    }
    l->cmds[l->count++] = *c;
}

static void ExecuteCommand(const Cmd *c) {
    MatStack *st = CurrentStack();
    switch (c->type) {
    case CMD_PUSH:
        if (st->depth + 1 < MAX_STACK) {
            memcpy(st->mat[st->depth + 1], st->mat[st->depth], sizeof(GLfloat) * 16);
            st->depth++;
        }
        break;
    case CMD_POP:
        if (st->depth > 0) st->depth--;
        break;
    case CMD_LOADID: MatIdentity(st->mat[st->depth]); break;
    case CMD_LOAD: memcpy(st->mat[st->depth], c->mat, sizeof(GLfloat) * 16); break;
    case CMD_MULT: MatMul(st->mat[st->depth], st->mat[st->depth], c->mat); break;
    case CMD_MODE: g_matrixMode = c->mode; break;
    case CMD_DRAW: DrawVertices(c->prim, c->verts, c->n); break;
    default: break;
    }
}

/* ---- immediate mode -------------------------------------------------------- */
static void FlushBegin(void) {
    if (!g_inBegin) return;
    g_inBegin = GL_FALSE;

    /* expand quads / polygons into triangles so the core profile can draw them */
    Vertex *out = g_verts;
    size_t outN = g_vertCount;
    Vertex *tmp = NULL;
    GLenum prim = g_beginMode;

    if (g_beginMode == GL_QUADS || g_beginMode == GL_QUAD_STRIP || g_beginMode == GL_POLYGON) {
        size_t need = 0;
        if (g_beginMode == GL_QUADS) need = (g_vertCount / 4) * 6;
        else if (g_beginMode == GL_QUAD_STRIP)
            need = (g_vertCount >= 4) ? ((g_vertCount - 2) / 2) * 6 : 0;
        else /* GL_POLYGON */
            need = (g_vertCount >= 3) ? (g_vertCount - 2) * 3 : 0;

        tmp = (Vertex *)malloc((need ? need : 1) * sizeof(Vertex));
        outN = 0;
        if (g_beginMode == GL_QUADS) {
            for (size_t i = 0; i + 3 < g_vertCount; i += 4) {
                tmp[outN++] = g_verts[i];
                tmp[outN++] = g_verts[i + 1];
                tmp[outN++] = g_verts[i + 2];
                tmp[outN++] = g_verts[i];
                tmp[outN++] = g_verts[i + 2];
                tmp[outN++] = g_verts[i + 3];
            }
        } else if (g_beginMode == GL_QUAD_STRIP) {
            for (size_t i = 0; i + 3 < g_vertCount; i += 2) {
                tmp[outN++] = g_verts[i];
                tmp[outN++] = g_verts[i + 1];
                tmp[outN++] = g_verts[i + 3];
                tmp[outN++] = g_verts[i];
                tmp[outN++] = g_verts[i + 3];
                tmp[outN++] = g_verts[i + 2];
            }
        } else { /* GL_POLYGON: fan from the first vertex */
            for (size_t i = 1; i + 1 < g_vertCount; ++i) {
                tmp[outN++] = g_verts[0];
                tmp[outN++] = g_verts[i];
                tmp[outN++] = g_verts[i + 1];
            }
        }
        out = tmp;
        prim = GL_TRIANGLES;
    }

    if (g_recording) {
        Cmd c;
        memset(&c, 0, sizeof(c));
        c.type = CMD_DRAW;
        c.prim = prim;
        c.n = outN;
        if (outN) {
            c.verts = (Vertex *)malloc(outN * sizeof(Vertex));
            memcpy(c.verts, out, outN * sizeof(Vertex));
        }
        ListPush(g_recording, &c);
    }
    if (!g_recording || g_recordingExecute) DrawVertices(prim, out, outN);

    free(tmp);
    g_vertCount = 0;
}

static void PushVertex(GLfloat x, GLfloat y, GLfloat z) {
    if (g_vertCount == g_vertCap) {
        g_vertCap = g_vertCap ? g_vertCap * 2 : 4096;
        g_verts = (Vertex *)realloc(g_verts, g_vertCap * sizeof(Vertex));
    }
    Vertex *v = &g_verts[g_vertCount++];
    v->pos[0] = x;
    v->pos[1] = y;
    v->pos[2] = z;
    memcpy(v->col, g_litAtBegin ? g_matDiffuse : g_color, sizeof(g_color));
    memcpy(v->nrm, g_normal, sizeof(g_normal));
    memcpy(v->uv, g_texCoord, sizeof(g_texCoord));
}

/* ---- capability tracking --------------------------------------------------- */
#define GL_COLOR_MATERIAL 0x0B57

EXPORT void glEnable(GLenum cap) {
    InitFns();
    if (cap == GL_LIGHTING) g_lighting = GL_TRUE;
    else if (cap == GL_COLOR_MATERIAL) g_colorMaterial = GL_TRUE;
    else if (cap == GL_TEXTURE_2D) g_texture2D = GL_TRUE;
    if (!p_glEnable) p_glEnable = (PFN_glEnable)Resolve("glEnable");
    if (p_glEnable) p_glEnable(cap);
}

EXPORT void glDisable(GLenum cap) {
    InitFns();
    if (cap == GL_LIGHTING) g_lighting = GL_FALSE;
    else if (cap == GL_COLOR_MATERIAL) g_colorMaterial = GL_FALSE;
    else if (cap == GL_TEXTURE_2D) g_texture2D = GL_FALSE;
    if (!p_glDisable) p_glDisable = (PFN_glDisable)Resolve("glDisable");
    if (p_glDisable) p_glDisable(cap);
}

/* ---- texture state --------------------------------------------------------- */
#define GL_RGBA 0x1908
#define GL_RGB 0x1907
#define GL_BGRA 0x80E1
#define GL_RGBA8 0x8058
#define GL_SRGB8_ALPHA8 0x8C43
#define GL_RGB8 0x8051

EXPORT void glBindTexture(GLenum target, GLuint texture) {
    InitFns();
    if (target == GL_TEXTURE_2D) g_boundTex2D = texture;
    if (!p_glBindTexture) p_glBindTexture = (PFN_glBindTexture)Resolve("glBindTexture");
    if (p_glBindTexture) p_glBindTexture(target, texture);
}

EXPORT void glActiveTexture(GLenum unit) {
    InitFns();
    if (!p_glActiveTexture) p_glActiveTexture = (PFN_glActiveTexture)Resolve("glActiveTexture");
    if (p_glActiveTexture) p_glActiveTexture(unit);
}

typedef void (*PFN_glTexEnviF)(GLenum, GLenum, GLint);
typedef void (*PFN_glTexEnvfF)(GLenum, GLenum, GLfloat);

EXPORT void glTexEnvi(GLenum target, GLenum pname, GLint param) {
    InitFns();
    if (target == GL_TEXTURE_ENV && pname == GL_TEXTURE_ENV_MODE) g_texEnvMode = param;
    static PFN_glTexEnviF p = NULL;
    if (!p) p = (PFN_glTexEnviF)Resolve("glTexEnvi");
    if (p) p(target, pname, param);
}

EXPORT void glTexEnvf(GLenum target, GLenum pname, GLfloat param) {
    InitFns();
    if (target == GL_TEXTURE_ENV && pname == GL_TEXTURE_ENV_MODE) g_texEnvMode = (GLint)param;
    static PFN_glTexEnvfF p = NULL;
    if (!p) p = (PFN_glTexEnvfF)Resolve("glTexEnvf");
    if (p) p(target, pname, param);
}

/* Legacy code uploads unsized internal formats (GL_RGBA, GL_RGB, BGRA...). A core profile
   rejects those, so translate them to their sized equivalents on the way through. */
EXPORT void glTexImage2D(GLenum target, GLint level, GLint internalFormat, GLsizei width,
                         GLsizei height, GLint border, GLenum format, GLenum type,
                         const void *pixels) {
    InitFns();
    GLint sized = internalFormat;
    switch (internalFormat) {
    case GL_RGBA: sized = GL_RGBA8; break;
    case GL_RGB: sized = GL_RGB8; break;
    case GL_BGRA: sized = GL_RGBA8; break;
    default: break;
    }
    if (!p_glTexImage2D) p_glTexImage2D = (PFN_glTexImage2D)Resolve("glTexImage2D");
    if (p_glTexImage2D) p_glTexImage2D(target, level, sized, width, height, border, format, type,
                                       pixels);
}

/* ---- exported API ---------------------------------------------------------- */
#define EXPORT __attribute__((visibility("default")))

EXPORT void glBegin(GLenum mode) {
    InitMatrices();
    FlushBegin();
    InitFns();
    g_litAtBegin = g_lighting;
    if (g_inBegin == GL_FALSE) Dbg("[ff] glBegin mode=0x%x lit=%d mat=%.2f,%.2f,%.2f\n", mode,
                                   (int)g_litAtBegin, g_matDiffuse[0], g_matDiffuse[1],
                                   g_matDiffuse[2]);
    g_beginMode = mode;
    g_inBegin = GL_TRUE;
}

EXPORT void glEnd(void) { FlushBegin(); }

EXPORT void glVertex2f(GLfloat x, GLfloat y) { PushVertex(x, y, 0.0f); }
EXPORT void glVertex2d(GLdouble x, GLdouble y) { PushVertex((GLfloat)x, (GLfloat)y, 0.0f); }
EXPORT void glVertex3f(GLfloat x, GLfloat y, GLfloat z) { PushVertex(x, y, z); }
EXPORT void glVertex3d(GLdouble x, GLdouble y, GLdouble z) {
    PushVertex((GLfloat)x, (GLfloat)y, (GLfloat)z);
}
EXPORT void glVertex4f(GLfloat x, GLfloat y, GLfloat z, GLfloat w) {
    (void)w;
    PushVertex(x, y, z);
}
EXPORT void glVertex2fv(const GLfloat *v) { PushVertex(v[0], v[1], 0.0f); }
EXPORT void glVertex3fv(const GLfloat *v) { PushVertex(v[0], v[1], v[2]); }
EXPORT void glVertex4fv(const GLfloat *v) { PushVertex(v[0], v[1], v[2]); }
EXPORT void glVertex3dv(const GLdouble *v) {
    PushVertex((GLfloat)v[0], (GLfloat)v[1], (GLfloat)v[2]);
}

static void SyncColorMaterial(void) {
    Dbg("[ff] glColor -> %.2f %.2f %.2f\n", g_color[0], g_color[1], g_color[2]);
    if (g_colorMaterial) memcpy(g_matDiffuse, g_color, sizeof(g_color));
}

EXPORT void glColor3f(GLfloat r, GLfloat g, GLfloat b) {
    g_color[0] = r;
    g_color[1] = g;
    g_color[2] = b;
    g_color[3] = 1.0f;
    SyncColorMaterial();
}
EXPORT void glColor4f(GLfloat r, GLfloat g, GLfloat b, GLfloat a) {
    g_color[0] = r;
    g_color[1] = g;
    g_color[2] = b;
    g_color[3] = a;
    SyncColorMaterial();
}
EXPORT void glColor3fv(const GLfloat *v) {
    g_color[0] = v[0];
    g_color[1] = v[1];
    g_color[2] = v[2];
    g_color[3] = 1.0f;
}
EXPORT void glColor4fv(const GLfloat *v) { memcpy(g_color, v, sizeof(g_color)); }
EXPORT void glColor3d(GLdouble r, GLdouble g, GLdouble b) {
    glColor3f((GLfloat)r, (GLfloat)g, (GLfloat)b);
}
EXPORT void glColor4d(GLdouble r, GLdouble g, GLdouble b, GLdouble a) {
    glColor4f((GLfloat)r, (GLfloat)g, (GLfloat)b, (GLfloat)a);
}
EXPORT void glColor3ub(GLubyte r, GLubyte g, GLubyte b) {
    glColor3f(r / 255.0f, g / 255.0f, b / 255.0f);
}
EXPORT void glColor4ub(GLubyte r, GLubyte g, GLubyte b, GLubyte a) {
    glColor4f(r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);
}
EXPORT void glColor3ubv(const GLubyte *v) { glColor3ub(v[0], v[1], v[2]); }
EXPORT void glColor4ubv(const GLubyte *v) { glColor4ub(v[0], v[1], v[2], v[3]); }
EXPORT void glColor3ui(GLuint r, GLuint g, GLuint b) {
    glColor3f((GLfloat)r / 4294967295.0f, (GLfloat)g / 4294967295.0f,
              (GLfloat)b / 4294967295.0f);
}

EXPORT void glNormal3f(GLfloat x, GLfloat y, GLfloat z) {
    g_normal[0] = x;
    g_normal[1] = y;
    g_normal[2] = z;
}
EXPORT void glNormal3fv(const GLfloat *v) { memcpy(g_normal, v, sizeof(g_normal)); }
EXPORT void glNormal3d(GLdouble x, GLdouble y, GLdouble z) {
    glNormal3f((GLfloat)x, (GLfloat)y, (GLfloat)z);
}

EXPORT void glTexCoord2f(GLfloat s, GLfloat t) {
    g_texCoord[0] = s;
    g_texCoord[1] = t;
}
EXPORT void glTexCoord2d(GLdouble s, GLdouble t) { glTexCoord2f((GLfloat)s, (GLfloat)t); }
EXPORT void glTexCoord1f(GLfloat s) {
    g_texCoord[0] = s;
    g_texCoord[1] = 0.0f;
}
EXPORT void glTexCoord3f(GLfloat s, GLfloat t, GLfloat r) {
    (void)r;
    glTexCoord2f(s, t);
}
EXPORT void glTexCoord4f(GLfloat s, GLfloat t, GLfloat r, GLfloat q) {
    (void)r;
    if (q != 0.0f) glTexCoord2f(s / q, t / q);
    else glTexCoord2f(s, t);
}
EXPORT void glTexCoord2fv(const GLfloat *v) { glTexCoord2f(v[0], v[1]); }
EXPORT void glTexCoord2dv(const GLdouble *v) { glTexCoord2f((GLfloat)v[0], (GLfloat)v[1]); }
EXPORT void glTexCoord1fv(const GLfloat *v) { glTexCoord1f(v[0]); }
EXPORT void glMultiTexCoord2f(GLenum unit, GLfloat s, GLfloat t) {
    if (unit == GL_TEXTURE0) glTexCoord2f(s, t);
}
EXPORT void glMultiTexCoord2fv(GLenum unit, const GLfloat *v) {
    if (unit == GL_TEXTURE0) glTexCoord2fv(v);
}

/* ---- materials ------------------------------------------------------------- */
#define GL_AMBIENT 0x1200
#define GL_DIFFUSE 0x1201
#define GL_AMBIENT_AND_DIFFUSE 0x1602
#define GL_FRONT 0x0404
#define GL_BACK 0x0405
#define GL_FRONT_AND_BACK 0x0408

EXPORT void glMaterialfv(GLenum face, GLenum pname, const GLfloat *params) {
    (void)face;
    if (!params) return;
    Dbg("[ff] glMaterialfv pname=0x%x -> %.2f %.2f %.2f\n", pname, params[0], params[1], params[2]);
    if (pname == GL_AMBIENT_AND_DIFFUSE || pname == GL_DIFFUSE)
        memcpy(g_matDiffuse, params, sizeof(g_matDiffuse));
    else if (pname == GL_AMBIENT)
        for (int i = 0; i < 3; ++i) g_matDiffuse[i] = params[i];
}
EXPORT void glMaterialf(GLenum face, GLenum pname, GLfloat param) {
    if (pname == GL_AMBIENT_AND_DIFFUSE || pname == GL_DIFFUSE)
        g_matDiffuse[0] = g_matDiffuse[1] = g_matDiffuse[2] = param;
    (void)face;
}
EXPORT void glMateriali(GLenum face, GLenum pname, GLint param) {
    glMaterialf(face, pname, (GLfloat)param);
}
EXPORT void glColorMaterial(GLenum face, GLenum mode) {
    Dbg("[ff] glColorMaterial mode=0x%x\n", mode);
    (void)face;
    if (mode == GL_AMBIENT_AND_DIFFUSE || mode == GL_DIFFUSE) g_colorMaterial = GL_TRUE;
}
EXPORT void glLightfv(GLenum light, GLenum pname, const GLfloat *params) {
    (void)light;
    (void)pname;
    (void)params;
}
EXPORT void glLightModelfv(GLenum pname, const GLfloat *params) {
    (void)pname;
    (void)params;
}
EXPORT void glLightModeli(GLenum pname, GLint param) {
    (void)pname;
    (void)param;
}

/* ---- matrices -------------------------------------------------------------- */
EXPORT void glMatrixMode(GLenum mode) {
    InitMatrices();
    g_matrixMode = mode;
}
EXPORT void glLoadIdentity(void) {
    InitMatrices();
    MatStack *st = CurrentStack();
    MatIdentity(st->mat[st->depth]);
}
EXPORT void glPushMatrix(void) {
    InitMatrices();
    MatStack *st = CurrentStack();
    if (st->depth + 1 < MAX_STACK) {
        memcpy(st->mat[st->depth + 1], st->mat[st->depth], sizeof(GLfloat) * 16);
        st->depth++;
    }
}
EXPORT void glPopMatrix(void) {
    InitMatrices();
    MatStack *st = CurrentStack();
    if (st->depth > 0) st->depth--;
}
EXPORT void glLoadMatrixf(const GLfloat *m) {
    InitMatrices();
    MatStack *st = CurrentStack();
    memcpy(st->mat[st->depth], m, sizeof(GLfloat) * 16);
}
EXPORT void glMultMatrixf(const GLfloat *m) {
    InitMatrices();
    MatStack *st = CurrentStack();
    MatMul(st->mat[st->depth], st->mat[st->depth], m);
}
EXPORT void glTranslatef(GLfloat x, GLfloat y, GLfloat z) {
    InitMatrices();
    GLfloat t[16];
    MatIdentity(t);
    t[12] = x;
    t[13] = y;
    t[14] = z;
    MatStack *st = CurrentStack();
    MatMul(st->mat[st->depth], st->mat[st->depth], t);
}
EXPORT void glTranslated(GLdouble x, GLdouble y, GLdouble z) {
    glTranslatef((GLfloat)x, (GLfloat)y, (GLfloat)z);
}
EXPORT void glScalef(GLfloat x, GLfloat y, GLfloat z) {
    InitMatrices();
    GLfloat s[16];
    MatIdentity(s);
    s[0] = x;
    s[5] = y;
    s[10] = z;
    MatStack *st = CurrentStack();
    MatMul(st->mat[st->depth], st->mat[st->depth], s);
}
EXPORT void glRotatef(GLfloat angle, GLfloat x, GLfloat y, GLfloat z) {
    InitMatrices();
    GLfloat len = sqrtf(x * x + y * y + z * z);
    if (len < 1e-6f) return;
    x /= len;
    y /= len;
    z /= len;
    const GLfloat rad = angle * (GLfloat)M_PI / 180.0f;
    const GLfloat c = cosf(rad), s = sinf(rad), ic = 1.0f - c;
    GLfloat r[16];
    MatIdentity(r);
    r[0] = x * x * ic + c;
    r[1] = y * x * ic + z * s;
    r[2] = x * z * ic - y * s;
    r[4] = x * y * ic - z * s;
    r[5] = y * y * ic + c;
    r[6] = y * z * ic + x * s;
    r[8] = x * z * ic + y * s;
    r[9] = y * z * ic - x * s;
    r[10] = z * z * ic + c;
    MatStack *st = CurrentStack();
    MatMul(st->mat[st->depth], st->mat[st->depth], r);
}
EXPORT void glRotated(GLdouble angle, GLdouble x, GLdouble y, GLdouble z) {
    glRotatef((GLfloat)angle, (GLfloat)x, (GLfloat)y, (GLfloat)z);
}

EXPORT void glOrtho(GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f) {
    InitMatrices();
    GLfloat m[16];
    MatIdentity(m);
    m[0] = (GLfloat)(2.0 / (r - l));
    m[5] = (GLfloat)(2.0 / (t - b));
    m[10] = (GLfloat)(-2.0 / (f - n));
    m[12] = (GLfloat)(-(r + l) / (r - l));
    m[13] = (GLfloat)(-(t + b) / (t - b));
    m[14] = (GLfloat)(-(f + n) / (f - n));
    MatStack *st = CurrentStack();
    MatMul(st->mat[st->depth], st->mat[st->depth], m);
}
EXPORT void glFrustum(GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f) {
    InitMatrices();
    GLfloat m[16];
    memset(m, 0, sizeof(m));
    m[0] = (GLfloat)(2.0 * n / (r - l));
    m[5] = (GLfloat)(2.0 * n / (t - b));
    m[8] = (GLfloat)((r + l) / (r - l));
    m[9] = (GLfloat)((t + b) / (t - b));
    m[10] = (GLfloat)(-(f + n) / (f - n));
    m[11] = -1.0f;
    m[14] = (GLfloat)(-2.0f * f * n / (f - n));
    MatStack *st = CurrentStack();
    MatMul(st->mat[st->depth], st->mat[st->depth], m);
}

EXPORT void glShadeModel(GLenum mode) { (void)mode; }

/* ---- display lists --------------------------------------------------------- */
EXPORT GLuint glGenLists(GLsizei range) {
    if (range <= 0) return 0;
    if (!g_lists) {
        g_listCap = 1024;
        g_lists = (List **)calloc(g_listCap, sizeof(List *));
    }
    const GLuint base = g_listBase + g_listCount;
    g_listCount += (GLuint)range;
    if (base + (GLuint)range >= g_listCap) {
        GLuint newCap = g_listCap;
        while (newCap <= base + (GLuint)range) newCap *= 2;
        g_lists = (List **)realloc(g_lists, newCap * sizeof(List *));
        memset(g_lists + g_listCap, 0, (newCap - g_listCap) * sizeof(List *));
        g_listCap = newCap;
    }
    return base;
}

static GLuint ListIndex(GLuint name) { return name ? name - g_listBase : 0xFFFFFFFFu; }

EXPORT void glNewList(GLuint name, GLenum mode) {
    FlushBegin();
    const GLuint idx = ListIndex(name);
    if (idx >= g_listCap) return;
    List *l = (List *)calloc(1, sizeof(List));
    if (g_lists[idx]) {
        for (size_t i = 0; i < g_lists[idx]->count; ++i) free(g_lists[idx]->cmds[i].verts);
        free(g_lists[idx]->cmds);
        free(g_lists[idx]);
    }
    g_lists[idx] = l;
    g_recording = l;
    g_recordingExecute = (mode == GL_COMPILE_AND_EXECUTE) ? GL_TRUE : GL_FALSE;
    g_pendingBase = name;
}

EXPORT void glEndList(void) {
    FlushBegin();
    g_recording = NULL;
    g_recordingExecute = GL_FALSE;
}

EXPORT void glCallList(GLuint name) {
    FlushBegin();
    const GLuint idx = ListIndex(name);
    if (idx >= g_listCap || !g_lists[idx]) return;
    List *l = g_lists[idx];
    for (size_t i = 0; i < l->count; ++i) ExecuteCommand(&l->cmds[i]);
}

EXPORT void glCallLists(GLsizei n, GLenum type, const void *lists) {
    for (GLsizei i = 0; i < n; ++i) {
        GLuint name = 0;
        switch (type) {
        case GL_UNSIGNED_BYTE: name = ((const GLubyte *)lists)[i]; break;
        case GL_UNSIGNED_SHORT: name = ((const GLushort *)lists)[i]; break;
        case GL_UNSIGNED_INT: name = ((const GLuint *)lists)[i]; break;
        default: name = 0; break;
        }
        glCallList(name);
    }
}

EXPORT void glDeleteLists(GLuint name, GLsizei range) {
    for (GLsizei i = 0; i < range; ++i) {
        const GLuint idx = ListIndex(name + (GLuint)i);
        if (idx >= g_listCap || !g_lists[idx]) continue;
        for (size_t k = 0; k < g_lists[idx]->count; ++k) free(g_lists[idx]->cmds[k].verts);
        free(g_lists[idx]->cmds);
        free(g_lists[idx]);
        g_lists[idx] = NULL;
    }
}

EXPORT GLboolean glIsList(GLuint name) {
    const GLuint idx = ListIndex(name);
    return (idx < g_listCap && g_lists[idx]) ? GL_TRUE : GL_FALSE;
}

/* ---- client arrays --------------------------------------------------------- */
static const void *g_vertexPtr = NULL;
static GLint g_vertexSize = 4, g_vertexStride = 0;
static GLenum g_vertexType = GL_FLOAT;
static const void *g_colorPtr = NULL;
static GLint g_colorSize = 4, g_colorStride = 0;
static GLenum g_colorType = GL_FLOAT;
static const void *g_normalPtr = NULL;
static GLint g_normalStride = 0;
static GLenum g_normalType = GL_FLOAT;
static GLboolean g_vertexArrayOn = GL_FALSE, g_colorArrayOn = GL_FALSE, g_normalArrayOn = GL_FALSE;
static const void *g_texPtr = NULL;
static GLint g_texSize = 2, g_texStride = 0;
static GLenum g_texType = GL_FLOAT;
static GLboolean g_texArrayOn = GL_FALSE;

EXPORT void glEnableClientState(GLenum cap) {
    if (cap == GL_TEXTURE_COORD_ARRAY) g_texArrayOn = GL_TRUE;
    switch (cap) {
    case GL_VERTEX_ARRAY: g_vertexArrayOn = GL_TRUE; break;
    case GL_COLOR_ARRAY: g_colorArrayOn = GL_TRUE; break;
    case GL_NORMAL_ARRAY: g_normalArrayOn = GL_TRUE; break;
    default: break;
    }
}
EXPORT void glDisableClientState(GLenum cap) {
    if (cap == GL_TEXTURE_COORD_ARRAY) g_texArrayOn = GL_FALSE;
    switch (cap) {
    case GL_VERTEX_ARRAY: g_vertexArrayOn = GL_FALSE; break;
    case GL_COLOR_ARRAY: g_colorArrayOn = GL_FALSE; break;
    case GL_NORMAL_ARRAY: g_normalArrayOn = GL_FALSE; break;
    default: break;
    }
}
EXPORT void glVertexPointer(GLint size, GLenum type, GLsizei stride, const void *ptr) {
    g_vertexSize = size;
    g_vertexType = type;
    g_vertexStride = stride;
    g_vertexPtr = ptr;
}
EXPORT void glColorPointer(GLint size, GLenum type, GLsizei stride, const void *ptr) {
    g_colorSize = size;
    g_colorType = type;
    g_colorStride = stride;
    g_colorPtr = ptr;
}
EXPORT void glNormalPointer(GLenum type, GLsizei stride, const void *ptr) {
    g_normalType = type;
    g_normalStride = stride;
    g_normalPtr = ptr;
}
EXPORT void glTexCoordPointer(GLint size, GLenum type, GLsizei stride, const void *ptr) {
    g_texSize = size;
    g_texType = type;
    g_texStride = stride;
    g_texPtr = ptr;
}

static GLfloat ReadScalar(const void *base, size_t offset, GLenum type) {
    const unsigned char *p = (const unsigned char *)base + offset;
    switch (type) {
    case GL_FLOAT: return *(const GLfloat *)p;
    case GL_DOUBLE: return (GLfloat)(*(const GLdouble *)p);
    case GL_UNSIGNED_BYTE: return (GLfloat)(*(const GLubyte *)p) / 255.0f;
    case GL_SHORT: return (GLfloat)(*(const short *)p);
    case GL_UNSIGNED_SHORT: return (GLfloat)(*(const unsigned short *)p);
    case GL_INT: return (GLfloat)(*(const GLint *)p);
    case GL_UNSIGNED_INT: return (GLfloat)(*(const GLuint *)p);
    default: return 0.0f;
    }
}

EXPORT void glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    InitFns();
    GLint bufBinding = 0;
    if (p_glGetIntegerv) p_glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &bufBinding);
    if (!g_vertexArrayOn || !g_vertexPtr || bufBinding != 0 || count <= 0) {
        if (p_glDrawArrays) p_glDrawArrays(mode, first, count);
        return;
    }
    const GLsizei vstride = g_vertexStride ? g_vertexStride : (GLsizei)(g_vertexSize * 4);
    const GLsizei cstride = g_colorStride ? g_colorStride : (GLsizei)(g_colorSize * 4);
    const GLsizei nstride = g_normalStride ? g_normalStride : 12;
    Vertex *buf = (Vertex *)malloc((size_t)count * sizeof(Vertex));
    for (GLsizei i = 0; i < count; ++i) {
        const GLint v = first + i;
        Vertex *out = &buf[i];
        out->pos[0] = ReadScalar(g_vertexPtr, (size_t)v * vstride + 0, g_vertexType);
        out->pos[1] = ReadScalar(g_vertexPtr, (size_t)v * vstride + 4, g_vertexType);
        out->pos[2] = (g_vertexSize >= 3) ? ReadScalar(g_vertexPtr, (size_t)v * vstride + 8,
                                                       g_vertexType)
                                          : 0.0f;
        if (g_colorArrayOn && g_colorPtr) {
            out->col[0] = ReadScalar(g_colorPtr, (size_t)v * cstride + 0, g_colorType);
            out->col[1] = ReadScalar(g_colorPtr, (size_t)v * cstride + 4, g_colorType);
            out->col[2] = ReadScalar(g_colorPtr, (size_t)v * cstride + 8, g_colorType);
            out->col[3] = (g_colorSize >= 4) ? ReadScalar(g_colorPtr, (size_t)v * cstride + 12,
                                                          g_colorType)
                                             : 1.0f;
        } else {
            memcpy(out->col, g_color, sizeof(g_color));
        }
        if (g_texArrayOn && g_texPtr) {
            const GLsizei tstride = g_texStride ? g_texStride : (GLsizei)(g_texSize * 4);
            out->uv[0] = ReadScalar(g_texPtr, (size_t)v * tstride + 0, g_texType);
            out->uv[1] = ReadScalar(g_texPtr, (size_t)v * tstride + 4, g_texType);
        } else {
            memcpy(out->uv, g_texCoord, sizeof(g_texCoord));
        }
        if (g_normalArrayOn && g_normalPtr) {
            out->nrm[0] = ReadScalar(g_normalPtr, (size_t)v * nstride + 0, g_normalType);
            out->nrm[1] = ReadScalar(g_normalPtr, (size_t)v * nstride + 4, g_normalType);
            out->nrm[2] = ReadScalar(g_normalPtr, (size_t)v * nstride + 8, g_normalType);
        } else {
            memcpy(out->nrm, g_normal, sizeof(g_normal));
        }
    }
    DrawVertices(mode, buf, (size_t)count);
    free(buf);
}

/* ---- glXGetProcAddress interceptor ----------------------------------------- */
static const struct {
    const char *name;
    void *fn;
} kFixed[] = {
    {"glBegin", (void *)glBegin},
    {"glEnd", (void *)glEnd},
    {"glVertex2f", (void *)glVertex2f},
    {"glVertex2d", (void *)glVertex2d},
    {"glVertex3f", (void *)glVertex3f},
    {"glVertex3d", (void *)glVertex3d},
    {"glVertex4f", (void *)glVertex4f},
    {"glVertex2fv", (void *)glVertex2fv},
    {"glVertex3fv", (void *)glVertex3fv},
    {"glVertex4fv", (void *)glVertex4fv},
    {"glVertex3dv", (void *)glVertex3dv},
    {"glColor3f", (void *)glColor3f},
    {"glColor4f", (void *)glColor4f},
    {"glColor3fv", (void *)glColor3fv},
    {"glColor4fv", (void *)glColor4fv},
    {"glColor3d", (void *)glColor3d},
    {"glColor4d", (void *)glColor4d},
    {"glColor3ub", (void *)glColor3ub},
    {"glColor4ub", (void *)glColor4ub},
    {"glColor3ubv", (void *)glColor3ubv},
    {"glColor4ubv", (void *)glColor4ubv},
    {"glColor3ui", (void *)glColor3ui},
    {"glNormal3f", (void *)glNormal3f},
    {"glNormal3fv", (void *)glNormal3fv},
    {"glNormal3d", (void *)glNormal3d},
    {"glTexCoord1f", (void *)glTexCoord1f},
    {"glTexCoord1fv", (void *)glTexCoord1fv},
    {"glTexCoord2f", (void *)glTexCoord2f},
    {"glTexCoord2fv", (void *)glTexCoord2fv},
    {"glTexCoord2d", (void *)glTexCoord2d},
    {"glTexCoord2dv", (void *)glTexCoord2dv},
    {"glTexCoord3f", (void *)glTexCoord3f},
    {"glTexCoord4f", (void *)glTexCoord4f},
    {"glMultiTexCoord2fv", (void *)glMultiTexCoord2fv},
    {"glMultiTexCoord2f", (void *)glMultiTexCoord2f},
    {"glMatrixMode", (void *)glMatrixMode},
    {"glLoadIdentity", (void *)glLoadIdentity},
    {"glPushMatrix", (void *)glPushMatrix},
    {"glPopMatrix", (void *)glPopMatrix},
    {"glLoadMatrixf", (void *)glLoadMatrixf},
    {"glMultMatrixf", (void *)glMultMatrixf},
    {"glTranslatef", (void *)glTranslatef},
    {"glTranslated", (void *)glTranslated},
    {"glScalef", (void *)glScalef},
    {"glRotatef", (void *)glRotatef},
    {"glRotated", (void *)glRotated},
    {"glOrtho", (void *)glOrtho},
    {"glFrustum", (void *)glFrustum},
    {"glShadeModel", (void *)glShadeModel},
    {"glGenLists", (void *)glGenLists},
    {"glNewList", (void *)glNewList},
    {"glEndList", (void *)glEndList},
    {"glCallList", (void *)glCallList},
    {"glCallLists", (void *)glCallLists},
    {"glDeleteLists", (void *)glDeleteLists},
    {"glIsList", (void *)glIsList},
    {"glEnableClientState", (void *)glEnableClientState},
    {"glDisableClientState", (void *)glDisableClientState},
    {"glVertexPointer", (void *)glVertexPointer},
    {"glColorPointer", (void *)glColorPointer},
    {"glNormalPointer", (void *)glNormalPointer},
    {"glTexCoordPointer", (void *)glTexCoordPointer},
    {"glDrawArrays", (void *)glDrawArrays},
    {"glTexEnvi", (void *)glTexEnvi},
    {"glTexEnvf", (void *)glTexEnvf},
    {"glTexImage2D", (void *)glTexImage2D},
};

static void *LookupFixed(const char *name) {
    if (!name) return NULL;
    for (size_t i = 0; i < sizeof(kFixed) / sizeof(kFixed[0]); ++i)
        if (strcmp(kFixed[i].name, name) == 0) return kFixed[i].fn;
    return NULL;
}

EXPORT void *glXGetProcAddressARB(const GLubyte *name) {
    void *fn = LookupFixed((const char *)name);
    if (fn) return fn;
    if (!p_glXGetProcAddress && !p_glXGetProcAddressARB)
        InitFns();
    if (p_glXGetProcAddressARB) return p_glXGetProcAddressARB(name);
    if (p_glXGetProcAddress) return p_glXGetProcAddress(name);
    return dlsym(RTLD_NEXT, (const char *)name);
}

EXPORT void *glXGetProcAddress(const GLubyte *name) { return glXGetProcAddressARB(name); }
