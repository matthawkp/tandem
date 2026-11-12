// Applies frame messages to a canvas texture and draws it 1:1 on the panel: Tandem's
// Receiver/Renderer.swift, in OpenGL ES 3 in place of Metal.
//
// Lossless rects are decoded on the CPU into `mirror`, then uploaded into the canvas. BC7 rects
// are uploaded into a compressed texture and expanded into the canvas by the GPU. The last pass
// applies the Mac's colour adaptation (True Tone and Night Shift) and draws the Mac's pointer.
//
// The canvas keeps the Mac's bytes as they come, BGRA, in a texture OpenGL calls RGBA: nothing
// needs converting on the way in, and the shaders swap red and blue on the way out.
#include "tandem.h"

#include <GLES3/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef GL_COMPRESSED_RGBA_BPTC_UNORM_EXT
#define GL_COMPRESSED_RGBA_BPTC_UNORM_EXT 0x8E8C
#endif

struct rect {
    int x, y, w, h, encoding;
    size_t offset, count, staging;
};

struct renderer {
    struct output *output;
    int width, height;
    size_t stride;
    GLuint canvas, canvas_fbo, bc7, cursor, splash;
    GLuint present_program, expand_program, cursor_program, splash_program;
    GLint present_matrix, present_use_matrix, present_height, cursor_rect, splash_size, splash_dots, splash_time;
    uint8_t *mirror;
    uint8_t *staging;
    size_t staging_size;
    bool supports_bc7;
    float matrix[9];
    bool use_matrix;

    int cursor_w, cursor_h, hot_x, hot_y, cursor_x, cursor_y;
    bool cursor_visible, cursor_has_shape;

    uint8_t *splash_pixels;
    int splash_w, splash_h;
    bool splash_dirty;
    struct splash_dots dots; // in the splash picture's pixels
    double started;
    bool software;
    char title[200], detail[400], footer[300];
    bool show_log;
    unsigned log_seen;

    uint8_t *readback;
};

static const float identity[9] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };

// ---- Shaders ----------------------------------------------------------------------------------

static const char *full_screen_vertex =
    "#version 300 es\n"
    "void main() {\n"
    "    vec2 uv = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
    "    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

// Into the canvas, whose rows run the same way as the BC7 texture's.
static const char *expand_fragment =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform highp sampler2D blocks;\n"
    "out vec4 color;\n"
    "void main() {\n"
    "    vec3 c = texelFetch(blocks, ivec2(gl_FragCoord.xy), 0).rgb;\n"
    "    color = vec4(c.b, c.g, c.r, 1.0);\n"
    "}\n";

// Onto the screen, where row 0 is at the bottom.
static const char *present_fragment =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform highp sampler2D canvas;\n"
    "uniform mat3 matrix;\n"
    "uniform int useMatrix;\n"
    "uniform int height;\n"
    "out vec4 color;\n"
    "vec3 toLinear(vec3 c) {\n"
    "    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThanEqual(c, vec3(0.04045)));\n"
    "}\n"
    "vec3 toGamma(vec3 c) {\n"
    "    return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThanEqual(c, vec3(0.0031308)));\n"
    "}\n"
    "void main() {\n"
    "    ivec2 p = ivec2(int(gl_FragCoord.x), height - 1 - int(gl_FragCoord.y));\n"
    "    vec3 c = texelFetch(canvas, p, 0).bgr;\n"
    "    if (useMatrix != 0) {\n"
    "        vec3 l = max(matrix * toLinear(c), 0.0);\n"
    "        c = toGamma(min(l, 1.0));\n"
    "    }\n"
    "    color = vec4(c, 1.0);\n"
    "}\n";

static const char *cursor_vertex =
    "#version 300 es\n"
    "uniform vec4 rect;\n" // left, top, right, bottom, in clip space
    "out vec2 uv;\n"
    "void main() {\n"
    "    uv = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));\n"
    "    gl_Position = vec4(mix(rect.x, rect.z, uv.x), mix(rect.y, rect.w, uv.y), 0.0, 1.0);\n"
    "}\n";

