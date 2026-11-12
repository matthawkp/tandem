// Tandem Display: Tandem's Receiver/ReceiverApp.swift, without a Mac underneath it.
//
// Everything that changes what's shown happens on this thread, in the order it arrived: the
// network thread only queues messages (and answers link probes, which are timed).
#define _GNU_SOURCE
#include "tandem.h"

#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

/// Exit status that asks whatever started this to turn the machine off.
#define EXIT_POWER_OFF 42

// ---- Options ----------------------------------------------------------------------------------

static struct {
    int headless_w, headless_h;
    uint16_t port;
    bool any_interface;
    const char *name;
    const char *font;
    const char *card;
    const char *backlight;
    int mode_w, mode_h;
    double mm_wide, mm_high;
    bool swap_tiles;
    bool allow_basic;
    bool no_input;
    bool show_log;
    bool debug, hash_all;
    double pointer_speed;
    int idle_blank_seconds;
    /// What "asleep" does to the panel: "dim" (black picture, backlight right down) or "off".
    const char *sleep_mode;
    int dump_at;
    const char *dump_path;
    const char *boot_picture;
    int boot_picture_w, boot_picture_h;
} options = {
    .port = WIRE_PORT, .font = "/usr/share/tandem/font.psf", .pointer_speed = 1, .idle_blank_seconds = 600,
    .sleep_mode = "dim", .show_log = true, .dump_at = -1,
};

static void parse_options(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i], *value = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(arg, "--headless")) { sscanf(value, "%dx%d", &options.headless_w, &options.headless_h); i++; }
        else if (!strcmp(arg, "--port")) { options.port = (uint16_t)atoi(value); i++; }
        else if (!strcmp(arg, "--any-interface")) options.any_interface = true;
        else if (!strcmp(arg, "--name")) { options.name = value; i++; }
        else if (!strcmp(arg, "--font")) { options.font = value; i++; }
        else if (!strcmp(arg, "--card")) { options.card = value; i++; }
        else if (!strcmp(arg, "--backlight")) { options.backlight = value; i++; }
        else if (!strcmp(arg, "--mode")) { sscanf(value, "%dx%d", &options.mode_w, &options.mode_h); i++; }
        else if (!strcmp(arg, "--size-mm")) { sscanf(value, "%lfx%lf", &options.mm_wide, &options.mm_high); i++; }
        else if (!strcmp(arg, "--swap-tiles")) options.swap_tiles = true;
        else if (!strcmp(arg, "--firmware-framebuffer")) options.allow_basic = true;
        else if (!strcmp(arg, "--no-input")) options.no_input = true;
        else if (!strcmp(arg, "--no-log")) options.show_log = false;
        else if (!strcmp(arg, "--debug")) options.debug = true;
        else if (!strcmp(arg, "--hash-all")) options.debug = options.hash_all = true;
        else if (!strcmp(arg, "--pointer-speed")) { options.pointer_speed = atof(value); i++; }
        else if (!strcmp(arg, "--idle-blank")) { options.idle_blank_seconds = atoi(value); i++; }
        else if (!strcmp(arg, "--sleep")) { options.sleep_mode = value; i++; }
        else if (!strcmp(arg, "--dump-at")) { options.dump_at = atoi(value); options.dump_path = i + 2 < argc ? argv[i + 2] : "dump.ppm"; i += 2; }
        else if (!strcmp(arg, "--boot-picture")) {
            // For making the stick: writes the boot menu's picture and stops.
            options.boot_picture = value;
            if (i + 2 >= argc || sscanf(argv[i + 2], "%dx%d", &options.boot_picture_w, &options.boot_picture_h) != 2) {
                fprintf(stderr, "--boot-picture PATH WIDTHxHEIGHT\n");
                exit(2);
            }
            i += 2;
        }
        else if (!strcmp(arg, "--version")) { puts("Tandem Display " TANDEM_DISPLAY_VERSION); exit(0); }
        else { fprintf(stderr, "unknown option %s\n", arg); exit(2); }
    }
}

// ---- What the network thread hands over -------------------------------------------------------

