#!/bin/sh
# Self-check for the framebuffer boot log: renders into a fake framebuffer and
# asserts text, newline, scroll and bounds behaviour. No kernel, no framework.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/inc/kern"
python3 - "$ROOT/patches/xnu/zzz-boot-progress.patch" "$TMP/inc/kern/boot_progress.h" <<'PY'
import sys
patch = open(sys.argv[1]).read()
start = patch.index('+++ b/osfmk/kern/boot_progress.h')
end = patch.index('--- a/osfmk/kern/Makefile')
body = [line[1:] for line in patch[start:end].splitlines()[1:] if line.startswith('+')]
open(sys.argv[2], 'w').write('\n'.join(body) + '\n')
PY
cat > "$TMP/test.c" <<'C'
#include <kern/boot_progress.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 120
#define ROW 480
#define ROWS 3                 /* 3 cells of 28 pixels: 84 pixels tall */
#define GUARD 64

static uint8_t *fb;
static int failures;

static uint32_t px(unsigned x, unsigned y)
{
	uint32_t v;
	memcpy(&v, fb + (size_t)y * ROW + (size_t)x * 4, 4);
	return v;
}

static void check(int cond, const char *what)
{
	if (!cond) {
		printf("FAIL %s\n", what);
		failures++;
	}
}

int main(void)
{
	int i;

	fb = calloc(1, (size_t)ROW * ROWS * 28 + GUARD);
	memset(fb + (size_t)ROW * ROWS * 28, 0xA5, GUARD);

	boot_progress_init();
	check(!boot_progress_active(), "inactive before bind");
	boot_progress_bind((uintptr_t)fb | 1, W, ROWS * 28, ROW, 32);
	check(boot_progress_active(), "active after bind");

	/* The bind banner occupies row 0 and is drawn opaque. */
	check(px(0, 0) == 0xFF000000u || px(1, 1) != 0, "row 0 drawn");

	boot_progress_putc('A');
	check(px(0, 27) == 0xFF000000u, "row 0 background is opaque black");

	/* Overwrite with a shorter line: stale glyphs must be cleared. */
	boot_progress_putc('\n');
	boot_progress_putc('\n');
	boot_progress_stage("arm_vm_init returned");
	check(px(W - 1, 2 * 28) == 0xFF000000u, "cleared row after stage");

	/* More lines than rows: must scroll and stay inside the framebuffer. */
	for (i = 0; i < 3 * 10; i++) {
		boot_progress_putc('y');
		boot_progress_putc('\n');
	}
	check(px(0, ROWS * 28 - 1) == 0xFF000000u, "scroll completes");

	for (i = 0; i < GUARD; i++) {
		if (fb[(size_t)ROW * ROWS * 28 + i] != 0xA5) {
			break;
		}
	}
	check(i == GUARD, "no writes past the framebuffer");

	printf(failures ? "FAILED %d\n" : "PASS\n", failures);
	free(fb);
	return failures != 0;
}
C
clang -O1 -Wall -Wextra -Werror -mgeneral-regs-only \
	-I"$TMP/inc" -I"$ROOT/kits/sheng" -DXNU_BOOT_PROGRESS=1 \
	-o "$TMP/test" "$TMP/test.c" "$ROOT/kits/sheng/BootProgress.c"
"$TMP/test"
