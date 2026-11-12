// Tandem Display for Linux: the "display" half of Tandem (the Mac app), for an iMac with no
// working macOS. It speaks the same protocol over the same Thunderbolt cable, so the Mac that
// extends onto it runs the ordinary Tandem app, unchanged.
//
// The protocol is Tandem's Shared/Wire.swift; this is a second implementation of its receiver.
#ifndef TANDEM_H
#define TANDEM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TANDEM_DISPLAY_VERSION "1.0"

// ---- Wire protocol (Shared/Wire.swift) ------------------------------------------------------

// Every message is: u32 body length | u8 kind | body   (little-endian)
enum wire_kind {
    K_HELLO = 1, K_FRAME = 2, K_ACK = 3, K_STATUS = 4, K_PING = 5, K_POWER = 6, K_DISPLAY = 7,
    K_PROBE = 8, K_PROBE_ACK = 9, K_INPUT = 10, K_INPUT_STATE = 11, K_CAMERA_FRAME = 12,
    K_ABOUT = 13, K_CURSOR = 14, K_CURSOR_SHAPE = 15, K_SWAP = 16, K_PEEK = 17, K_SETTINGS = 18,
    K_SETTINGS_CHOICE = 19, K_FILE = 20, K_FEATURES = 21,
};

#define WIRE_VERSION 4
#define WIRE_PORT 51515
#define WIRE_MAX_MESSAGE (512u << 20)
#define WIRE_MAX_DIMENSION 16384

enum { CAP_BC7 = 1, CAP_BRIGHTNESS = 2, CAP_CURSOR = 4, CAP_SWAP = 8, CAP_PEEK = 16, CAP_SETTINGS = 32, CAP_FILES = 64 };
enum { ENC_RAW = 0, ENC_LZ4 = 1, ENC_BC7 = 2, ENC_BC7_LZ4 = 3 };
enum { POWER_SLEEP = 0, POWER_WAKE = 1 };
enum { INPUT_OFF = 0, INPUT_NEEDS_PERMISSION = 1, INPUT_READY = 2 };

static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static inline uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32; }
static inline void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void wr32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
static inline void wr64(uint8_t *p, uint64_t v) { wr32(p, (uint32_t)v); wr32(p + 4, (uint32_t)(v >> 32)); }

// ---- log.c ----------------------------------------------------------------------------------

void log_line(const char *format, ...) __attribute__((format(printf, 1, 2)));
/// The last lines logged, newest last, for the waiting screen. Returns how many were copied.
int log_recent(char lines[][160], int max);
/// Counts up whenever a line is logged.
unsigned log_generation(void);
double now_seconds(void);

// ---- lz4a.c ---------------------------------------------------------------------------------

/// Decodes what Apple's COMPRESSION_LZ4 writes ("bv41" blocks). Returns the decoded size, or -1.
long apple_lz4_decode(uint8_t *dst, size_t capacity, const uint8_t *src, size_t count);

// ---- pool.c ---------------------------------------------------------------------------------

void pool_start(int threads);
/// Calls work(context, i) for every i below count, across the pool and this thread.
void pool_run(int count, void (*work)(void *context, int index), void *context);

// ---- text.c ---------------------------------------------------------------------------------

bool font_load(const char *path);
int font_width(void);
int font_height(void);
/// Draws UTF-8 text into an RGBA picture, each font pixel `scale` across. Returns the width drawn.
int text_draw(uint8_t *rgba, int width, int height, int x, int y, const char *text, int scale, uint32_t color);
int text_width(const char *text, int scale);

// ---- splash.c -------------------------------------------------------------------------------

/// Where the waiting screen's three dots go, in the picture's pixels from its top left.
struct splash_dots { float x, y, radius, spacing; };
/// How bright the dots are while still (0 background, 1 white), and at the dimmest when moving.
#define SPLASH_DOT_REST 0.28f
#define SPLASH_DOT_REST_TEXT "0.28" // the same, for shaders
/// Draws the waiting screen into an RGBA picture: the name, the dots (drawn only if
/// `still_dots`, else just placed in `dots` for whoever moves them), `status`, `detail`, then
/// `footer` along the bottom with `lines` of the log above it.
void splash_draw(uint8_t *rgba, int w, int h, const char *status, const char *detail, const char *footer,
                 char lines[][160], int line_count, bool still_dots, struct splash_dots *dots);
