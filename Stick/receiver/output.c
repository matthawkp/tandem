// Where the picture goes: the panel, through the kernel's modesetting (KMS), or nowhere at all,
// for testing on a machine with no screen.
//
// A 5K iMac's panel is two 2560x2880 halves on two DisplayPort links, which Linux shows as two
// connectors that say they're tiles of one display. Both scan out of one framebuffer, the left
// half and the right, and every frame changes both in a single atomic commit so they flip
// together: there's no seam, and nothing tears down the middle.
#define _GNU_SOURCE
#include "tandem.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#ifndef EGL_PLATFORM_GBM_KHR
#define EGL_PLATFORM_GBM_KHR 0x31D7
#endif
#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif

static EGLContext make_context(EGLDisplay display, EGLConfig config) {
    static const EGLint attributes[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE };
    return eglCreateContext(display, config, EGL_NO_CONTEXT, attributes);
}

// ---- No screen --------------------------------------------------------------------------------

struct headless {
    struct output base;
    EGLDisplay display;
    EGLContext context;
    GLuint texture, fbo;
};

static void headless_begin(struct output *output) {
    struct headless *h = (struct headless *)output;
    eglMakeCurrent(h->display, EGL_NO_SURFACE, EGL_NO_SURFACE, h->context);
    glBindFramebuffer(GL_FRAMEBUFFER, h->fbo);
}

static bool headless_end(struct output *output) {
    (void)output;
    glFlush();
    return false;
}

static int no_event_fd(struct output *output) { (void)output; return -1; }
static bool no_events(struct output *output) { (void)output; return true; }
static void no_power(struct output *output, bool on) { (void)output; (void)on; }

struct output *headless_open(int width, int height) {
    struct headless *h = calloc(1, sizeof *h);
    h->display = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (h->display == EGL_NO_DISPLAY || !eglInitialize(h->display, NULL, NULL)) {
        log_line("no EGL without a screen (error 0x%x)", eglGetError());
        return NULL;
    }
    eglBindAPI(EGL_OPENGL_ES_API);
    static const EGLint wanted[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                                     EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE };
    EGLConfig config;
    EGLint count = 0;
    if (!eglChooseConfig(h->display, wanted, &config, 1, &count) || count < 1) {
        log_line("no EGL config (error 0x%x)", eglGetError());
        return NULL;
    }
    h->context = make_context(h->display, config);
    if (h->context == EGL_NO_CONTEXT || !eglMakeCurrent(h->display, EGL_NO_SURFACE, EGL_NO_SURFACE, h->context)) {
        log_line("no OpenGL ES 3 context (error 0x%x)", eglGetError());
        return NULL;
    }
    glGenTextures(1, &h->texture);
    glBindTexture(GL_TEXTURE_2D, h->texture);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, width, height);
    glGenFramebuffers(1, &h->fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, h->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, h->texture, 0);

    h->base.width = width;
    h->base.height = height;
    snprintf(h->base.description, sizeof h->base.description, "no screen (testing), %dx%d", width, height);
    h->base.begin = headless_begin;
    h->base.end = headless_end;
    h->base.event_fd = no_event_fd;
    h->base.handle_events = no_events;
    h->base.set_power = no_power;
    return &h->base;
}

// ---- The panel --------------------------------------------------------------------------------

#define MAX_TILES 4

struct tile {
    uint32_t connector, crtc, plane;
    uint32_t fb_property; // the plane's FB_ID, used on every frame
    int crtc_index;
    drmModeModeInfo mode;
    uint32_t mode_blob;
    int x, y; // where this tile's corner is in the whole picture
    char name[32];
};

/// What a connector says about itself.
struct candidate {
    uint32_t id;
    uint32_t type;
    char name[32];
    drmModeModeInfo modes[64];
    int mode_count;
    int mm_wide, mm_high;
    uint32_t current_crtc;
    uint32_t possible_crtcs;
    // From its TILE property, if it has one.
    bool tiled;
    int group, across, down, column, row, tile_w, tile_h;
};

struct kms {
    struct output base;
    int fd;
    struct gbm_device *gbm;
    struct gbm_surface *surface;
    EGLDisplay display;
    EGLContext context;
    EGLSurface egl_surface;
    struct tile tiles[MAX_TILES];
    int tile_count;
    struct gbm_bo *showing, *pending;
    int flips_awaited;
    bool mode_set;
    bool powered;
    drmModeRes *resources;
    drmModePlaneRes *planes;
};

