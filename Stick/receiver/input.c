// The iMac's keyboard and mouse, lent to the Mac: Tandem's Receiver/InputCapture.swift.
//
// On macOS that forwards CGEvents as they are. Here there are none, so Linux input events
// (evdev) are turned into the same messages: a CGEventType, CGEventFlags and the CGEvent fields
// the Mac replays. There's no desktop of this machine's own to go back to, so the keyboard and
// mouse belong to the Mac whenever it's showing a picture and will take them.
#define _GNU_SOURCE
#include "tandem.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

// CGEventType
enum { CG_LEFT_DOWN = 1, CG_LEFT_UP = 2, CG_RIGHT_DOWN = 3, CG_RIGHT_UP = 4, CG_MOVED = 5, CG_LEFT_DRAGGED = 6,
       CG_RIGHT_DRAGGED = 7, CG_KEY_DOWN = 10, CG_KEY_UP = 11, CG_FLAGS_CHANGED = 12, CG_SYSTEM_DEFINED = 14,
       CG_SCROLL = 22, CG_OTHER_DOWN = 25, CG_OTHER_UP = 26, CG_OTHER_DRAGGED = 27 };
// CGEventField
enum { F_CLICK_STATE = 1, F_BUTTON = 3, F_DELTA_X = 4, F_DELTA_Y = 5, F_AUTOREPEAT = 8, F_KEYCODE = 9,
       F_SCROLL_1 = 11, F_SCROLL_2 = 12, F_CONTINUOUS = 88, F_SCROLL_FIXED_1 = 93, F_SCROLL_FIXED_2 = 94,
       F_SCROLL_POINT_1 = 96, F_SCROLL_POINT_2 = 97, F_SCROLL_PHASE = 99, F_SCROLL_COUNT = 100, F_MOMENTUM_PHASE = 123,
       F_SUBTYPE = 0x1000, F_DATA1 = 0x1001, F_DATA2 = 0x1002 };
// CGEventFlags, and under them the bits that say which of a pair of keys it is.
enum { FLAG_CAPS = 0x10000, FLAG_SHIFT = 0x20000, FLAG_CONTROL = 0x40000, FLAG_OPTION = 0x80000, FLAG_COMMAND = 0x100000,
       FLAG_KEYPAD = 0x200000, FLAG_FN = 0x800000, FLAG_ALWAYS = 0x100,
       DEV_LCTRL = 0x1, DEV_LSHIFT = 0x2, DEV_RSHIFT = 0x4, DEV_LCMD = 0x8, DEV_RCMD = 0x10, DEV_LOPT = 0x20, DEV_ROPT = 0x40,
       DEV_RCTRL = 0x2000 };

/// macOS virtual key codes for Linux key codes; -1 where there's none.
static short keymap[KEY_CNT];
/// Flags a key's own events carry (arrows and function keys say "fn", the keypad says "keypad").
static uint32_t key_flags[KEY_CNT];

struct modifier { int key; int code; uint32_t flag, device; };
static const struct modifier modifiers[] = {
    { KEY_LEFTSHIFT, 0x38, FLAG_SHIFT, DEV_LSHIFT },   { KEY_RIGHTSHIFT, 0x3C, FLAG_SHIFT, DEV_RSHIFT },
    { KEY_LEFTCTRL, 0x3B, FLAG_CONTROL, DEV_LCTRL },   { KEY_RIGHTCTRL, 0x3E, FLAG_CONTROL, DEV_RCTRL },
    { KEY_LEFTALT, 0x3A, FLAG_OPTION, DEV_LOPT },      { KEY_RIGHTALT, 0x3D, FLAG_OPTION, DEV_ROPT },
    { KEY_LEFTMETA, 0x37, FLAG_COMMAND, DEV_LCMD },    { KEY_RIGHTMETA, 0x36, FLAG_COMMAND, DEV_RCMD },
    { KEY_FN, 0x3F, FLAG_FN, 0 },
};
#define MODIFIER_COUNT (int)(sizeof modifiers / sizeof modifiers[0])

/// Keys macOS knows as media keys (NX_KEYTYPE_*), which travel as system-defined events.
static int media_key(int key) {
    switch (key) {
    case KEY_VOLUMEUP: return 0;
    case KEY_VOLUMEDOWN: return 1;
    case KEY_MUTE: return 7;
    case KEY_EJECTCD: return 14;
    case KEY_PLAYPAUSE: return 16;
    case KEY_NEXTSONG: return 17;
    case KEY_PREVIOUSSONG: return 18;
    case KEY_FASTFORWARD: return 19;
    case KEY_REWIND: return 20;
    case KEY_KBDILLUMUP: return 21;
    case KEY_KBDILLUMDOWN: return 22;
    default: return -1;
    }
}