static const char *cursor_fragment =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform sampler2D image;\n"
    "in vec2 uv;\n"
    "out vec4 color;\n"
    "void main() { color = texture(image, uv).bgra; }\n"; // premultiplied

// The waiting screen, scaled up from its picture, and its three dots brightening one after
// another: a pulse runs along them every 1.4 s.
static const char *splash_fragment =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform sampler2D image;\n"
    "uniform vec2 size;\n"
    "uniform vec4 dots;\n" // centre x, centre y (pixels from the top left), radius, spacing
    "uniform float time;\n"
    "out vec4 color;\n"
    "void main() {\n"
    "    vec2 p = vec2(gl_FragCoord.x, size.y - gl_FragCoord.y);\n"
    "    vec3 c = texture(image, p / size).rgb;\n"
    "    for (int i = 0; i < 3; i++) {\n"
    "        vec2 centre = vec2(dots.x + float(i - 1) * dots.w, dots.y);\n"
    "        float cover = clamp(dots.z + 0.5 - length(p - centre), 0.0, 1.0);\n"
    "        float wave = max(sin(6.2831853 * (time / 1.4 - float(i) * 0.16)), 0.0);\n"
    "        float bright = mix(" SPLASH_DOT_REST_TEXT ", 1.0, wave * wave);\n"
    "        c = mix(c, vec3(1.0), cover * bright);\n"
    "    }\n"
    "    color = vec4(c, 1.0);\n"
    "}\n";

static GLuint compile(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char info[400] = "";
        glGetShaderInfoLog(shader, sizeof info, NULL, info);
        log_line("shader error: %s", info);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint link_program(const char *vertex, const char *fragment) {
    GLuint v = compile(GL_VERTEX_SHADER, vertex), f = compile(GL_FRAGMENT_SHADER, fragment);
    if (!v || !f) return 0;
    GLuint program = glCreateProgram();
    glAttachShader(program, v);
    glAttachShader(program, f);
    glLinkProgram(program);
    glDeleteShader(v);
    glDeleteShader(f);
    GLint ok = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char info[400] = "";
        glGetProgramInfoLog(program, sizeof info, NULL, info);
        log_line("shader link error: %s", info);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

static bool has_extension(const char *name) {
    GLint count = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &count);
    for (GLint i = 0; i < count; i++) {
        const char *extension = (const char *)glGetStringi(GL_EXTENSIONS, (GLuint)i);
        if (extension && strcmp(extension, name) == 0) return true;
    }
    return false;
}

static GLuint make_texture(GLenum filter) {
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (GLint)filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (GLint)filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return texture;
}

// ---- Setting up -------------------------------------------------------------------------------

struct renderer *renderer_create(struct output *output) {
    struct renderer *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->output = output;
    r->width = output->width;
    r->height = output->height;
    r->stride = (size_t)r->width * 4;
    memcpy(r->matrix, identity, sizeof identity);
    output->begin(output);

    const char *gl_renderer = (const char *)glGetString(GL_RENDERER);
    log_line("OpenGL: %s, %s", gl_renderer, (const char *)glGetString(GL_VERSION));
    r->software = gl_renderer && (strstr(gl_renderer, "llvmpipe") || strstr(gl_renderer, "softpipe"));
    r->started = now_seconds();
    GLint largest = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &largest);
    if (largest < r->width || largest < r->height) {
        log_line("the picture (%dx%d) is larger than this GPU's textures (%d)", r->width, r->height, largest);
        return NULL;
    }

    r->present_program = link_program(full_screen_vertex, present_fragment);
    r->expand_program = link_program(full_screen_vertex, expand_fragment);
    r->cursor_program = link_program(cursor_vertex, cursor_fragment);
    r->splash_program = link_program(full_screen_vertex, splash_fragment);
    if (!r->present_program || !r->expand_program || !r->cursor_program || !r->splash_program) return NULL;
    r->present_matrix = glGetUniformLocation(r->present_program, "matrix");
    r->present_use_matrix = glGetUniformLocation(r->present_program, "useMatrix");
    r->present_height = glGetUniformLocation(r->present_program, "height");
    r->cursor_rect = glGetUniformLocation(r->cursor_program, "rect");
    r->splash_size = glGetUniformLocation(r->splash_program, "size");
    r->splash_dots = glGetUniformLocation(r->splash_program, "dots");
    r->splash_time = glGetUniformLocation(r->splash_program, "time");

    r->mirror = calloc((size_t)r->height, r->stride);
    if (!r->mirror) return NULL;
    r->canvas = make_texture(GL_NEAREST);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, r->width, r->height);
    glGenFramebuffers(1, &r->canvas_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, r->canvas_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, r->canvas, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        log_line("couldn't make the canvas (%dx%d)", r->width, r->height);
        return NULL;
    }

    if (has_extension("GL_EXT_texture_compression_bptc")) {
        int w4 = (r->width + 3) / 4 * 4, h4 = (r->height + 3) / 4 * 4;
        r->bc7 = make_texture(GL_NEAREST);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_COMPRESSED_RGBA_BPTC_UNORM_EXT, w4, h4);
        r->staging_size = (size_t)(w4 / 4) * (size_t)(h4 / 4) * 16;
        r->staging = malloc(r->staging_size);
        r->supports_bc7 = glGetError() == GL_NO_ERROR && r->staging != NULL;
    }

    r->cursor = make_texture(GL_LINEAR);

    // The waiting screen is drawn at half size on large panels, and scaled up: plenty for text.
    int divide = r->width >= 3000 ? 2 : 1;
    r->splash_w = r->width / divide;
    r->splash_h = r->height / divide;
    r->splash_pixels = calloc((size_t)r->splash_w * (size_t)r->splash_h, 4);
    r->splash = make_texture(GL_LINEAR);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, r->splash_w, r->splash_h);
    r->splash_dirty = true;

    log_line("renderer %dx%d, BC7 %s", r->width, r->height, r->supports_bc7 ? "supported" : "unsupported");
    renderer_clear(r);
    return r;
}