static const char *connector_type_name(uint32_t type) {
    switch (type) {
    case DRM_MODE_CONNECTOR_eDP: return "eDP";
    case DRM_MODE_CONNECTOR_DisplayPort: return "DP";
    case DRM_MODE_CONNECTOR_HDMIA: return "HDMI-A";
    case DRM_MODE_CONNECTOR_HDMIB: return "HDMI-B";
    case DRM_MODE_CONNECTOR_LVDS: return "LVDS";
    case DRM_MODE_CONNECTOR_VGA: return "VGA";
    case DRM_MODE_CONNECTOR_DVID: return "DVI-D";
    case DRM_MODE_CONNECTOR_DVII: return "DVI-I";
    case DRM_MODE_CONNECTOR_VIRTUAL: return "Virtual";
    default: return "Connector";
    }
}

static uint32_t property_id(int fd, uint32_t object, uint32_t object_type, const char *name, uint64_t *value) {
    drmModeObjectProperties *properties = drmModeObjectGetProperties(fd, object, object_type);
    if (!properties) return 0;
    uint32_t found = 0;
    for (uint32_t i = 0; i < properties->count_props && !found; i++) {
        drmModePropertyRes *property = drmModeGetProperty(fd, properties->props[i]);
        if (!property) continue;
        if (strcmp(property->name, name) == 0) {
            found = property->prop_id;
            if (value) *value = properties->prop_values[i];
        }
        drmModeFreeProperty(property);
    }
    drmModeFreeObjectProperties(properties);
    return found;
}

static bool add(drmModeAtomicReq *request, int fd, uint32_t object, uint32_t object_type, const char *name, uint64_t value) {
    uint32_t id = property_id(fd, object, object_type, name, NULL);
    if (!id) {
        log_line("screen: object %u has no %s property", object, name);
        return false;
    }
    return drmModeAtomicAddProperty(request, object, id, value) >= 0;
}

static double refresh_of(const drmModeModeInfo *mode) {
    if (mode->htotal == 0 || mode->vtotal == 0) return 0;
    return (double)mode->clock * 1000.0 / ((double)mode->htotal * (double)mode->vtotal);
}

static void read_candidate(int fd, drmModeConnector *connector, struct candidate *c) {
    memset(c, 0, sizeof *c);
    c->id = connector->connector_id;
    c->type = connector->connector_type;
    snprintf(c->name, sizeof c->name, "%s-%u", connector_type_name(connector->connector_type), connector->connector_type_id);
    c->mode_count = connector->count_modes > 64 ? 64 : connector->count_modes;
    memcpy(c->modes, connector->modes, (size_t)c->mode_count * sizeof c->modes[0]);
    c->mm_wide = (int)connector->mmWidth;
    c->mm_high = (int)connector->mmHeight;
    for (int i = 0; i < connector->count_encoders; i++) {
        drmModeEncoder *encoder = drmModeGetEncoder(fd, connector->encoders[i]);
        if (!encoder) continue;
        c->possible_crtcs |= encoder->possible_crtcs;
        if (encoder->encoder_id == connector->encoder_id) c->current_crtc = encoder->crtc_id;
        drmModeFreeEncoder(encoder);
    }
    uint64_t blob_id = 0;
    if (property_id(fd, c->id, DRM_MODE_OBJECT_CONNECTOR, "TILE", &blob_id) && blob_id) {
        drmModePropertyBlobRes *blob = drmModeGetPropertyBlob(fd, (uint32_t)blob_id);
        if (blob) {
            // "group:single monitor:tiles across:tiles down:column:row:tile width:tile height"
            char text[128] = "";
            size_t length = blob->length < sizeof text - 1 ? blob->length : sizeof text - 1;
            memcpy(text, blob->data, length);
            int single = 0;
            if (sscanf(text, "%d:%d:%d:%d:%d:%d:%d:%d", &c->group, &single, &c->across, &c->down,
                       &c->column, &c->row, &c->tile_w, &c->tile_h) == 8 && c->across * c->down > 1) {
                c->tiled = true;
            }
            drmModeFreePropertyBlob(blob);
        }
    }
}

