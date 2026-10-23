# Panel console: how boot output reaches the screen

## The problem

There is no usable serial port on this tablet, the generated ADT has no serial
node, and `PE_init_console()` falls back to `PE_kputc = serial_putc_crlf` only
when `serial_init()` succeeds. So every kprintf before the framebuffer is mapped
is written nowhere.

The earliest point where text is possible at all is the moment
`initialize_screen()` (`osfmk/console/video_console.c:2797`) maps the
framebuffer — that call is inside `PE_create_console()`, which `arm_init` runs
*after* `arm_vm_init`. Before that the only channel is reset timing (see
[04-probe-playbook.md](04-probe-playbook.md)).

## What was built

`kits/sheng/` contains a self-contained framebuffer console, compiled by
`scripts/build-boot-progress.py` with the exact flags CI used for
`osfmk/kern/startup.o` (read out of `startup.o.json`), archived as
`libBootProgress.a`, and force-loaded into the kernel when
`XNU_BOOT_PROGRESS=1`.

| file | role |
|---|---|
| `kits/sheng/BootProgress.c` | the console: bind, putc, stage breadcrumbs, line scroll |
| `kits/sheng/BootFont.h` | 96 glyphs, 5x12, AOSP `DiagFont.h` (same font the loader uses for its diagnostics) |
| `kits/sheng/test-boot-progress.sh` | renders into a fake framebuffer and asserts text/newline/scroll/bounds |
| `scripts/build-boot-progress.py` | ABI-exact compile + `ar` |
| `patches/xnu/zzz-boot-progress.patch` | call sites (arm_init, startup, video_console, serial_console, pe_kprintf, sleh, bsd_init, kern_exec, kern_exit) |

The patch declares the API in `osfmk/kern/boot_progress.h` and compiles to
no-ops unless `-DXNU_BOOT_PROGRESS=1` is set, so the same tree builds both ways.

## Behaviour

- `boot_progress_bind(base, width, height, stride, depth)` is called by the
  patched `initialize_screen()` with the **already mapped virtual address**, so
  the console can write with plain stores. Depth must be 32 bpp; anything else
  is ignored (the gta4l panel is BGRA8888).
- The first line is `xnu: framebuffer console up`, then the last stage string
  recorded before the bind, then the live kprintf stream.
- `PE_init_console()` is redirected: once the console is bound, `PE_kputc`
  points at `boot_progress_putc`, so `kprintf` output goes to the panel even
  though the XNU video console itself is never initialised.
- Geometry: 12x28 pixel cells, so 1200x2000 gives 100 columns x 71 rows.
  Text is white on opaque black; the `xnu: ` tag is cyan. Because the cell
  background is opaque, the loader's green bar disappears from row 0 as soon as
  the first line is drawn — that is the visual proof that the console is live.
- When the bottom row is reached the text area is scrolled up by one cell row.
- Binding and drawing are guarded by a non-blocking atomic lock: output from an
  interrupt handler is dropped instead of deadlocking the kernel.
- No cache maintenance is needed or done: the framebuffer is mapped as I/O
  write-combined (`pmap_cache_attributes()` falls back to `VM_WIMG_IO` for a PA
  outside the managed window).

## What it deliberately does not do

`ponytail:` one screen, no scrollback buffer, no serial mirroring, no timestamp,
no font scaling beyond 2x. The stage breadcrumbs are a single 256-byte string,
not a ring. Upgrade path: a real console driver with a ring buffer once the
board reaches userspace.

`boot_progress_irq`, `_user_breakpoint`, `_user_abort`, `_critical_exit` and
`_poll` are intentionally empty: they run in contexts where drawing would either
deadlock or lose the panic we are trying to read.

## Enabling it

`.github/workflows/build-xnu-kernel-gta4l.yaml` sets `XNU_BOOT_PROGRESS: "1"`;
`scripts/build-xnu-4k-baseline.sh` then patches, builds and links the archive.
Unset it to build the same kernel without the console.

Local check of the renderer (no kernel needed):

```
sh kits/sheng/test-boot-progress.sh      # PASS
```