bool renderer_supports_bc7(struct renderer *r) { return r->supports_bc7; }

void renderer_clear(struct renderer *r) {
    memset(r->mirror, 0, r->stride * (size_t)r->height);
    glBindFramebuffer(GL_FRAMEBUFFER, r->canvas_fbo);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
}

void renderer_set_matrix(struct renderer *r, const float matrix[9]) {
    for (int i = 0; i < 9; i++) {
        if (!(matrix[i] == matrix[i]) || matrix[i] > 1e6f || matrix[i] < -1e6f) return; // NaN or absurd
    }
    memcpy(r->matrix, matrix, sizeof r->matrix);
    r->use_matrix = memcmp(matrix, identity, sizeof identity) != 0;
}

// ---- Frames -----------------------------------------------------------------------------------

struct decode_job {
    struct renderer *renderer;
    const uint8_t *body;
    struct rect *rects;
    bool failed;
};

static void decode_rect(void *context, int index) {
    struct decode_job *job = context;
    struct renderer *r = job->renderer;
    struct rect *rect = &job->rects[index];
    const uint8_t *src = job->body + rect->offset;

    if (rect->encoding == ENC_RAW || rect->encoding == ENC_LZ4) {
        size_t row_bytes = (size_t)rect->w * 4, raw_count = row_bytes * (size_t)rect->h;
        uint8_t *target = r->mirror + (size_t)rect->y * r->stride + (size_t)rect->x * 4;
        if (rect->encoding == ENC_RAW) {
            if (rect->count != raw_count) { job->failed = true; return; }
            for (int row = 0; row < rect->h; row++) memcpy(target + (size_t)row * r->stride, src + (size_t)row * row_bytes, row_bytes);
        } else if (rect->w == r->width) {
            // Whole rows: straight into place.
            if (apple_lz4_decode(target, raw_count, src, rect->count) != (long)raw_count) job->failed = true;
        } else {
            uint8_t *packed = malloc(raw_count);
            if (!packed || apple_lz4_decode(packed, raw_count, src, rect->count) != (long)raw_count) {
                job->failed = true;
            } else {
                for (int row = 0; row < rect->h; row++) memcpy(target + (size_t)row * r->stride, packed + (size_t)row * row_bytes, row_bytes);
            }
            free(packed);
        }
    } else {
        // w * h pixels at one byte each is exactly the size of their blocks.
        size_t size = (size_t)rect->w * (size_t)rect->h;
        uint8_t *target = r->staging + rect->staging;
        if (rect->encoding == ENC_BC7) {
            if (rect->count != size) { job->failed = true; return; }
            memcpy(target, src, size);
        } else if (apple_lz4_decode(target, size, src, rect->count) != (long)size) {
            job->failed = true;
        }
    }
}