enum { ITEM_MESSAGE, ITEM_CONNECTED, ITEM_DISCONNECTED };
struct item {
    struct item *next;
    int what;
    uint8_t kind;
    uint8_t *body;
    size_t count;
};

static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static struct item *queue_head, *queue_tail;
static int wake_fd = -1;

static void wake(void) {
    uint64_t one = 1;
    if (write(wake_fd, &one, sizeof one) < 0) { /* already awake */ }
}

static void enqueue(int what, uint8_t kind, uint8_t *body, size_t count) {
    struct item *item = calloc(1, sizeof *item);
    if (!item) { free(body); return; }
    item->what = what;
    item->kind = kind;
    item->body = body;
    item->count = count;
    pthread_mutex_lock(&queue_lock);
    if (queue_tail) queue_tail->next = item; else queue_head = item;
    queue_tail = item;
    pthread_mutex_unlock(&queue_lock);
    wake();
}

static struct item *dequeue_all(void) {
    pthread_mutex_lock(&queue_lock);
    struct item *items = queue_head;
    queue_head = queue_tail = NULL;
    pthread_mutex_unlock(&queue_lock);
    return items;
}

// ---- The hello --------------------------------------------------------------------------------

static uint8_t hello[512];
static size_t hello_size;
static bool has_backlight;
static char machine_kind[32] = "Mac";
static char machine_name[128];

/// "iMac19,1" is an iMac, as Tandem's Machine.kind has it.
static void read_machine_kind(void) {
    char model[64] = "";
    FILE *file = fopen("/sys/class/dmi/id/product_name", "r");
    if (file) {
        if (!fgets(model, sizeof model, file)) model[0] = 0;
        fclose(file);
    }
    static const char *families[][2] = { { "MacBookPro", "MacBook Pro" }, { "MacBookAir", "MacBook Air" }, { "MacBook", "MacBook" },
                                         { "iMacPro", "iMac Pro" }, { "iMac", "iMac" }, { "Macmini", "Mac mini" }, { "MacPro", "Mac Pro" } };
    for (size_t i = 0; i < sizeof families / sizeof families[0]; i++) {
        if (strncmp(model, families[i][0], strlen(families[i][0])) == 0) {
            snprintf(machine_kind, sizeof machine_kind, "%s", families[i][1]);
            break;
        }
    }
    model[strcspn(model, "\r\n")] = 0;
    log_line("this machine: %s (%s)", model[0] ? model : "unknown", machine_kind);
}

/// u32 width, u32 height, f64 mmWide, f64 mmHigh, u16 version, u16 capabilities, f32 brightness,
/// then the peer: u16 name length, name, kind.
static void build_hello(struct output *output, struct renderer *renderer, float brightness) {
    double mm_wide = options.mm_wide > 0 ? options.mm_wide : output->mm_wide;
    double mm_high = options.mm_high > 0 ? options.mm_high : output->mm_high;
    if (mm_wide <= 0 || mm_high <= 0) {
        // No size from the panel: an iMac's is 218 pixels to the inch, an ordinary monitor's about half.
        double per_inch = output->width >= 3840 ? 218 : 109;
        mm_wide = output->width / per_inch * 25.4;
        mm_high = output->height / per_inch * 25.4;
    }
    uint16_t capabilities = CAP_CURSOR;
    if (renderer_supports_bc7(renderer)) capabilities |= CAP_BC7;
    if (has_backlight) capabilities |= CAP_BRIGHTNESS;

    uint8_t *p = hello;
    wr32(p, (uint32_t)output->width);
    wr32(p + 4, (uint32_t)output->height);
    uint64_t bits;
    memcpy(&bits, &mm_wide, 8);
    wr64(p + 8, bits);
    memcpy(&bits, &mm_high, 8);
    wr64(p + 16, bits);
    wr16(p + 24, WIRE_VERSION);
    wr16(p + 26, capabilities);
    uint32_t brightness_bits;
    memcpy(&brightness_bits, &brightness, 4);
    wr32(p + 28, brightness_bits);
    size_t name_length = strlen(machine_name), kind_length = strlen(machine_kind);
    wr16(p + 32, (uint16_t)name_length);
    memcpy(p + 34, machine_name, name_length);
    memcpy(p + 34 + name_length, machine_kind, kind_length);
    hello_size = 34 + name_length + kind_length;
}