/// The mode to use on a connector: the size asked for, or the one it prefers, at its fastest.
static const drmModeModeInfo *pick_mode(const struct candidate *c, int width, int height) {
    const drmModeModeInfo *best = NULL;
    for (int i = 0; i < c->mode_count; i++) {
        const drmModeModeInfo *mode = &c->modes[i];
        if (mode->flags & DRM_MODE_FLAG_INTERLACE) continue;
        if (width && (mode->hdisplay != width || mode->vdisplay != height)) continue;
        if (!width && !(mode->type & DRM_MODE_TYPE_PREFERRED)) continue;
        if (!best || refresh_of(mode) > refresh_of(best) + 0.5) best = mode;
    }
    if (!best && !width) {
        // Nothing preferred: the largest.
        for (int i = 0; i < c->mode_count; i++) {
            const drmModeModeInfo *mode = &c->modes[i];
            if (mode->flags & DRM_MODE_FLAG_INTERLACE) continue;
            if (!best || mode->hdisplay * mode->vdisplay > best->hdisplay * best->vdisplay) best = mode;
        }
    }
    return best;
}

static bool crtc_for(struct kms *k, const struct candidate *c, uint32_t taken, uint32_t *crtc, int *index) {
    // The one it's already on, if it's free: less to change.
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < k->resources->count_crtcs; i++) {
            if (!(c->possible_crtcs & (1u << i)) || (taken & (1u << i))) continue;
            if (pass == 0 && k->resources->crtcs[i] != c->current_crtc) continue;
            *crtc = k->resources->crtcs[i];
            *index = i;
            return true;
        }
    }
    return false;
}

static uint32_t primary_plane_for(struct kms *k, int crtc_index, const uint32_t *taken, int taken_count) {
    for (uint32_t i = 0; i < k->planes->count_planes; i++) {
        drmModePlane *plane = drmModeGetPlane(k->fd, k->planes->planes[i]);
        if (!plane) continue;
        uint32_t id = plane->plane_id, possible = plane->possible_crtcs;
        drmModeFreePlane(plane);
        if (!(possible & (1u << crtc_index))) continue;
        uint64_t type = 0;
        if (!property_id(k->fd, id, DRM_MODE_OBJECT_PLANE, "type", &type) || type != DRM_PLANE_TYPE_PRIMARY) continue;
        bool used = false;
        for (int t = 0; t < taken_count; t++) used |= taken[t] == id;
        if (!used) return id;
    }
    return 0;
}