bool renderer_apply(struct renderer *r, const uint8_t *body, size_t count, uint32_t *frame_no) {
    if (count < 8) {
        log_line("frame of %zu bytes is too short", count);
        return false;
    }
    *frame_no = rd32(body);
    size_t rect_count = rd32(body + 4);
    // Each rect has a 13-byte header, so there can't be more than fit.
    if (rect_count > (count - 8) / 13) {
        log_line("frame %u claims %zu rects in %zu bytes", *frame_no, rect_count, count);
        return false;
    }
    struct rect *rects = calloc(rect_count ? rect_count : 1, sizeof *rects);
    if (!rects) return false;
    size_t offset = 8, staging = 0;
    bool any_bc7 = false;
    for (size_t i = 0; i < rect_count; i++) {
        if (offset + 13 > count || body[offset + 8] > ENC_BC7_LZ4) {
            log_line("bad rect header in frame %u", *frame_no);
            free(rects);
            return false;
        }
        struct rect *rect = &rects[i];
        rect->x = rd16(body + offset);
        rect->y = rd16(body + offset + 2);
        rect->w = rd16(body + offset + 4);
        rect->h = rd16(body + offset + 6);
        rect->encoding = body[offset + 8];
        rect->count = rd32(body + offset + 9);
        rect->offset = offset + 13;
        if (rect->x + rect->w > r->width || rect->y + rect->h > r->height || rect->count > count - rect->offset) {
            log_line("bad rect in frame %u", *frame_no);
            free(rects);
            return false;
        }
        if (rect->encoding == ENC_BC7 || rect->encoding == ENC_BC7_LZ4) {
            // The staging buffer holds one screenful of blocks: rects that overlap, or repeat,
            // mustn't run past its end.
            size_t size = (size_t)rect->w * (size_t)rect->h;
            if (!r->supports_bc7 || rect->x % 4 || rect->y % 4 || rect->w % 4 || rect->h % 4 || staging + size > r->staging_size) {
                log_line("unexpected BC7 rect in frame %u", *frame_no);
                free(rects);
                return false;
            }
            rect->staging = staging;
            staging += size;
            any_bc7 = true;
        }
        offset = rect->offset + rect->count;
    }

    struct decode_job job = { r, body, rects, false };
    pool_run((int)rect_count, decode_rect, &job);
    if (job.failed) {
        log_line("couldn't decode frame %u", *frame_no);
        free(rects);
        return false;
    }

    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, r->width);
    glBindTexture(GL_TEXTURE_2D, r->canvas);
    for (size_t i = 0; i < rect_count; i++) {
        struct rect *rect = &rects[i];
        if (rect->encoding != ENC_RAW && rect->encoding != ENC_LZ4) continue;
        if (rect->w == 0 || rect->h == 0) continue;
        glTexSubImage2D(GL_TEXTURE_2D, 0, rect->x, rect->y, rect->w, rect->h, GL_RGBA, GL_UNSIGNED_BYTE,
                        r->mirror + (size_t)rect->y * r->stride + (size_t)rect->x * 4);
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);

    if (any_bc7) {
        glBindTexture(GL_TEXTURE_2D, r->bc7);
        for (size_t i = 0; i < rect_count; i++) {
            struct rect *rect = &rects[i];
            if (rect->encoding != ENC_BC7 && rect->encoding != ENC_BC7_LZ4) continue;
            if (rect->w == 0 || rect->h == 0) continue;
            glCompressedTexSubImage2D(GL_TEXTURE_2D, 0, rect->x, rect->y, rect->w, rect->h, GL_COMPRESSED_RGBA_BPTC_UNORM_EXT,
                                      rect->w * rect->h, r->staging + rect->staging);
        }
        glBindFramebuffer(GL_FRAMEBUFFER, r->canvas_fbo);
        glViewport(0, 0, r->width, r->height);
        glDisable(GL_BLEND);
        glEnable(GL_SCISSOR_TEST);
        glUseProgram(r->expand_program);
        glActiveTexture(GL_TEXTURE0);
        for (size_t i = 0; i < rect_count; i++) {
            struct rect *rect = &rects[i];
            if (rect->encoding != ENC_BC7 && rect->encoding != ENC_BC7_LZ4) continue;
            if (rect->w == 0 || rect->h == 0) continue;
            glScissor(rect->x, rect->y, rect->w, rect->h);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        glDisable(GL_SCISSOR_TEST);
    }
    free(rects);
    return true;
}