// ---- Network handlers (on the network thread) -------------------------------------------------

static void on_connected(const char *from) {
    log_line("sender connected from %s", from);
    // The brightness as it is now, which the Mac's slider starts from.
    if (has_backlight) {
        float brightness = backlight_get();
        uint32_t bits;
        memcpy(&bits, &brightness, 4);
        wr32(hello + 28, bits);
    }
    net_send(K_HELLO, hello, hello_size);
    enqueue(ITEM_CONNECTED, 0, NULL, 0);
}

static void on_message(uint8_t kind, uint8_t *body, size_t count) {
    switch (kind) {
    case K_PROBE: {
        // Timed by the Mac to measure the link, so answered at once.
        uint8_t size[4];
        wr32(size, (uint32_t)count);
        net_send(K_PROBE_ACK, size, 4);
        free(body);
        break;
    }
    case K_FRAME: case K_STATUS: case K_POWER: case K_ABOUT: case K_DISPLAY: case K_CURSOR: case K_CURSOR_SHAPE: case K_INPUT_STATE:
        enqueue(ITEM_MESSAGE, kind, body, count);
        break;
    default:
        // Pings, and what only a Mac with a desktop of its own can do: peeking, swapping roles,
        // its settings menu, files.
        free(body);
    }
}

static void on_disconnected(void) {
    enqueue(ITEM_DISCONNECTED, 0, NULL, 0);
}

// ---- Input handlers (on the input thread) -----------------------------------------------------

static atomic_bool activity_seen;
static atomic_bool wake_on_activity;
static atomic_bool power_button_pressed;
static volatile sig_atomic_t stop_requested;

static void on_activity(void) {
    atomic_store(&activity_seen, true);
    if (atomic_load(&wake_on_activity)) wake();
}

static void on_power_button(void) {
    atomic_store(&power_button_pressed, true);
    wake();
}

static void on_signal(int number) {
    (void)number;
    stop_requested = 1;
}

// ---- State ------------------------------------------------------------------------------------

static struct output *output;
static struct renderer *renderer;
static bool connected, streaming, asleep_with_mac, blank, panel_off;
static int mac_input_state = INPUT_OFF;
static char peer_kind[64] = "Mac";
static char status_text[400];
static float wanted_brightness = -1, brightness_before_blank = -1;
static double last_activity, last_wake_sent;

// Frames wait for an answer once they're on screen.
#define MAX_ACKS 256
static uint32_t applied[MAX_ACKS], on_the_way[MAX_ACKS];
static int applied_count, on_the_way_count;
static bool flip_pending, dirty, black_shown;
static unsigned long frames_shown;

static void send_acks(uint32_t *frames, int *count) {
    for (int i = 0; i < *count; i++) {
        uint8_t body[4];
        wr32(body, frames[i]);
        net_send(K_ACK, body, 4);
    }
    *count = 0;
}

static void update_forwarding(void) {
    input_set_forwarding(streaming && !blank && mac_input_state == INPUT_READY);
}

static void set_blank(bool on) {
    if (on == blank) return;
    blank = on;
    atomic_store(&wake_on_activity, on);
    if (on) {
        if (has_backlight) {
            brightness_before_blank = backlight_get();
            backlight_set(0);
        }
    } else {
        if (panel_off) {
            output->set_power(output, true);
            panel_off = false;
        }
        float restore = wanted_brightness >= 0 ? wanted_brightness : brightness_before_blank;
        if (has_backlight && restore >= 0) backlight_set(restore);
        last_activity = now_seconds();
    }
    update_forwarding();
    dirty = true;
}