/// Chooses what to show on: all the tiles of a tiled panel, or else one connector. Fills in
/// k->tiles and the picture's size.
static bool choose_screen(struct kms *k, const struct kms_options *options) {
    struct candidate *all = calloc((size_t)k->resources->count_connectors + 1, sizeof *all);
    int count = 0;
    for (int i = 0; i < k->resources->count_connectors; i++) {
        drmModeConnector *connector = drmModeGetConnector(k->fd, k->resources->connectors[i]);
        if (!connector) continue;
        struct candidate c;
        read_candidate(k->fd, connector, &c);
        bool connected = connector->connection == DRM_MODE_CONNECTED && c.mode_count > 0;
        const drmModeModeInfo *preferred = connected ? pick_mode(&c, 0, 0) : NULL;
        if (c.tiled) {
            log_line("screen: %s %s, %d modes, prefers %dx%d, %dx%d mm, tile %d,%d of %dx%d (%dx%d each, group %d)", c.name,
                     connected ? "connected" : "not connected", c.mode_count, preferred ? preferred->hdisplay : 0,
                     preferred ? preferred->vdisplay : 0, c.mm_wide, c.mm_high, c.column, c.row, c.across, c.down,
                     c.tile_w, c.tile_h, c.group);
        } else {
            log_line("screen: %s %s, %d modes, prefers %dx%d, %dx%d mm", c.name, connected ? "connected" : "not connected",
                     c.mode_count, preferred ? preferred->hdisplay : 0, preferred ? preferred->vdisplay : 0, c.mm_wide, c.mm_high);
        }
        for (int m = 0; connected && m < c.mode_count && m < 12; m++) {
            log_line("screen:   %dx%d at %.2f Hz%s", c.modes[m].hdisplay, c.modes[m].vdisplay, refresh_of(&c.modes[m]),
                     c.modes[m].type & DRM_MODE_TYPE_PREFERRED ? " (preferred)" : "");
        }
        drmModeFreeConnector(connector);
        if (connected) all[count++] = c;
    }
    if (count == 0) {
        log_line("screen: nothing is connected");
        free(all);
        return false;
    }

    // A whole tiled panel, unless one size was asked for.
    const struct candidate *members[MAX_TILES] = { 0 };
    int member_count = 0;
    if (!options->mode_width) {
        for (int i = 0; i < count && member_count == 0; i++) {
            if (!all[i].tiled || all[i].across * all[i].down > MAX_TILES) continue;
            int wanted = all[i].across * all[i].down, found = 0;
            const struct candidate *group[MAX_TILES] = { 0 };
            for (int j = 0; j < count; j++) {
                if (!all[j].tiled || all[j].group != all[i].group) continue;
                int slot = all[j].row * all[i].across + all[j].column;
                if (slot < 0 || slot >= wanted || group[slot]) continue;
                group[slot] = &all[j];
                found++;
            }
            if (found == wanted) {
                memcpy(members, group, sizeof group);
                member_count = wanted;
            } else {
                log_line("screen: only %d of the panel's %d tiles are connected", found, wanted);
            }
        }
        // Two halves that don't say they're tiles: an internal panel and one other connector,
        // each taller than it's wide. The internal one is the left half.
        if (member_count == 0 && count == 2) {
            const drmModeModeInfo *a = pick_mode(&all[0], 0, 0), *b = pick_mode(&all[1], 0, 0);
            bool internal = all[0].type == DRM_MODE_CONNECTOR_eDP || all[1].type == DRM_MODE_CONNECTOR_eDP;
            if (internal && a && b && a->hdisplay == b->hdisplay && a->vdisplay == b->vdisplay && a->vdisplay > a->hdisplay) {
                int left = all[0].type == DRM_MODE_CONNECTOR_eDP ? 0 : 1;
                members[0] = &all[left];
                members[1] = &all[1 - left];
                member_count = 2;
                all[0].across = all[1].across = 2;
                all[0].down = all[1].down = 1;
                all[0].tile_w = all[1].tile_w = a->hdisplay;
                all[0].tile_h = all[1].tile_h = a->vdisplay;
                log_line("screen: taking %s and %s as the two halves of one panel", members[0]->name, members[1]->name);
            }
        }
    }

    uint32_t taken_crtcs = 0, taken_planes[MAX_TILES];
    k->tile_count = 0;
    if (member_count > 1) {
        int across = members[0]->across, tile_w = members[0]->tile_w, tile_h = members[0]->tile_h;
        if (options->swap_tiles && member_count == 2) {
            const struct candidate *swap = members[0];
            members[0] = members[1];
            members[1] = swap;
        }
        const drmModeModeInfo *first = NULL;
        for (int i = 0; i < member_count; i++) {
            const drmModeModeInfo *mode = pick_mode(members[i], tile_w, tile_h);
            if (!mode) mode = pick_mode(members[i], 0, 0);
            if (!mode) break;
            if (!first) first = mode;
            struct tile *tile = &k->tiles[k->tile_count];
            snprintf(tile->name, sizeof tile->name, "%s", members[i]->name);
            tile->connector = members[i]->id;
            tile->mode = *mode;
            tile->x = (i % across) * mode->hdisplay;
            tile->y = (i / across) * mode->vdisplay;
            if (!crtc_for(k, members[i], taken_crtcs, &tile->crtc, &tile->crtc_index)) break;
            taken_crtcs |= 1u << tile->crtc_index;
            tile->plane = primary_plane_for(k, tile->crtc_index, taken_planes, k->tile_count);
            if (!tile->plane) break;
            taken_planes[k->tile_count++] = tile->plane;
        }
        if (k->tile_count == member_count && first) {
            k->base.width = across * first->hdisplay;
            k->base.height = (member_count / across) * first->vdisplay;
            // Each tile's EDID may give the size of the whole panel or of its own part. Either
            // way its height is right for one row, and the pixels are square.
            int mm_high = members[0]->mm_high * (member_count / across);
            k->base.mm_high = mm_high;
            k->base.mm_wide = mm_high > 0 ? (double)mm_high * k->base.width / k->base.height : 0;
            snprintf(k->base.description, sizeof k->base.description, "%dx%d in %d tiles of %dx%d at %.0f Hz",
                     k->base.width, k->base.height, member_count, first->hdisplay, first->vdisplay, refresh_of(first));
            free(all);
            return true;
        }
        log_line("screen: couldn't drive every tile, falling back to one connector");
        k->tile_count = 0;
        taken_crtcs = 0;
    }

    // One connector: the built-in panel if there is one.
    const struct candidate *chosen = NULL;
    for (int i = 0; i < count; i++) {
        if (options->mode_width && !pick_mode(&all[i], options->mode_width, options->mode_height)) continue;
        bool internal = all[i].type == DRM_MODE_CONNECTOR_eDP || all[i].type == DRM_MODE_CONNECTOR_LVDS;
        if (!chosen || (internal && chosen->type != DRM_MODE_CONNECTOR_eDP && chosen->type != DRM_MODE_CONNECTOR_LVDS)) chosen = &all[i];
    }
    if (!chosen) {
        log_line("screen: nothing connected offers %dx%d", options->mode_width, options->mode_height);
        free(all);
        return false;
    }
    const drmModeModeInfo *mode = pick_mode(chosen, options->mode_width, options->mode_height);
    if (!options->mode_width && chosen->tiled && mode->vdisplay > mode->hdisplay) {
        // Half of a tiled panel, without its other half. A mode that's wider than tall, if the
        // panel offers one, is the whole panel scaled; its preferred mode is the half alone.
        for (int i = 0; i < chosen->mode_count; i++) {
            const drmModeModeInfo *other = &chosen->modes[i];
            if (other->flags & DRM_MODE_FLAG_INTERLACE || other->hdisplay <= other->vdisplay) continue;
            if (mode->vdisplay > mode->hdisplay || other->hdisplay * other->vdisplay > mode->hdisplay * mode->vdisplay) mode = other;
        }
    }
    struct tile *tile = &k->tiles[0];
    snprintf(tile->name, sizeof tile->name, "%s", chosen->name);
    tile->connector = chosen->id;
    tile->mode = *mode;
    bool ok = crtc_for(k, chosen, 0, &tile->crtc, &tile->crtc_index);
    if (ok) tile->plane = primary_plane_for(k, tile->crtc_index, NULL, 0);
    if (!ok || !tile->plane) {
        log_line("screen: no CRTC or plane for %s", chosen->name);
        free(all);
        return false;
    }
    k->tile_count = 1;
    k->base.width = mode->hdisplay;
    k->base.height = mode->vdisplay;
    k->base.mm_wide = chosen->mm_wide;
    k->base.mm_high = chosen->mm_high;
    snprintf(k->base.description, sizeof k->base.description, "%dx%d at %.0f Hz on %s", mode->hdisplay, mode->vdisplay,
             refresh_of(mode), chosen->name);
    free(all);
    return true;
}