static void build_keymap(void) {
    for (int i = 0; i < KEY_CNT; i++) keymap[i] = -1;
    static const struct { int key; short code; } keys[] = {
        { KEY_A, 0x00 }, { KEY_S, 0x01 }, { KEY_D, 0x02 }, { KEY_F, 0x03 }, { KEY_H, 0x04 }, { KEY_G, 0x05 }, { KEY_Z, 0x06 },
        { KEY_X, 0x07 }, { KEY_C, 0x08 }, { KEY_V, 0x09 }, { KEY_102ND, 0x0A }, { KEY_B, 0x0B }, { KEY_Q, 0x0C }, { KEY_W, 0x0D },
        { KEY_E, 0x0E }, { KEY_R, 0x0F }, { KEY_Y, 0x10 }, { KEY_T, 0x11 }, { KEY_1, 0x12 }, { KEY_2, 0x13 }, { KEY_3, 0x14 },
        { KEY_4, 0x15 }, { KEY_6, 0x16 }, { KEY_5, 0x17 }, { KEY_EQUAL, 0x18 }, { KEY_9, 0x19 }, { KEY_7, 0x1A },
        { KEY_MINUS, 0x1B }, { KEY_8, 0x1C }, { KEY_0, 0x1D }, { KEY_RIGHTBRACE, 0x1E }, { KEY_O, 0x1F }, { KEY_U, 0x20 },
        { KEY_LEFTBRACE, 0x21 }, { KEY_I, 0x22 }, { KEY_P, 0x23 }, { KEY_ENTER, 0x24 }, { KEY_L, 0x25 }, { KEY_J, 0x26 },
        { KEY_APOSTROPHE, 0x27 }, { KEY_K, 0x28 }, { KEY_SEMICOLON, 0x29 }, { KEY_BACKSLASH, 0x2A }, { KEY_COMMA, 0x2B },
        { KEY_SLASH, 0x2C }, { KEY_N, 0x2D }, { KEY_M, 0x2E }, { KEY_DOT, 0x2F }, { KEY_TAB, 0x30 }, { KEY_SPACE, 0x31 },
        { KEY_GRAVE, 0x32 }, { KEY_BACKSPACE, 0x33 }, { KEY_ESC, 0x35 }, { KEY_CAPSLOCK, 0x39 },
        { KEY_F17, 0x40 }, { KEY_KPDOT, 0x41 }, { KEY_KPASTERISK, 0x43 }, { KEY_KPPLUS, 0x45 }, { KEY_NUMLOCK, 0x47 },
        { KEY_KPSLASH, 0x4B }, { KEY_KPENTER, 0x4C }, { KEY_KPMINUS, 0x4E }, { KEY_F18, 0x4F }, { KEY_F19, 0x50 },
        { KEY_KPEQUAL, 0x51 }, { KEY_KP0, 0x52 }, { KEY_KP1, 0x53 }, { KEY_KP2, 0x54 }, { KEY_KP3, 0x55 }, { KEY_KP4, 0x56 },
        { KEY_KP5, 0x57 }, { KEY_KP6, 0x58 }, { KEY_KP7, 0x59 }, { KEY_F20, 0x5A }, { KEY_KP8, 0x5B }, { KEY_KP9, 0x5C },
        { KEY_F5, 0x60 }, { KEY_F6, 0x61 }, { KEY_F7, 0x62 }, { KEY_F3, 0x63 }, { KEY_F8, 0x64 }, { KEY_F9, 0x65 },
        { KEY_F11, 0x67 }, { KEY_F13, 0x69 }, { KEY_SYSRQ, 0x69 }, { KEY_F16, 0x6A }, { KEY_F14, 0x6B }, { KEY_SCROLLLOCK, 0x6B },
        { KEY_F10, 0x6D }, { KEY_F12, 0x6F }, { KEY_F15, 0x71 }, { KEY_PAUSE, 0x71 }, { KEY_INSERT, 0x72 }, { KEY_HELP, 0x72 },
        { KEY_HOME, 0x73 }, { KEY_PAGEUP, 0x74 }, { KEY_DELETE, 0x75 }, { KEY_F4, 0x76 }, { KEY_END, 0x77 }, { KEY_F2, 0x78 },
        { KEY_PAGEDOWN, 0x79 }, { KEY_F1, 0x7A }, { KEY_LEFT, 0x7B }, { KEY_RIGHT, 0x7C }, { KEY_DOWN, 0x7D }, { KEY_UP, 0x7E },
        // Apple keyboards' top row, when it isn't sending F1 to F12. Brightness goes as key
        // codes, which is how Tandem on the Mac expects it from an Apple keyboard.
        { KEY_BRIGHTNESSUP, 144 }, { KEY_BRIGHTNESSDOWN, 145 }, { KEY_SCALE, 160 }, { KEY_ALL_APPLICATIONS, 131 },
        // A PC keyboard's menu key.
        { KEY_COMPOSE, 0x6E },
    };
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) keymap[keys[i].key] = keys[i].code;
    for (int i = 0; i < MODIFIER_COUNT; i++) keymap[modifiers[i].key] = (short)modifiers[i].code;

    static const int fn_keys[] = { KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11,
                                   KEY_F12, KEY_F13, KEY_F14, KEY_F15, KEY_F16, KEY_F17, KEY_F18, KEY_F19, KEY_F20,
                                   KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_DELETE, KEY_INSERT, KEY_HELP };
    for (size_t i = 0; i < sizeof fn_keys / sizeof fn_keys[0]; i++) key_flags[fn_keys[i]] = FLAG_FN;
    static const int arrows[] = { KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN };
    for (size_t i = 0; i < sizeof arrows / sizeof arrows[0]; i++) key_flags[arrows[i]] = FLAG_FN | FLAG_KEYPAD;
    static const int keypad[] = { KEY_KP0, KEY_KP1, KEY_KP2, KEY_KP3, KEY_KP4, KEY_KP5, KEY_KP6, KEY_KP7, KEY_KP8, KEY_KP9,
                                  KEY_KPDOT, KEY_KPASTERISK, KEY_KPPLUS, KEY_KPSLASH, KEY_KPENTER, KEY_KPMINUS, KEY_KPEQUAL,
                                  KEY_NUMLOCK };
    for (size_t i = 0; i < sizeof keypad / sizeof keypad[0]; i++) key_flags[keypad[i]] = FLAG_KEYPAD;
}

