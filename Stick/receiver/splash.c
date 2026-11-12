// The waiting screen: "Tandem Display", three dots under it, and what's happening. The boot
// menu's picture is the same screen drawn ahead of time, so starting up looks like one screen
// that comes to life: the picture appears as the iMac starts, stays while Linux starts, and the
// display program takes over drawing it with the dots moving.
#include "tandem.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/// The waiting screen's background, as 0xRRGGBB.
#define BACKGROUND 0x0c0c10

/// Draws text centred on x, breaking it into lines no wider than `limit`. Returns the y below it.
/// With `draw` false, only works out where that would be.
static int draw_wrapped(uint8_t *rgba, int w, int h, const char *text, int centre, int y, int limit, int scale,
                        uint32_t color, bool draw) {
    int columns = limit / (font_width() * scale);
    if (columns < 8) columns = 8;
    size_t length = strlen(text);
    const char *line = text;
    while (*line) {
        size_t take = strlen(line);
        if ((int)take > columns) {
            take = (size_t)columns;
            while (take > 0 && line[take] != ' ') take--;
            if (take == 0) take = (size_t)columns;
        }
        char buffer[512];
        if (take >= sizeof buffer) take = sizeof buffer - 1;
        memcpy(buffer, line, take);
        buffer[take] = 0;
        if (draw) text_draw(rgba, w, h, centre - text_width(buffer, scale) / 2, y, buffer, scale, color);
        y += font_height() * scale + font_height() * scale / 4;
        line += take;
        while (*line == ' ') line++;
        if (line > text + length) break;
    }
    return y;
}

static void fill(uint8_t *rgba, size_t pixels, uint32_t color) {
    for (size_t i = 0; i < pixels; i++) {
        uint8_t *pixel = rgba + i * 4;
        pixel[0] = (uint8_t)(color >> 16); pixel[1] = (uint8_t)(color >> 8); pixel[2] = (uint8_t)color; pixel[3] = 255;
    }
}

/// The dots as they are before anything moves them, drawn into the picture.
static void draw_still_dots(uint8_t *rgba, int w, int h, const struct splash_dots *dots) {
    for (int i = 0; i < 3; i++) {
        float cx = dots->x + (float)(i - 1) * dots->spacing, cy = dots->y;
        int r = (int)ceilf(dots->radius) + 2;
        for (int y = (int)cy - r; y <= (int)cy + r; y++) {
            for (int x = (int)cx - r; x <= (int)cx + r; x++) {
                if (x < 0 || y < 0 || x >= w || y >= h) continue;
                float d = hypotf((float)x + 0.5f - cx, (float)y + 0.5f - cy);
                // Edges softened over a pixel, like the shader's.
                float cover = fminf(fmaxf(dots->radius + 0.5f - d, 0), 1);
                float a = cover * SPLASH_DOT_REST;
                uint8_t *pixel = rgba + ((size_t)y * (size_t)w + (size_t)x) * 4;
                for (int c = 0; c < 3; c++) pixel[c] = (uint8_t)lroundf((float)pixel[c] * (1 - a) + 255 * a);
            }
        }
    }
}

void splash_draw(uint8_t *rgba, int w, int h, const char *status, const char *detail, const char *footer,
                 char lines[][160], int line_count, bool still_dots, struct splash_dots *dots) {
    fill(rgba, (size_t)w * (size_t)h, BACKGROUND);
    memset(dots, 0, sizeof *dots);
    if (font_height() == 0) return;
    // Sized for the picture, whatever the font: the name around a twentieth of the height.
    int unit = h / 22 / font_height();
    if (unit < 1) unit = 1;
    int small = unit > 1 ? unit / 2 : 1;
    int line = font_height() * small;

    // The name and the dots stay where they are whatever is said under them.
    int y = h * 36 / 100;
    y = draw_wrapped(rgba, w, h, "Tandem Display", w / 2, y, w * 8 / 10, unit, 0xffffff, true);
    dots->radius = (float)line * 0.17f;
    dots->spacing = dots->radius * 4.2f;
    dots->x = (float)w / 2;
    dots->y = (float)y + (float)line * 0.9f;
    if (still_dots) draw_still_dots(rgba, w, h, dots);
    y = (int)(dots->y + (float)line * 1.4f);

    if (status && *status) y = draw_wrapped(rgba, w, h, status, w / 2, y, w * 7 / 10, small, 0xd2d2da, true);
    if (detail && *detail) draw_wrapped(rgba, w, h, detail, w / 2, y + line / 3, w * 7 / 10, small, 0x8a8a94, true);

    // The footer sits on the bottom edge however many lines it takes.
    int footer_top = h;
    if (footer && *footer) {
        int footer_height = draw_wrapped(rgba, w, h, footer, w / 2, 0, w * 9 / 10, small, 0, false);
        footer_top = h - footer_height - line / 2;
        draw_wrapped(rgba, w, h, footer, w / 2, footer_top, w * 9 / 10, small, 0x5c5c66, true);
    }
    int top = footer_top - line * (line_count + 1);
    for (int i = 0; i < line_count; i++) text_draw(rgba, w, h, w / 20, top + i * line, lines[i], small, 0x3f3f48);
}

// ---- The boot menu's picture ------------------------------------------------------------------

/// Writes a run-length encoded TGA (what GRUB reads besides PNG and JPEG): 24 bits, top row first.
static bool write_tga(const char *path, const uint8_t *rgba, int w, int h) {
    FILE *file = fopen(path, "wb");
    if (!file) return false;
    uint8_t header[18] = { 0 };
    header[2] = 10; // run-length encoded true colour
    wr16(header + 12, (uint16_t)w);
    wr16(header + 14, (uint16_t)h);
    header[16] = 24;
    header[17] = 0x20; // the top row first
    fwrite(header, 1, sizeof header, file);
    for (int y = 0; y < h; y++) {
        const uint8_t *row = rgba + (size_t)y * (size_t)w * 4;
        // Packets never cross from one row to the next.
        int x = 0;
        while (x < w) {
            int run = 1;
            while (x + run < w && run < 128 && memcmp(row + x * 4, row + (x + run) * 4, 3) == 0) run++;
            if (run > 1) {
                const uint8_t *p = row + x * 4;
                uint8_t packet[4] = { (uint8_t)(0x80 | (run - 1)), p[2], p[1], p[0] };
                fwrite(packet, 1, 4, file);
                x += run;
                continue;
            }
            // Pixels that differ from the next, until two the same come along.
            int count = 1;
            while (x + count < w && count < 128 &&
                   (x + count + 1 >= w || memcmp(row + (x + count) * 4, row + (x + count + 1) * 4, 3) != 0)) count++;
            fputc(count - 1, file);
            for (int i = 0; i < count; i++) {
                const uint8_t *p = row + (x + i) * 4;
                uint8_t bgr[3] = { p[2], p[1], p[0] };
                fwrite(bgr, 1, 3, file);
            }
            x += count;
        }
    }
    bool ok = ferror(file) == 0;
    return fclose(file) == 0 && ok;
}

bool splash_write_boot_picture(const char *path, int w, int h) {
    uint8_t *rgba = malloc((size_t)w * (size_t)h * 4);
    if (!rgba) return false;
    struct splash_dots dots;
    splash_draw(rgba, w, h, "Starting", "", "", NULL, 0, true, &dots);
    bool ok = write_tga(path, rgba, w, h);
    free(rgba);
    return ok;
}