static void destroy_fb(struct gbm_bo *bo, void *data) {
    uint32_t fb = (uint32_t)(uintptr_t)data;
    if (fb) drmModeRmFB(gbm_device_get_fd(gbm_bo_get_device(bo)), fb);
}

static uint32_t fb_for(struct kms *k, struct gbm_bo *bo) {
    uint32_t fb = (uint32_t)(uintptr_t)gbm_bo_get_user_data(bo);
    if (fb) return fb;
    uint32_t width = gbm_bo_get_width(bo), height = gbm_bo_get_height(bo), format = gbm_bo_get_format(bo);
    uint32_t handles[4] = { 0 }, strides[4] = { 0 }, offsets[4] = { 0 };
    uint64_t modifiers[4] = { 0 };
    int planes = gbm_bo_get_plane_count(bo);
    uint64_t modifier = gbm_bo_get_modifier(bo);
    for (int i = 0; i < planes && i < 4; i++) {
        handles[i] = gbm_bo_get_handle_for_plane(bo, i).u32;
        strides[i] = gbm_bo_get_stride_for_plane(bo, i);
        offsets[i] = gbm_bo_get_offset(bo, i);
        modifiers[i] = modifier;
    }
    int result = -1;
    if (modifier != DRM_FORMAT_MOD_INVALID && modifier != DRM_FORMAT_MOD_LINEAR) {
        result = drmModeAddFB2WithModifiers(k->fd, width, height, format, handles, strides, offsets, modifiers, &fb, DRM_MODE_FB_MODIFIERS);
    }
    if (result != 0) {
        handles[0] = gbm_bo_get_handle(bo).u32;
        strides[0] = gbm_bo_get_stride(bo);
        memset(handles + 1, 0, sizeof handles - sizeof handles[0]);
        memset(strides + 1, 0, sizeof strides - sizeof strides[0]);
        memset(offsets, 0, sizeof offsets);
        result = drmModeAddFB2(k->fd, width, height, format, handles, strides, offsets, &fb, 0);
    }
    if (result != 0) {
        log_line("screen: couldn't make a framebuffer: %s", strerror(errno));
        return 0;
    }
    gbm_bo_set_user_data(bo, (void *)(uintptr_t)fb, destroy_fb);
    return fb;
}