// ---- Sending ----------------------------------------------------------------------------------

struct field { uint32_t id; double value; };

/// u32 type | u64 flags | then pairs of u32 field, f64 value
static void send_event(uint32_t type, uint64_t flags, const struct field *fields, int count) {
    uint8_t body[12 + 16 * 12];
    if (count > 16) count = 16;
    wr32(body, type);
    wr64(body + 4, flags);
    for (int i = 0; i < count; i++) {
        uint64_t bits;
        memcpy(&bits, &fields[i].value, 8);
        wr32(body + 12 + i * 12, fields[i].id);
        wr64(body + 12 + i * 12 + 4, bits);
    }
    net_send(K_INPUT, body, (size_t)(12 + count * 12));
}

// ---- State ------------------------------------------------------------------------------------

#define MAX_DEVICES 64
struct device {
    int fd;
    bool grabbed;
    double dx, dy;     // movement since the last report
    int wheel, hwheel; // notches since the last report
};

static struct device devices[MAX_DEVICES];
static struct input_handlers handlers;
static double pointer_speed = 1;
static atomic_bool forwarding_wanted;
static bool forwarding;

static bool modifier_down[MODIFIER_COUNT];
static bool caps_lock;
static bool button_down[8];
static int click_count;
static int click_button = -1;
static double click_time;
static double moved_since_click;
static double last_move_time;
static double last_wheel_time;

static uint64_t current_flags(void) {
    uint64_t flags = FLAG_ALWAYS;
    for (int i = 0; i < MODIFIER_COUNT; i++) {
        if (modifier_down[i]) flags |= modifiers[i].flag | modifiers[i].device;
    }
    if (caps_lock) flags |= FLAG_CAPS;
    return flags;
}

static void set_grab(struct device *device, bool grab) {
    if (device->fd < 0 || device->grabbed == grab) return;
    // Grabbed, the keys don't also reach this machine's own console underneath.
    if (ioctl(device->fd, EVIOCGRAB, grab ? 1 : 0) == 0) device->grabbed = grab;
}

/// Lets go of everything on the Mac: nothing sticks when control stops.
static void release_all(void) {
    send_event(0, 0, NULL, 0);
    memset(modifier_down, 0, sizeof modifier_down);
    memset(button_down, 0, sizeof button_down);
}