static void update_splash(void) {
    char title[200], detail[400], footer[300], link[100];
    net_link_description(link, sizeof link);
    if (connected && status_text[0]) {
        snprintf(title, sizeof title, "Connected to your %s", peer_kind);
        snprintf(detail, sizeof detail, "%s", status_text);
    } else if (connected) {
        snprintf(title, sizeof title, "Connected to your %s", peer_kind);
        snprintf(detail, sizeof detail, "Waiting for the picture…");
    } else {
        snprintf(title, sizeof title, "Waiting for your %s", peer_kind);
        snprintf(detail, sizeof detail, "Join the two with a Thunderbolt cable and open Tandem on the Mac you want to extend.");
    }
    snprintf(footer, sizeof footer, "%s  -  %d x %d  -  %s  -  Power button: shut down",
             machine_name, output->width, output->height, link);
    renderer_set_splash(renderer, title, detail, footer, options.show_log);
}

static void started_streaming(void) {
    streaming = true;
    status_text[0] = 0;
    asleep_with_mac = false;
    set_blank(false);
    update_forwarding();
    log_line("showing the %s's picture", peer_kind);
}

static void stopped_streaming(void) {
    if (!streaming) return;
    streaming = false;
    update_forwarding();
    dirty = true;
}

static void handle_message(uint8_t kind, const uint8_t *body, size_t count) {
    switch (kind) {
    case K_FRAME: {
        if (!streaming) started_streaming();
        uint32_t frame_no = 0;
        if (!renderer_apply(renderer, body, count, &frame_no)) {
            // The Mac's idea of what's on screen is now wrong, and it waits for an answer to
            // every frame: start the connection again rather than say nothing.
            net_drop();
            return;
        }
        if (options.debug && (frame_no % 120 == 0 || options.hash_all)) {
            log_line("frame %u hash %llx (lossless parts only)", frame_no, (unsigned long long)renderer_hash(renderer, true));
            if (options.hash_all) log_line("frame %u picture %llx", frame_no, (unsigned long long)renderer_hash(renderer, false));
        }
        if (options.dump_at >= 0 && (int)frame_no == options.dump_at) {
            log_line("frame %u written to %s: %s", frame_no, options.dump_path, renderer_dump_ppm(renderer, options.dump_path) ? "ok" : "failed");
        }
        if (applied_count == MAX_ACKS) send_acks(applied, &applied_count);
        applied[applied_count++] = frame_no;
        dirty = true;
        break;
    }
    case K_STATUS:
        snprintf(status_text, sizeof status_text, "%.*s", (int)(count < sizeof status_text - 1 ? count : sizeof status_text - 1), (const char *)body);
        log_line("status from sender: %s", status_text);
        stopped_streaming();
        dirty = true;
        break;
    case K_POWER:
        if (count < 1) break;
        log_line("%s power: %s", peer_kind, body[0] == POWER_SLEEP ? "sleep" : "wake");
        if (body[0] == POWER_SLEEP) {
            asleep_with_mac = true;
            stopped_streaming();
            set_blank(true);
        } else if (body[0] == POWER_WAKE) {
            asleep_with_mac = false;
            set_blank(false);
        }
        break;
    case K_ABOUT: {
        // u16 name length, name, kind
        if (count < 2 || (size_t)rd16(body) + 2 > count) break;
        size_t name_length = rd16(body), kind_length = count - 2 - name_length;
        if (kind_length > 0 && kind_length < sizeof peer_kind) {
            memcpy(peer_kind, body + 2 + name_length, kind_length);
            peer_kind[kind_length] = 0;
        }
        log_line("showing %.*s, a %s", (int)name_length, (const char *)body + 2, peer_kind);
        dirty = true;
        break;
    }
    case K_DISPLAY: {
        // f32 brightness (-1: leave alone), 9 x f32 colour matrix
        if (count < 40) break;
        float brightness, matrix[9];
        memcpy(&brightness, body, 4);
        memcpy(matrix, body + 4, 36);
        renderer_set_matrix(renderer, matrix);
        if (brightness >= 0 && brightness <= 1 && has_backlight) {
            wanted_brightness = brightness;
            if (!blank) backlight_set(brightness);
        }
        dirty = true;
        break;
    }
    case K_CURSOR:
        // i32 x | i32 y | u8 visible
        if (count < 9) break;
        renderer_set_cursor(renderer, (int32_t)rd32(body), (int32_t)rd32(body + 4), body[8] != 0);
        dirty = true;
        break;
    case K_CURSOR_SHAPE: {
        // u16 width | u16 height | u16 hotX | u16 hotY | premultiplied BGRA rows
        if (count < 8) break;
        int w = rd16(body), h = rd16(body + 2);
        if (w <= 0 || h <= 0 || w > 1024 || h > 1024 || count != 8 + (size_t)w * (size_t)h * 4) break;
        renderer_set_cursor_shape(renderer, w, h, rd16(body + 4), rd16(body + 6), body + 8);
        dirty = true;
        break;
    }
    case K_INPUT_STATE:
        if (count < 1 || body[0] > INPUT_READY) break;
        mac_input_state = body[0];
        log_line("the %s %s this keyboard and mouse", peer_kind,
                 mac_input_state == INPUT_READY ? "takes" : mac_input_state == INPUT_NEEDS_PERMISSION ? "needs permission to take" : "isn't taking");
        update_forwarding();
        break;
    }
}