/// The first commit: every connector, CRTC and plane is given a state, ours or off, so nothing
/// the console left behind stays in the way.
static bool set_mode(struct kms *k, uint32_t fb, bool active) {
    drmModeAtomicReq *request = drmModeAtomicAlloc();
    bool ok = request != NULL;
    for (int i = 0; ok && i < k->resources->count_connectors; i++) {
        uint32_t connector = k->resources->connectors[i], crtc = 0;
        for (int t = 0; t < k->tile_count; t++) {
            if (k->tiles[t].connector == connector) crtc = k->tiles[t].crtc;
        }
        ok = add(request, k->fd, connector, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", crtc);
    }
    for (int i = 0; ok && i < k->resources->count_crtcs; i++) {
        uint32_t crtc = k->resources->crtcs[i], blob = 0;
        for (int t = 0; t < k->tile_count; t++) {
            if (k->tiles[t].crtc == crtc) blob = k->tiles[t].mode_blob;
        }
        ok = add(request, k->fd, crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID", blob) &&
             add(request, k->fd, crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", blob && active ? 1 : 0);
    }
    for (uint32_t i = 0; ok && i < k->planes->count_planes; i++) {
        uint32_t plane = k->planes->planes[i];
        const struct tile *tile = NULL;
        for (int t = 0; t < k->tile_count; t++) {
            if (k->tiles[t].plane == plane) tile = &k->tiles[t];
        }
        ok = add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "FB_ID", tile ? fb : 0) &&
             add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "CRTC_ID", tile ? tile->crtc : 0);
        if (ok && tile) {
            ok = add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "SRC_X", (uint64_t)tile->x << 16) &&
                 add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "SRC_Y", (uint64_t)tile->y << 16) &&
                 add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "SRC_W", (uint64_t)tile->mode.hdisplay << 16) &&
                 add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "SRC_H", (uint64_t)tile->mode.vdisplay << 16) &&
                 add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "CRTC_X", 0) &&
                 add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "CRTC_Y", 0) &&
                 add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "CRTC_W", tile->mode.hdisplay) &&
                 add(request, k->fd, plane, DRM_MODE_OBJECT_PLANE, "CRTC_H", tile->mode.vdisplay);
        }
    }
    if (ok && drmModeAtomicCommit(k->fd, request, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL) != 0) {
        log_line("screen: couldn't set the mode: %s", strerror(errno));
        ok = false;
    }
    if (request) drmModeAtomicFree(request);
    return ok;
}

