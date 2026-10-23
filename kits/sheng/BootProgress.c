// SPDX-License-Identifier: MIT
/*
 * Framebuffer boot log for boards with no usable serial port.
 *
 * The kernel maps the framebuffer itself in initialize_screen(); that is the
 * earliest point where text can be written, so this file draws into the
 * mapping it is handed by the zzz-boot-progress.patch call sites. Stages
 * recorded before the bind are replayed at bind time, which is what turns a
 * silent hang into "the kernel got this far".
 *
 * ponytail: one screen, no scrollback (the screen scrolls), no fonts other
 * than the 5x12 AOSP glyphs, and no serial mirroring. Upgrade path: a real
 * console driver with a ring buffer once the board boots.
 */
#include <kern/boot_progress.h>
#include <stdint.h>

#define BP_COLS_MAX 256

/* 5x12 AOSP glyphs, packed two rows per 32-bit half (see BootFont.h). */
#define GLYPH_FONT_TABLE
#include "BootFont.h"
static const uint64_t bp_font[] = GLYPH_FONT;

static volatile uint32_t *bp_fb __attribute__((aligned(8)));
static unsigned bp_width, bp_height, bp_stride;   /* pixels / bytes per row */
static unsigned bp_cw, bp_ch;                     /* cell size in pixels */
static unsigned bp_col, bp_row;
static unsigned bp_bound;
static volatile unsigned bp_lock;

/* The stage string is only ever read back by the same CPU that wrote it. */
static char bp_stage[BP_COLS_MAX];

static inline int
bp_trylock(void)
{
	return __atomic_test_and_set(&bp_lock, __ATOMIC_ACQUIRE) == 0;
}

static inline void
bp_unlock(void)
{
	__atomic_clear(&bp_lock, __ATOMIC_RELEASE);
}

static void bp_pixel(unsigned x, unsigned y, uint32_t color);
static void bp_wrap(void);

static void
bp_clear_row(unsigned row)
{
	unsigned y = row * bp_ch;
	unsigned x, dy;

	for (dy = 0; dy < bp_ch; dy++) {
		for (x = 0; x < bp_width; x++) {
			bp_pixel(x, y + dy, 0xFF000000u);
		}
	}
}

static void
bp_pixel(unsigned x, unsigned y, uint32_t color)
{
	((volatile uint32_t *)((volatile char *)bp_fb + (uint64_t)y * bp_stride))[x] = color;
}

static void
bp_cell(unsigned col, unsigned row, unsigned ch, uint32_t fg)
{
	unsigned x0 = col * bp_cw;
	unsigned y0 = row * bp_ch;
	unsigned gx, gy, dy, dx;
	uint64_t glyph = (ch >= 32 && ch <= 126) ? bp_font[ch - 32] : 0;

	for (gy = 0; gy < bp_ch; gy++) {
		for (gx = 0; gx < bp_cw; gx++) {
			bp_pixel(x0 + gx, y0 + gy, 0xFF000000u);
		}
	}
	for (gy = 0; gy < 12; gy++) {
		uint32_t bits = (gy < 6) ? (uint32_t)(glyph >> 32) >> (gy * 5)
		    : (uint32_t)glyph >> ((gy - 6) * 5);
		for (gx = 0; gx < 5; gx++) {
			if (!((bits >> gx) & 1)) {
				continue;
			}
			for (dy = 0; dy < 2; dy++) {
				for (dx = 0; dx < 2; dx++) {
					bp_pixel(x0 + gx * 2 + dx, y0 + gy * 2 + dy, fg);
				}
			}
		}
	}
}

static void
bp_newline(void)
{
	bp_col = 0;
	if (++bp_row >= bp_height / bp_ch) {
		bp_wrap();
	}
	bp_clear_row(bp_row);
}

/* Bottom of the screen reached: start over instead of copying rows.
 * ponytail: history is lost on a wrap, but a wrap costs one clear instead of a
 * 9 MiB row copy per line under -v. Upgrade path: a real ring buffer. */
static void
bp_wrap(void)
{
	unsigned x, y;

	for (y = 0; y < bp_height; y++) {
		for (x = 0; x < bp_width; x++) {
			bp_pixel(x, y, 0xFF000000u);
		}
	}
	bp_row = 0;
}

static void
bp_puts(const char *s, uint32_t fg)
{
	for (; *s != 0; s++) {
		if (*s == '\n') {
			bp_newline();
			continue;
		}
		if (*s == '\r') {
			bp_col = 0;
			continue;
		}
		if (*s < 32 || *s > 126) {
			continue;
		}
		if (bp_col >= bp_width / bp_cw) {
			bp_newline();
		}
		bp_cell(bp_col++, bp_row, (unsigned char)*s, fg);
	}
}