static void handle_item(struct item *item) {
    if (item->what == ITEM_CONNECTED) {
        connected = true;
        streaming = false;
        status_text[0] = 0;
        mac_input_state = INPUT_OFF;
        applied_count = on_the_way_count = 0;
        renderer_reset_cursor(renderer);
        if (!asleep_with_mac) set_blank(false);
        update_forwarding();
        dirty = true;
    } else if (item->what == ITEM_DISCONNECTED) {
        log_line("sender disconnected");
        connected = false;
        streaming = false;
        mac_input_state = INPUT_OFF;
        status_text[0] = 0;
        applied_count = on_the_way_count = 0;
        static const float identity[9] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
        renderer_set_matrix(renderer, identity);
        renderer_clear(renderer);
        update_forwarding();
        last_activity = now_seconds();
        dirty = true;
    } else {
        handle_message(item->kind, item->body, item->count);
    }
}

int main(int argc, char **argv) {
    parse_options(argc, argv);
    if (options.boot_picture) {
        if (!font_load(options.font)) { fprintf(stderr, "no font at %s\n", options.font); return 1; }
        bool ok = splash_write_boot_picture(options.boot_picture, options.boot_picture_w, options.boot_picture_h);
        if (!ok) fprintf(stderr, "couldn't write %s\n", options.boot_picture);
        return ok ? 0 : 1;
    }
    setvbuf(stderr, NULL, _IOLBF, 0);
    log_line("Tandem Display %s", TANDEM_DISPLAY_VERSION);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);

    read_machine_kind();
    snprintf(machine_name, sizeof machine_name, "%s", options.name && *options.name ? options.name : machine_kind);
    if (!font_load(options.font)) log_line("no font at %s: the waiting screen will have no words", options.font);

    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    int workers = cores > 8 ? 7 : cores > 1 ? (int)cores - 1 : 0;
    pool_start(workers);

    if (options.headless_w > 0) {
        output = headless_open(options.headless_w, options.headless_h);
    } else {
        struct kms_options kms = { .card = options.card, .mode_width = options.mode_w, .mode_height = options.mode_h,
                                   .swap_tiles = options.swap_tiles, .wait_seconds = 90, .allow_basic = options.allow_basic };
        output = kms_open(&kms);
    }
    if (!output) return 1;
    renderer = renderer_create(output);
    if (!renderer) return 1;

    has_backlight = options.headless_w == 0 && backlight_open(options.backlight);
    if (has_backlight) log_line("brightness: %s, now %.0f%%", backlight_name(), backlight_get() * 100);
    else log_line("brightness: no control found");
    build_hello(output, renderer, has_backlight ? backlight_get() : -1);
    log_line("receiver %dx%d, %s, %s", output->width, output->height, output->description, machine_name);

    wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    struct net_handlers net = { on_connected, on_message, on_disconnected };
    if (!net_start(options.port, options.any_interface, &net)) return 1;
    if (!options.no_input && options.headless_w == 0) {
        struct input_handlers input = { on_activity, on_power_button };
        input_start(&input, options.pointer_speed);
    }

    last_activity = now_seconds();
    dirty = true;
    double last_splash = 0, last_splash_text = 0, last_report = now_seconds();
    // The waiting screen's dots move, so while it's shown it's drawn again every so often.
    double splash_interval = renderer_animation_interval(renderer);
    bool showing_splash = false;
    while (!stop_requested) {
        struct pollfd fds[2] = { { wake_fd, POLLIN, 0 }, { output->event_fd(output), POLLIN, 0 } };
        int timeout = 250;
        if (dirty && !flip_pending) {
            timeout = 0;
        } else if (showing_splash && !flip_pending) {
            double wait = last_splash + splash_interval - now_seconds();
            timeout = wait <= 0 ? 0 : wait >= 0.25 ? 250 : (int)(wait * 1000) + 1;
        }
        poll(fds, fds[1].fd >= 0 ? 2 : 1, timeout);
        if (fds[0].revents & POLLIN) {
            uint64_t count;
            if (read(wake_fd, &count, sizeof count) < 0) { /* nothing to clear */ }
        }
        if (fds[1].fd >= 0 && (fds[1].revents & POLLIN) && output->handle_events(output)) {
            // On screen: now the Mac may send what comes next.
            flip_pending = false;
            send_acks(on_the_way, &on_the_way_count);
        }

        for (struct item *item = dequeue_all(), *next; item; item = next) {
            next = item->next;
            handle_item(item);
            free(item->body);
            free(item);
        }

        double now = now_seconds();
        if (atomic_exchange(&power_button_pressed, false)) {
            log_line("power button: shutting down");
            return EXIT_POWER_OFF;
        }
        if (atomic_exchange(&activity_seen, false)) {
            last_activity = now;
            if (blank && asleep_with_mac && connected) {
                // Woken by hand while the Mac's screens are off but it's still there: wake it too.
                if (now - last_wake_sent > 2) {
                    last_wake_sent = now;
                    log_line("woken by hand, waking the %s", peer_kind);
                    uint8_t wake_byte = POWER_WAKE;
                    net_send(K_POWER, &wake_byte, 1);
                }
            } else if (blank) {
                asleep_with_mac = false;
                set_blank(false);
            }
        }
        // With no Mac to show, the screen doesn't stay lit for good.
        if (!blank && !connected && options.idle_blank_seconds > 0 && now - last_activity > options.idle_blank_seconds) {
            log_line("no Mac for %d s: screen off until a key, the mouse or a Mac", options.idle_blank_seconds);
            set_blank(true);
        }

        int what = blank ? SHOW_BLACK : streaming ? SHOW_PICTURE : SHOW_SPLASH;
        showing_splash = what == SHOW_SPLASH && !panel_off;
        // Only the dots moving: what the screen says needn't be looked at again.
        bool just_the_dots = false;
        if (what == SHOW_SPLASH && now - last_splash >= splash_interval) {
            last_splash = now;
            just_the_dots = !dirty;
            dirty = true;
        }
        if (dirty && !flip_pending && !panel_off) {
            // What it says is looked at again whenever something happened, and once a second for
            // the cable's state and the log, which move on by themselves.
            if (what == SHOW_SPLASH && (!just_the_dots || now - last_splash_text >= 1)) {
                update_splash();
                last_splash_text = now;
            }
            dirty = false;
            if (renderer_present(renderer, what)) {
                flip_pending = true;
                memcpy(on_the_way, applied, (size_t)applied_count * sizeof applied[0]);
                on_the_way_count = applied_count;
                applied_count = 0;
            } else {
                send_acks(applied, &applied_count);
            }
            frames_shown++;
            black_shown = what == SHOW_BLACK;
        } else if (panel_off && applied_count > 0) {
            // Nothing is shown while the panel is off, but the Mac still wants its answers.
            send_acks(applied, &applied_count);
        }

        // Asleep, and the black picture is on screen: the panel itself can go off, if asked.
        if (blank && black_shown && !flip_pending && !dirty && !panel_off && strcmp(options.sleep_mode, "off") == 0) {
            output->set_power(output, false);
            panel_off = true;
        }

        if (options.debug && now - last_report >= 5) {
            log_line("%lu frames shown in the last %.0f s", frames_shown, now - last_report);
            frames_shown = 0;
            last_report = now;
        }
    }
    log_line("stopping");
    return 0;
}
