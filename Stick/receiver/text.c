// Text for the waiting screen, from a console font (PSF), and the panel's backlight.
#include "tandem.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- Font -------------------------------------------------------------------------------------

static uint8_t *glyphs;
static int glyph_count, glyph_bytes, glyph_width, glyph_height;

bool font_load(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) return false;
    uint8_t header[32];
    size_t got = fread(header, 1, sizeof header, file);
    long offset = 0;
    if (got >= 32 && rd32(header) == 0x864ab572u) { // PSF2
        offset = rd32(header + 8);
        glyph_count = (int)rd32(header + 16);
        glyph_bytes = (int)rd32(header + 20);
        glyph_height = (int)rd32(header + 24);
        glyph_width = (int)rd32(header + 28);
    } else if (got >= 4 && header[0] == 0x36 && header[1] == 0x04) { // PSF1
        offset = 4;
        glyph_count = (header[2] & 1) ? 512 : 256;
        glyph_bytes = header[3];
        glyph_height = header[3];
        glyph_width = 8;
    } else {
        fclose(file);
        return false;
    }
    bool sane = glyph_count >= 128 && glyph_count <= 65536 && glyph_width > 0 && glyph_width <= 64 &&
                glyph_height > 0 && glyph_height <= 128 && glyph_bytes == ((glyph_width + 7) / 8) * glyph_height;
    if (sane) {
        glyphs = malloc((size_t)glyph_count * (size_t)glyph_bytes);
        sane = glyphs && fseek(file, offset, SEEK_SET) == 0 &&
               fread(glyphs, (size_t)glyph_bytes, (size_t)glyph_count, file) == (size_t)glyph_count;
    }
    fclose(file);
    if (!sane) {
        free(glyphs);
        glyphs = NULL;
    }
    return sane;
}

int font_width(void) { return glyphs ? glyph_width : 0; }
int font_height(void) { return glyphs ? glyph_height : 0; }

/// The next character of UTF-8 text as something the font has: ASCII, with the few other
/// characters Tandem's messages use turned into their nearest. 0 at the end.
static int next_char(const char **text) {
    const unsigned char *p = (const unsigned char *)*text;
    if (*p == 0) return 0;
    if (*p < 0x80) {
        *text += 1;
        return *p < 0x20 ? ' ' : *p;
    }
    int length = (*p & 0xe0) == 0xc0 ? 2 : (*p & 0xf0) == 0xe0 ? 3 : (*p & 0xf8) == 0xf0 ? 4 : 1;
    unsigned code = length == 2 ? (*p & 0x1fu) : length == 3 ? (*p & 0x0fu) : length == 4 ? (*p & 0x07u) : 0xfffd;
    for (int i = 1; i < length; i++) {
        if ((p[i] & 0xc0) != 0x80) { length = i; code = 0xfffd; break; }
        code = code << 6 | (p[i] & 0x3fu);
    }
    *text += length;
    switch (code) {
    case 0x2018: case 0x2019: return '\'';
    case 0x201c: case 0x201d: return '"';
    case 0x2013: case 0x2014: return '-';
    case 0x2026: return '~'; // drawn as "..." by the caller
    case 0x00d7: return 'x';
    case 0x00b7: case 0x2022: return '-';
    case 0x00a0: return ' ';
    case 0x2192: return '>';
    default: return '?';
    }
}

int text_width(const char *text, int scale) {
    int count = 0;
    for (int c; (c = next_char(&text)) != 0;) count += c == '~' ? 3 : 1;
    return count * font_width() * scale;
}

static void draw_glyph(uint8_t *rgba, int width, int height, int x, int y, int c, int scale, uint32_t color) {
    if (c >= glyph_count) c = '?';
    const uint8_t *glyph = glyphs + (size_t)c * (size_t)glyph_bytes;
    int row_bytes = (glyph_width + 7) / 8;
    uint8_t r = (uint8_t)(color >> 16), g = (uint8_t)(color >> 8), b = (uint8_t)color;
    for (int gy = 0; gy < glyph_height; gy++) {
        for (int gx = 0; gx < glyph_width; gx++) {
            if (!(glyph[gy * row_bytes + gx / 8] & (0x80 >> (gx % 8)))) continue;
            for (int sy = 0; sy < scale; sy++) {
                int py = y + gy * scale + sy;
                if (py < 0 || py >= height) continue;
                for (int sx = 0; sx < scale; sx++) {
                    int px = x + gx * scale + sx;
                    if (px < 0 || px >= width) continue;
                    uint8_t *pixel = rgba + ((size_t)py * (size_t)width + (size_t)px) * 4;
                    pixel[0] = r; pixel[1] = g; pixel[2] = b; pixel[3] = 255;
                }
            }
        }
    }
}

int text_draw(uint8_t *rgba, int width, int height, int x, int y, const char *text, int scale, uint32_t color) {
    if (!glyphs) return 0;
    int start = x;
    for (int c; (c = next_char(&text)) != 0;) {
        int repeat = c == '~' ? 3 : 1;
        for (int i = 0; i < repeat; i++) {
            draw_glyph(rgba, width, height, x, y, c == '~' ? '.' : c, scale, color);
            x += glyph_width * scale;
        }
    }
    return x - start;
}

// ---- Backlight --------------------------------------------------------------------------------

static char backlight_dir[300];
static char backlight_device[64];
static long backlight_max;

static long read_number(const char *dir, const char *name) {
    char path[400];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *file = fopen(path, "r");
    if (!file) return -1;
    long value = -1;
    if (fscanf(file, "%ld", &value) != 1) value = -1;
    fclose(file);
    return value;
}

static bool backlight_try(const char *name) {
    char dir[300];
    snprintf(dir, sizeof dir, "/sys/class/backlight/%s", name);
    long max = read_number(dir, "max_brightness");
    if (max <= 0 || read_number(dir, "brightness") < 0) return false;
    snprintf(backlight_dir, sizeof backlight_dir, "%s", dir);
    snprintf(backlight_device, sizeof backlight_device, "%s", name);
    backlight_max = max;
    return true;
}

bool backlight_open(const char *preferred) {
    if (preferred && *preferred && backlight_try(preferred)) return true;
    // The firmware's control first, where there is one: on these iMacs it's the one that works.
    static const char *order[] = { "acpi_video0", "apple_backlight", "gmux_backlight", NULL };
    for (int i = 0; order[i]; i++) {
        if (backlight_try(order[i])) return true;
    }
    DIR *dir = opendir("/sys/class/backlight");
    if (!dir) return false;
    bool found = false;
    for (struct dirent *entry; !found && (entry = readdir(dir)) != NULL;) {
        if (entry->d_name[0] != '.') found = backlight_try(entry->d_name);
    }
    closedir(dir);
    return found;
}

const char *backlight_name(void) { return backlight_device; }

float backlight_get(void) {
    if (!backlight_max) return -1;
    long value = read_number(backlight_dir, "brightness");
    if (value < 0) return -1;
    float fraction = (float)value / (float)backlight_max;
    return fraction > 1 ? 1 : fraction;
}

void backlight_set(float fraction) {
    if (!backlight_max || !(fraction >= 0)) return;
    if (fraction > 1) fraction = 1;
    long value = (long)(fraction * (float)backlight_max + 0.5f);
    // Never all the way off: with nothing lit there'd be no telling it was still on.
    if (value < 1) value = 1;
    char path[400];
    snprintf(path, sizeof path, "%s/brightness", backlight_dir);
    FILE *file = fopen(path, "w");
    if (!file) return;
    fprintf(file, "%ld\n", value);
    fclose(file);
}