/* Caller holds bp_lock. */
static void
bp_line(const char *tag, const char *text)
{
	bp_col = 0;
	bp_clear_row(bp_row);
	bp_puts(tag, 0xFF00FFFFu);
	bp_puts(text, 0xFFFFFFFFu);
	bp_newline();
}

void
boot_progress_init(void)
{
	/* Nothing readable exists yet; stages buffer in bp_stage. */
}

void
boot_progress_bind(uintptr_t base, unsigned width, unsigned height,
    unsigned stride, unsigned depth)
{
	if (base == 0 || width == 0 || height == 0 || stride == 0) {
		return;
	}
	/* Apple encodes "video present" in bit 0 of the address. */
	base &= ~(uintptr_t)7;
	if (depth != 32) {
		return;         /* only the 32bpp BGRA panel path is supported */
	}
	if (!bp_trylock()) {
		return;
	}
	if (bp_bound && bp_fb == (volatile uint32_t *)base) {
		/* initialize_screen() is called again on console acquire; keep the log. */
		bp_unlock();
		return;
	}
	bp_fb = (volatile uint32_t *)base;
	bp_width = width;
	bp_height = height;
	bp_stride = stride;
	bp_cw = 6 * 2;
	bp_ch = 14 * 2;
	bp_col = 0;
	bp_row = 0;
	bp_bound = 1;
	bp_line("xnu: ", "framebuffer console up");
	if (bp_stage[0] != 0) {
		bp_line("xnu: ", bp_stage);
	}
	bp_unlock();
}

int
boot_progress_active(void)
{
	return bp_bound;
}

void
boot_progress_start(void)
{
	if (!bp_bound) {
		return;
	}
	if (!bp_trylock()) {
		return;
	}
	bp_line("xnu: ", "kernel boot");
	bp_unlock();
}

void
boot_progress_putc(char c)
{
	if (!bp_bound) {
		return;
	}
	if (!bp_trylock()) {
		return;
	}
	if (c == '\n') {
		bp_newline();
	} else if (c == '\r') {
		bp_col = 0;
	} else if ((unsigned char)c >= 32 && (unsigned char)c <= 126) {
		if (bp_col >= bp_width / bp_cw) {
			bp_newline();
		}
		bp_cell(bp_col++, bp_row, (unsigned char)c, 0xFFFFFFFFu);
	}
	bp_unlock();
}

void
boot_progress_stage(const char *message)
{
	unsigned long i = 0;

	if (message == 0) {
		return;
	}
	while (message[i] != 0 && i + 1 < sizeof(bp_stage)) {
		bp_stage[i] = message[i];
		i++;
	}
	bp_stage[i] = 0;
	if (!bp_bound) {
		return;
	}
	if (!bp_trylock()) {
		return;
	}
	bp_line("xnu: ", message);
	bp_unlock();
}

void
boot_progress_process_stage(int pid, const char *name, const char *stage)
{
	if (!bp_bound || pid < 0) {
		return;
	}
	if (!bp_trylock()) {
		return;
	}
	bp_col = 0;
	bp_puts("xnu: ", 0xFF00FFFFu);
	bp_puts(name ? name : "?", 0xFFFFFFFFu);
	bp_puts(" ", 0xFFFFFFFFu);
	bp_puts(stage ? stage : "?", 0xFFFFFFFFu);
	bp_newline();
	bp_unlock();
}

void
boot_progress_exit(int pid, const char *name, int code, unsigned sig,
    uint64_t unused)
{
	char digits[12];
	unsigned i = 0;

	(void)unused;
	(void)pid;
	if (!bp_bound) {
		return;
	}
	do {
		digits[i++] = (char)('0' + (code % 10));
		code /= 10;
	} while (code != 0 && i < sizeof(digits));
	if (!bp_trylock()) {
		return;
	}
	bp_col = 0;
	bp_puts("xnu: exit ", 0xFF00FFFFu);
	bp_puts(name ? name : "?", 0xFFFFFFFFu);
	bp_puts(" status ", 0xFFFFFFFFu);
	while (i > 0) {
		bp_puts(&digits[--i], 0xFFFFFFFFu);
	}
	if (sig != 0) {
		bp_puts(" signal", 0xFFFFFFFFu);
	}
	bp_newline();
	bp_unlock();
}

void
boot_progress_critical_exit(int pid, char *prefix, unsigned long len)
{
	(void)pid;
	(void)prefix;
	(void)len;
}

void
boot_progress_irq(uint64_t pc, uint64_t cpsr, uint64_t sp)
{
	(void)pc;
	(void)cpsr;
	(void)sp;
}

void
boot_progress_poll(void)
{
}

void
boot_progress_user_breakpoint(void *state, unsigned esr)
{
	(void)state;
	(void)esr;
}

void
boot_progress_user_abort(void *state, unsigned esr, uint64_t addr)
{
	(void)state;
	(void)esr;
	(void)addr;
}