// ---- The pointer ------------------------------------------------------------------------------

void renderer_set_cursor_shape(struct renderer *r, int width, int height, int hot_x, int hot_y, const uint8_t *bgra) {
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glBindTexture(GL_TEXTURE_2D, r->cursor);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, bgra);
    r->cursor_w = width;
    r->cursor_h = height;
    r->hot_x = hot_x;
    r->hot_y = hot_y;
    r->cursor_has_shape = true;
}

void renderer_set_cursor(struct renderer *r, int x, int y, bool visible) {
    r->cursor_x = x;
    r->cursor_y = y;
    r->cursor_visible = visible;
}

void renderer_reset_cursor(struct renderer *r) {
    r->cursor_has_shape = false;
    r->cursor_visible = false;
}

// ---- The waiting screen -----------------------------------------------------------------------

void renderer_set_splash(struct renderer *r, const char *title, const char *detail, const char *footer, bool show_log) {
    if (strcmp(r->title, title) == 0 && strcmp(r->detail, detail) == 0 && strcmp(r->footer, footer) == 0 &&
        r->show_log == show_log && (!show_log || r->log_seen == log_generation())) {
        return;
    }
    snprintf(r->title, sizeof r->title, "%s", title);
    snprintf(r->detail, sizeof r->detail, "%s", detail);
    snprintf(r->footer, sizeof r->footer, "%s", footer);
    r->show_log = show_log;
    r->splash_dirty = true;
}

static void draw_splash(struct renderer *r) {
    char lines[10][160];
    int count = r->show_log ? log_recent(lines, 10) : 0;
    if (r->show_log) r->log_seen = log_generation();
    splash_draw(r->splash_pixels, r->splash_w, r->splash_h, r->title, r->detail, r->footer, lines, count, false, &r->dots);
}

double renderer_animation_interval(struct renderer *r) { return r->software ? 0.25 : 1.0 / 30; }

// ---- Showing it -------------------------------------------------------------------------------