static void apply_forwarding(void) {
    bool wanted = atomic_load(&forwarding_wanted);
    if (wanted == forwarding) return;
    forwarding = wanted;
    if (!forwarding) release_all();
    for (int i = 0; i < MAX_DEVICES; i++) set_grab(&devices[i], forwarding);
    log_line("keyboard and mouse: %s", forwarding ? "controlling the Mac" : "not in use");
}

void input_set_forwarding(bool on) { atomic_store(&forwarding_wanted, on); }

// ---- Events -----------------------------------------------------------------------------------

static void key_event(int key, int value) {
    if (key == KEY_POWER) {
        if (value == 1) handlers.power_button();
        return;
    }
    if (!forwarding) return;

    // Mouse buttons.
    if (key >= BTN_MOUSE && key < BTN_JOYSTICK) {
        if (value == 2) return;
        int button = key == BTN_LEFT ? 0 : key == BTN_RIGHT ? 1 : key == BTN_MIDDLE ? 2 : key - BTN_MOUSE;
        if (button < 0 || button > 7) return;
        bool down = value == 1;
        double now = now_seconds();
        if (down) {
            bool again = button == click_button && now - click_time < 0.5 && moved_since_click < 6;
            click_count = again ? click_count + 1 : 1;
            click_button = button;
            click_time = now;
            moved_since_click = 0;
        }
        button_down[button] = down;
        uint32_t type = button == 0 ? (down ? CG_LEFT_DOWN : CG_LEFT_UP) : button == 1 ? (down ? CG_RIGHT_DOWN : CG_RIGHT_UP)
                                                                                      : (down ? CG_OTHER_DOWN : CG_OTHER_UP);
        struct field fields[] = { { F_BUTTON, button }, { F_CLICK_STATE, click_button == button ? click_count : 1 } };
        send_event(type, current_flags(), fields, 2);
        return;
    }
    if (key < 0 || key >= KEY_CNT) return;

    for (int i = 0; i < MODIFIER_COUNT; i++) {
        if (modifiers[i].key != key) continue;
        if (value == 2) return;
        modifier_down[i] = value == 1;
        struct field fields[] = { { F_KEYCODE, modifiers[i].code }, { F_AUTOREPEAT, 0 } };
        send_event(CG_FLAGS_CHANGED, current_flags(), fields, 2);
        return;
    }
    if (key == KEY_CAPSLOCK) {
        // One press turns it on, the next turns it off; letting go says nothing.
        if (value != 1) return;
        caps_lock = !caps_lock;
        struct field fields[] = { { F_KEYCODE, 0x39 }, { F_AUTOREPEAT, 0 } };
        send_event(CG_FLAGS_CHANGED, current_flags(), fields, 2);
        return;
    }

    int media = media_key(key);
    if (media >= 0) {
        // NSEvent's system-defined event for a media key: subtype 8, and in data1 the key, then
        // 0x0A for down or 0x0B for up, then whether it's repeating.
        bool down = value != 0;
        double data1 = (double)((media << 16) | ((down ? 0x0A : 0x0B) << 8) | (value == 2 ? 1 : 0));
        struct field fields[] = { { F_SUBTYPE, 8 }, { F_DATA1, data1 }, { F_DATA2, -1 } };
        send_event(CG_SYSTEM_DEFINED, down ? 0xA00 : 0xB00, fields, 3);
        return;
    }

    int code = keymap[key];
    if (code < 0) return;
    struct field fields[] = { { F_KEYCODE, code }, { F_AUTOREPEAT, value == 2 ? 1 : 0 } };
    send_event(value == 0 ? CG_KEY_UP : CG_KEY_DOWN, current_flags() | key_flags[key], fields, 2);
}