/// The boot menu's picture: the waiting screen saying "Starting", as a TGA file for GRUB.
bool splash_write_boot_picture(const char *path, int w, int h);

// ---- Output: kms.c (a real screen) or headless.c (none, for testing) --------------------------

struct output {
    int width, height;        // pixels of the whole picture
    double mm_wide, mm_high;  // 0 if unknown
    char description[160];
    /// Makes the GL context current and binds what's drawn to.
    void (*begin)(struct output *);
    /// Shows what was drawn. True if `flipped` will follow once it's on screen (then nothing more
    /// may be shown until it has); false if it's already there.
    bool (*end)(struct output *);
    /// File descriptor that becomes readable when a flip finishes, or -1.
    int (*event_fd)(struct output *);
    /// Handles events on that descriptor. True once the last `end` is on screen.
    bool (*handle_events)(struct output *);
    /// Turns the panel off or on, where that's possible.
    void (*set_power)(struct output *, bool on);
};

struct kms_options {
    const char *card;      // "/dev/dri/card0", or NULL for the first with a screen
    int mode_width, mode_height; // 0: the panel's own
    bool swap_tiles;
    int wait_seconds;      // how long to wait for the graphics driver
    bool allow_basic;      // make do with the firmware's framebuffer (drawn by the CPU, slowly)
};
struct output *kms_open(const struct kms_options *options);
struct output *headless_open(int width, int height);

// ---- render.c -------------------------------------------------------------------------------

struct renderer;
struct renderer *renderer_create(struct output *output);
bool renderer_supports_bc7(struct renderer *);
/// Decodes a frame message into the picture. On success returns true and sets *frame_no.
bool renderer_apply(struct renderer *, const uint8_t *body, size_t count, uint32_t *frame_no);
void renderer_clear(struct renderer *);
void renderer_set_matrix(struct renderer *, const float matrix[9]);
void renderer_set_cursor_shape(struct renderer *, int width, int height, int hot_x, int hot_y, const uint8_t *bgra);
void renderer_set_cursor(struct renderer *, int x, int y, bool visible);
void renderer_reset_cursor(struct renderer *);
/// What's shown instead of the picture: a title, a line under it, and optionally the log.
void renderer_set_splash(struct renderer *, const char *title, const char *detail, const char *footer, bool show_log);
/// Seconds between the waiting screen's frames while its dots move: fewer when the processor
/// draws everything.
double renderer_animation_interval(struct renderer *);
/// Draws the picture (or the waiting screen, or black) and hands it to the output.
bool renderer_present(struct renderer *, int what);
enum { SHOW_PICTURE, SHOW_SPLASH, SHOW_BLACK };
/// FNV-1a of the picture as decoded, like Tandem's imageHash, for checking against the sender's.
uint64_t renderer_hash(struct renderer *, bool lossless_only);
bool renderer_dump_ppm(struct renderer *, const char *path);

// ---- net.c ----------------------------------------------------------------------------------

struct net_handlers {
    /// A Mac connected; send the hello. On the network thread, like the others.
    void (*connected)(const char *from);
    /// Takes ownership of `body` (free it), which may be NULL when count is 0.
    void (*message)(uint8_t kind, uint8_t *body, size_t count);
    void (*disconnected)(void);
};
bool net_start(uint16_t port, bool any_interface, const struct net_handlers *handlers);
/// Safe from any thread; false if there's nobody to send to.
bool net_send(uint8_t kind, const void *body, size_t count);
/// Hangs up on the Mac, which then connects again and starts with a whole frame.
void net_drop(void);
/// "connected", "no cable", ...: the state of the Thunderbolt link, for the waiting screen.
void net_link_description(char *out, size_t size);

// ---- input.c --------------------------------------------------------------------------------

struct input_handlers {
    /// Any key, button or movement, forwarded or not.
    void (*activity)(void);
    void (*power_button)(void);
};
void input_start(const struct input_handlers *handlers, double pointer_speed);
/// Whether keys and mouse go to the Mac (there's a picture, and the Mac will act on them).
void input_set_forwarding(bool on);

// ---- backlight.c ----------------------------------------------------------------------------

bool backlight_open(const char *preferred);
/// 0...1, or -1 if unknown.
float backlight_get(void);
void backlight_set(float fraction);
const char *backlight_name(void);

#endif