static void kms_begin(struct output *output) {
    struct kms *k = (struct kms *)output;
    eglMakeCurrent(k->display, k->egl_surface, k->egl_surface, k->context);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

static bool kms_end(struct output *output) {
    struct kms *k = (struct kms *)output;
    if (!eglSwapBuffers(k->display, k->egl_surface)) {
        log_line("screen: couldn't swap buffers (error 0x%x)", eglGetError());
        return false;
    }
    struct gbm_bo *bo = gbm_surface_lock_front_buffer(k->surface);
    uint32_t fb = bo ? fb_for(k, bo) : 0;
    if (!fb) {
        if (bo) gbm_surface_release_buffer(k->surface, bo);
        return false;
    }

    if (!k->mode_set) {
        if (!set_mode(k, fb, true)) {
            gbm_surface_release_buffer(k->surface, bo);
            return false;
        }
        k->mode_set = true;
        k->powered = true;
        if (k->showing) gbm_surface_release_buffer(k->surface, k->showing);
        k->showing = bo;
        log_line("screen: showing %s", k->base.description);
        return false;
    }

    // Every tile in one commit, so they change on the same refresh.
    drmModeAtomicReq *request = drmModeAtomicAlloc();
    bool ok = request != NULL;
    for (int t = 0; ok && t < k->tile_count; t++) {
        ok = drmModeAtomicAddProperty(request, k->tiles[t].plane, k->tiles[t].fb_property, fb) >= 0;
    }
    int result = ok ? drmModeAtomicCommit(k->fd, request, DRM_MODE_PAGE_FLIP_EVENT | DRM_MODE_ATOMIC_NONBLOCK, k) : -1;
    if (request) drmModeAtomicFree(request);
    if (result != 0) {
        // EBUSY: the last flip hasn't finished. Anything else is a real problem, said once in a while.
        static double last_said;
        if (errno != EBUSY && now_seconds() - last_said > 5) {
            last_said = now_seconds();
            log_line("screen: couldn't flip: %s", strerror(errno));
        }
        gbm_surface_release_buffer(k->surface, bo);
        return false;
    }
    k->pending = bo;
    k->flips_awaited = k->tile_count;
    return true;
}

static void flipped(int fd, unsigned sequence, unsigned seconds, unsigned microseconds, unsigned crtc, void *data) {
    (void)fd; (void)sequence; (void)seconds; (void)microseconds; (void)crtc;
    struct kms *k = data;
    if (k->flips_awaited > 0) k->flips_awaited--;
}

static int kms_event_fd(struct output *output) { return ((struct kms *)output)->fd; }

static bool kms_handle_events(struct output *output) {
    struct kms *k = (struct kms *)output;
    drmEventContext context = { .version = 3, .page_flip_handler2 = flipped };
    drmHandleEvent(k->fd, &context);
    if (k->flips_awaited > 0 || !k->pending) return false;
    if (k->showing) gbm_surface_release_buffer(k->surface, k->showing);
    k->showing = k->pending;
    k->pending = NULL;
    return true;
}

static void kms_set_power(struct output *output, bool on) {
    struct kms *k = (struct kms *)output;
    if (!k->mode_set || on == k->powered) return;
    drmModeAtomicReq *request = drmModeAtomicAlloc();
    bool ok = request != NULL;
    for (int t = 0; ok && t < k->tile_count; t++) {
        ok = add(request, k->fd, k->tiles[t].crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", on ? 1 : 0);
    }
    if (ok && drmModeAtomicCommit(k->fd, request, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL) == 0) {
        k->powered = on;
        log_line("screen: panel %s", on ? "on" : "off");
    } else {
        log_line("screen: couldn't turn the panel %s: %s", on ? "on" : "off", strerror(errno));
    }
    if (request) drmModeAtomicFree(request);
}

static int open_card(const char *wanted, bool allow_basic) {
    for (int i = 0; i < 8; i++) {
        char path[64];
        if (wanted) snprintf(path, sizeof path, "%s", wanted);
        else snprintf(path, sizeof path, "/dev/dri/card%d", i);
        int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            drmModeRes *resources = drmModeGetResources(fd);
            bool usable = resources && resources->count_connectors > 0 && resources->count_crtcs > 0;
            if (resources) drmModeFreeResources(resources);
            if (usable) {
                drmVersion *version = drmGetVersion(fd);
                log_line("screen: %s, driver %s", path, version ? version->name : "?");
                // The firmware's own framebuffer can't flip or draw: wait for the real driver.
                bool basic = version && (strcmp(version->name, "efidrm") == 0 || strcmp(version->name, "simpledrm") == 0 ||
                                         strcmp(version->name, "vesadrm") == 0);
                if (version) drmFreeVersion(version);
                if (!basic || allow_basic) return fd;
            }
            close(fd);
        }
        if (wanted) break;
    }
    return -1;
}

struct output *kms_open(const struct kms_options *options) {
    struct kms *k = calloc(1, sizeof *k);
    double deadline = now_seconds() + options->wait_seconds;
    bool said = false;
    while ((k->fd = open_card(options->card, options->allow_basic)) < 0) {
        if (now_seconds() > deadline) {
            log_line("screen: no graphics driver after %d s", options->wait_seconds);
            return NULL;
        }
        if (!said) log_line("screen: waiting for the graphics driver");
        said = true;
        usleep(250000);
    }
    if (drmSetClientCap(k->fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) != 0 || drmSetClientCap(k->fd, DRM_CLIENT_CAP_ATOMIC, 1) != 0) {
        log_line("screen: this driver has no atomic modesetting");
        return NULL;
    }
    k->resources = drmModeGetResources(k->fd);
    k->planes = drmModeGetPlaneResources(k->fd);
    if (!k->resources || !k->planes) return NULL;

    // A panel's second half can take a moment longer to answer than its first.
    bool chosen = false;
    for (int attempt = 0; attempt < 12 && !chosen; attempt++) {
        if (attempt > 0) usleep(500000);
        chosen = choose_screen(k, options);
        bool waiting_for_half = chosen && k->tile_count == 1 && k->tiles[0].mode.vdisplay > k->tiles[0].mode.hdisplay && !options->mode_width;
        if (waiting_for_half && attempt < 11) {
            log_line("screen: only half a panel so far (%dx%d), looking again", k->tiles[0].mode.hdisplay, k->tiles[0].mode.vdisplay);
            chosen = false;
        }
    }
    if (!chosen) return NULL;
    for (int t = 0; t < k->tile_count; t++) {
        struct tile *tile = &k->tiles[t];
        if (drmModeCreatePropertyBlob(k->fd, &tile->mode, sizeof tile->mode, &tile->mode_blob) != 0) return NULL;
        tile->fb_property = property_id(k->fd, tile->plane, DRM_MODE_OBJECT_PLANE, "FB_ID", NULL);
        if (!tile->fb_property) return NULL;
        log_line("screen: %s on CRTC %u, plane %u, showing the picture from %d,%d", tile->name, tile->crtc, tile->plane, tile->x, tile->y);
    }

    k->gbm = gbm_create_device(k->fd);
    if (!k->gbm) {
        log_line("screen: no GBM device");
        return NULL;
    }
    k->surface = gbm_surface_create(k->gbm, (uint32_t)k->base.width, (uint32_t)k->base.height, GBM_FORMAT_XRGB8888,
                                    GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
    if (!k->surface) {
        log_line("screen: no GBM surface of %dx%d", k->base.width, k->base.height);
        return NULL;
    }
    k->display = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, k->gbm, NULL);
    if (k->display == EGL_NO_DISPLAY || !eglInitialize(k->display, NULL, NULL)) {
        log_line("screen: no EGL (error 0x%x)", eglGetError());
        return NULL;
    }
    eglBindAPI(EGL_OPENGL_ES_API);
    static const EGLint wanted[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                                     EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE };
    EGLConfig configs[128], config = NULL;
    EGLint count = 0;
    eglChooseConfig(k->display, wanted, configs, 128, &count);
    for (EGLint i = 0; i < count && !config; i++) {
        EGLint visual = 0;
        if (eglGetConfigAttrib(k->display, configs[i], EGL_NATIVE_VISUAL_ID, &visual) && (uint32_t)visual == GBM_FORMAT_XRGB8888) config = configs[i];
    }
    if (!config) {
        log_line("screen: no EGL config for the framebuffer's format (%d offered)", count);
        return NULL;
    }
    k->context = make_context(k->display, config);
    k->egl_surface = eglCreatePlatformWindowSurface(k->display, config, k->surface, NULL);
    if (k->context == EGL_NO_CONTEXT || k->egl_surface == EGL_NO_SURFACE ||
        !eglMakeCurrent(k->display, k->egl_surface, k->egl_surface, k->context)) {
        log_line("screen: no OpenGL ES 3 on it (error 0x%x)", eglGetError());
        return NULL;
    }
    // Flips are timed here, by waiting for each to finish.
    eglSwapInterval(k->display, 0);

    k->base.begin = kms_begin;
    k->base.end = kms_end;
    k->base.event_fd = kms_event_fd;
    k->base.handle_events = kms_handle_events;
    k->base.set_power = kms_set_power;
    return &k->base;
}