static void report(struct device *device) {
    double now = now_seconds();
    if (device->dx != 0 || device->dy != 0) {
        // A mouse's own counts, sped up as it moves faster, as macOS does for a real mouse.
        double seconds = now - last_move_time;
        if (seconds < 0.001) seconds = 0.001;
        if (seconds > 0.05) seconds = 0.05;
        last_move_time = now;
        double distance = hypot(device->dx, device->dy);
        double speed = distance / seconds;
        double gain = (0.5 + fmin(speed / 4000.0, 1.0) * 1.5) * pointer_speed;
        moved_since_click += distance;
        if (forwarding) {
            int button = button_down[0] ? 0 : button_down[1] ? 1 : -1;
            for (int i = 2; button < 0 && i < 8; i++) {
                if (button_down[i]) button = i;
            }
            uint32_t type = button == 0 ? CG_LEFT_DRAGGED : button == 1 ? CG_RIGHT_DRAGGED : button > 1 ? CG_OTHER_DRAGGED : CG_MOVED;
            struct field fields[] = { { F_DELTA_X, device->dx * gain }, { F_DELTA_Y, device->dy * gain }, { F_BUTTON, button < 0 ? 0 : button } };
            send_event(type, current_flags(), fields, 3);
        }
        device->dx = device->dy = 0;
    }
    if (device->wheel != 0 || device->hwheel != 0) {
        // Lines, as a mouse wheel sends: more of them when the wheel is spun quickly.
        int lines = now - last_wheel_time < 0.06 ? 4 : 2;
        last_wheel_time = now;
        if (forwarding) {
            double vertical = device->wheel * lines, horizontal = device->hwheel * lines;
            struct field fields[] = {
                { F_SCROLL_1, vertical }, { F_SCROLL_2, horizontal },
                { F_SCROLL_FIXED_1, vertical }, { F_SCROLL_FIXED_2, horizontal },
                { F_SCROLL_POINT_1, vertical * 10 }, { F_SCROLL_POINT_2, horizontal * 10 },
                { F_CONTINUOUS, 0 }, { F_SCROLL_PHASE, 0 }, { F_MOMENTUM_PHASE, 0 }, { F_SCROLL_COUNT, 0 },
            };
            send_event(CG_SCROLL, current_flags(), fields, 10);
        }
        device->wheel = device->hwheel = 0;
    }
}

static void read_device(struct device *device) {
    struct input_event events[64];
    for (;;) {
        ssize_t n = read(device->fd, events, sizeof events);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN) return;
        if (n <= 0) {
            // Unplugged.
            close(device->fd);
            device->fd = -1;
            device->grabbed = false;
            return;
        }
        handlers.activity();
        for (size_t i = 0; i < (size_t)n / sizeof events[0]; i++) {
            const struct input_event *event = &events[i];
            if (event->type == EV_KEY) {
                key_event(event->code, event->value);
            } else if (event->type == EV_REL) {
                if (event->code == REL_X) device->dx += event->value;
                else if (event->code == REL_Y) device->dy += event->value;
                else if (event->code == REL_WHEEL) device->wheel += event->value;
                else if (event->code == REL_HWHEEL) device->hwheel += event->value;
            } else if (event->type == EV_SYN && event->code == SYN_REPORT) {
                report(device);
            }
        }
    }
}

static void scan_devices(void) {
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (devices[i].fd >= 0) continue;
        char path[64];
        snprintf(path, sizeof path, "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        unsigned long types = 0;
        char name[128] = "?";
        ioctl(fd, EVIOCGNAME(sizeof name), name);
        if (ioctl(fd, EVIOCGBIT(0, sizeof types), &types) < 0 || !(types & (1ul << EV_KEY))) {
            close(fd);
            // Remember it isn't wanted, so it isn't opened again every time.
            devices[i].fd = -2;
            continue;
        }
        devices[i] = (struct device){ .fd = fd };
        log_line("input: %s (%s)", name, path);
        set_grab(&devices[i], forwarding);
    }
}

static void *input_thread(void *unused) {
    (void)unused;
    double last_scan = -10;
    for (;;) {
        double now = now_seconds();
        if (now - last_scan > 2) {
            last_scan = now;
            // Devices that weren't wanted may have gone, and their numbers been given to others.
            for (int i = 0; i < MAX_DEVICES; i++) {
                if (devices[i].fd != -2) continue;
                char path[64];
                snprintf(path, sizeof path, "/dev/input/event%d", i);
                if (access(path, F_OK) != 0) devices[i].fd = -1;
            }
            scan_devices();
        }
        apply_forwarding();

        struct pollfd fds[MAX_DEVICES];
        int map[MAX_DEVICES], count = 0;
        for (int i = 0; i < MAX_DEVICES; i++) {
            if (devices[i].fd < 0) continue;
            fds[count] = (struct pollfd){ devices[i].fd, POLLIN, 0 };
            map[count++] = i;
        }
        if (poll(fds, (nfds_t)count, 200) <= 0) continue;
        for (int i = 0; i < count; i++) {
            if (fds[i].revents) read_device(&devices[map[i]]);
        }
    }
    return NULL;
}

void input_start(const struct input_handlers *callbacks, double speed) {
    handlers = *callbacks;
    if (speed > 0) pointer_speed = speed;
    build_keymap();
    for (int i = 0; i < MAX_DEVICES; i++) devices[i].fd = -1;
    pthread_t thread;
    if (pthread_create(&thread, NULL, input_thread, NULL) == 0) pthread_detach(thread);
}