bool renderer_present(struct renderer *r, int what) {
    struct output *output = r->output;
    if (what == SHOW_SPLASH && r->show_log && r->log_seen != log_generation()) r->splash_dirty = true;
    if (what == SHOW_SPLASH && r->splash_dirty) {
        draw_splash(r);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glBindTexture(GL_TEXTURE_2D, r->splash);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, r->splash_w, r->splash_h, GL_RGBA, GL_UNSIGNED_BYTE, r->splash_pixels);
        r->splash_dirty = false;
    }

    output->begin(output);
    glViewport(0, 0, r->width, r->height);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glActiveTexture(GL_TEXTURE0);

    if (what == SHOW_BLACK) {
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
    } else if (what == SHOW_SPLASH) {
        glUseProgram(r->splash_program);
        glUniform2f(r->splash_size, (float)r->width, (float)r->height);
        float scale = (float)r->width / (float)r->splash_w;
        glUniform4f(r->splash_dots, r->dots.x * scale, r->dots.y * scale, r->dots.radius * scale, r->dots.spacing * scale);
        glUniform1f(r->splash_time, (float)(now_seconds() - r->started));
        glBindTexture(GL_TEXTURE_2D, r->splash);
        glDrawArrays(GL_TRIANGLES, 0, 3);
    } else {
        glUseProgram(r->present_program);
        // Sent row by row; OpenGL wants columns.
        float columns[9];
        for (int row = 0; row < 3; row++) {
            for (int column = 0; column < 3; column++) columns[column * 3 + row] = r->matrix[row * 3 + column];
        }
        glUniformMatrix3fv(r->present_matrix, 1, GL_FALSE, columns);
        glUniform1i(r->present_use_matrix, r->use_matrix ? 1 : 0);
        glUniform1i(r->present_height, r->height);
        glBindTexture(GL_TEXTURE_2D, r->canvas);
        glDrawArrays(GL_TRIANGLES, 0, 3);

        if (r->cursor_visible && r->cursor_has_shape) {
            float left = (float)(r->cursor_x - r->hot_x), top = (float)(r->cursor_y - r->hot_y);
            float w = (float)r->width, h = (float)r->height;
            glUseProgram(r->cursor_program);
            glUniform4f(r->cursor_rect, left / w * 2 - 1, 1 - top / h * 2,
                        (left + (float)r->cursor_w) / w * 2 - 1, 1 - (top + (float)r->cursor_h) / h * 2);
            glBindTexture(GL_TEXTURE_2D, r->cursor);
            glEnable(GL_BLEND);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            glDisable(GL_BLEND);
        }
    }
    return output->end(output);
}

// ---- Checking ---------------------------------------------------------------------------------

/// Tandem's imageHash: FNV-1a over a BGRA image, eight bytes at a time.
static uint64_t image_hash(const uint8_t *base, int width, int height, size_t stride) {
    uint64_t h = 0xcbf29ce484222325ull;
    size_t words = (size_t)width * 4 / 8;
    for (int y = 0; y < height; y++) {
        const uint8_t *row = base + (size_t)y * stride;
        for (size_t i = 0; i < words; i++) {
            uint64_t word;
            memcpy(&word, row + i * 8, 8);
            h = (h ^ word) * 0x100000001b3ull;
        }
    }
    return h;
}

static const uint8_t *read_canvas(struct renderer *r) {
    if (!r->readback) r->readback = malloc(r->stride * (size_t)r->height);
    if (!r->readback) return NULL;
    glBindFramebuffer(GL_READ_FRAMEBUFFER, r->canvas_fbo);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, r->width, r->height, GL_RGBA, GL_UNSIGNED_BYTE, r->readback);
    return r->readback;
}

uint64_t renderer_hash(struct renderer *r, bool lossless_only) {
    const uint8_t *pixels = lossless_only ? r->mirror : read_canvas(r);
    return pixels ? image_hash(pixels, r->width, r->height, r->stride) : 0;
}

bool renderer_dump_ppm(struct renderer *r, const char *path) {
    const uint8_t *pixels = read_canvas(r);
    FILE *file = pixels ? fopen(path, "wb") : NULL;
    if (!file) return false;
    fprintf(file, "P6\n%d %d\n255\n", r->width, r->height);
    uint8_t *row = malloc((size_t)r->width * 3);
    for (int y = 0; row && y < r->height; y++) {
        const uint8_t *src = pixels + (size_t)y * r->stride;
        for (int x = 0; x < r->width; x++) {
            row[x * 3] = src[x * 4 + 2];
            row[x * 3 + 1] = src[x * 4 + 1];
            row[x * 3 + 2] = src[x * 4];
        }
        fwrite(row, 3, (size_t)r->width, file);
    }
    free(row);
    fclose(file);
    return true;
}
