#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# Source versions come from feeds.toml through the unixnu driver; the defaults are the qualified ones.
XNU_TAG=${UNIXNU_XNU_TAG:-xnu-10063.141.1}
XNU_COMMIT=${UNIXNU_XNU_COMMIT:-d8b80295118ef25ac3a784134bcf95cd8e88109f}
XNU_DARWIN=${UNIXNU_XNU_DARWIN:-23.6.0}
XNU_VERSION=${UNIXNU_XNU_VERSION:-10063.141.1}
LIBPLATFORM_TAG=${UNIXNU_LIBPLATFORM_TAG:-libplatform-316.100.10}
LIBDISPATCH_TAG=${UNIXNU_LIBDISPATCH_TAG:-libdispatch-1477.100.9}
AVAILABILITY_TAG=${UNIXNU_AVAILABILITYVERSIONS_TAG:-AvailabilityVersions-141.1}
if [ ! -d refer/xnu/.git ]; then
  git clone --depth 1 --branch "$XNU_TAG" https://github.com/apple-oss-distributions/xnu.git refer/xnu

fi
if [ "$(git -C refer/xnu rev-parse HEAD)" != "$XNU_COMMIT" ]; then
  echo 'error: unexpected XNU reference revision' >&2
  exit 1
fi
if [ ! -d .cache/xnu-work/.git ]; then
  git clone --shared refer/xnu .cache/xnu-work
fi

# Xcode 16.2 clang does not accept -mach_msg2 (added in later toolchains); strip it
set -x
grep -rl -- '-mach_msg2' .cache/xnu-work --include='*.mk' --include='Makefile*' --include='*.template' --include='*.xcconfig' 2>/dev/null | while read -r f; do
  sed -i '' 's/-mach_msg2//g' "$f"
  echo "patched: $f"
done || true
if [ ! -x .cache/fakeroot/usr/local/libexec/availability.pl ]; then
  if [ ! -d refer/AvailabilityVersions/.git ]; then
    git clone --depth 1 --branch "$AVAILABILITY_TAG" https://github.com/apple-oss-distributions/AvailabilityVersions.git refer/AvailabilityVersions
  fi
  mkdir -p .cache/fakeroot
  make -C refer/AvailabilityVersions install -j"${JOBS:-4}" \
    OBJROOT="$ROOT/build/availability" SYMROOT="$ROOT/build/availability" \
    DSTROOT="$ROOT/.cache/fakeroot" CMAKE="$(command -v cmake)" NINJA="$(command -v ninja)"
fi
# --- nabu: undo a previous marker injection before patches are (re)applied ---
# The injection below edits osfmk/arm/arm_init.c and osfmk/conf/files.arm64, the same
# files native-4k-user-abi / zzz-boot-progress / source-machine-layer patch. On a reused
# work tree those edits must be removed first or `git apply --check` fails.
if [ -d .cache/xnu-work/osfmk/arm ]; then
  rm -f .cache/xnu-work/osfmk/arm/nabu_early_mark.c .cache/xnu-work/osfmk/arm/nabu_early_mark.h
  python3 - .cache/xnu-work/osfmk/arm/arm_init.c .cache/xnu-work/osfmk/conf/files.arm64 .cache/xnu-work/osfmk/console/video_console.c .cache/xnu-work/osfmk/kern/startup.c .cache/xnu-work/pexpert/arm/pe_init.c .cache/xnu-work/osfmk/kern/ipc_kobject.c .cache/xnu-work/osfmk/arm64/sleh.c <<'MKU'
import io,re,sys
def rw(p,f):
    s=io.open(p,encoding='utf-8').read()
    n=f(s)
    if n!=s:
        io.open(p,'w',encoding='utf-8',newline='').write(n)
        print('  nabu pre-clean: reverted '+p)
def arm(s):
    s=re.sub(r'^[ \t]*#include <arm/nabu_early_mark\.h>\n','',s,count=1,flags=re.M)
    s=re.sub(r'^[ \t]*nabu_mark_(?:init|rebind|map|show|val|quad)\([^\n]*\);|nabu_abort_hold\n','',s,count=0,flags=re.M)
    for n in range(1,65):
        s=re.sub(r'^[ \t]*NABU_MARK\('+str(n)+r'\);\n','',s,count=1,flags=re.M)
    return s
def conff(s):
    return ''.join(l for l in s.splitlines(True) if 'nabu_early_mark.c' not in l)
def vc_clean(t):
    t=re.sub(r'^#include <arm/nabu_early_mark\.h>\n','',t,count=1,flags=re.M)
    t=re.sub(r'\t/\* nabu: vcattach just mapped the framebuffer.*?\n\t\}\n','',t,count=1,flags=re.S)
    for n in range(1,65):
        t=re.sub(r'^[ \t]*NABU_MARK\('+str(n)+r'\);\n','',t,count=1,flags=re.M)
    return t
def st_clean(t):
    t=re.sub(r'^#include (?:"\.\./\.\./osfmk/arm/nabu_early_mark\.h"|<arm/nabu_early_mark\.h>)\n','',t,count=1,flags=re.M)
    for n in range(1,65):
        t=re.sub(r'^[ \t]*NABU_MARK\('+str(n)+r'\);\n','',t,count=1,flags=re.M)
    return t
rw(sys.argv[1],arm)
rw(sys.argv[2],conff)
if len(sys.argv) > 3:
    rw(sys.argv[3],vc_clean)
if len(sys.argv) > 4:
    rw(sys.argv[4],st_clean)
if len(sys.argv) > 5:
    rw(sys.argv[5],st_clean)
if len(sys.argv) > 6:
    rw(sys.argv[6],st_clean)
MKU
fi
# --- end nabu pre-clean ---
# The optional observation hooks overlap existing root/exec patch context.
# Remove them first so earlier independent patches retain their idempotent checks.
# The same holds for the boot-time GPU addon mount (zzy), which edits the owner Data mount function inside the systemos patch.
# Reverse newest first; the loop below re-applies them in name order.
for LATE_PATCH in "$ROOT/patches/xnu/zzz-boot-progress.patch" "$ROOT/patches/xnu/zzy-native-gpu-addon-mount.patch"; do
  if git -C .cache/xnu-work apply --reverse --check "$LATE_PATCH" >/dev/null 2>&1; then
    git -C .cache/xnu-work apply --reverse "$LATE_PATCH"
  fi
done
for PATCH in "$ROOT"/patches/xnu/*.patch "$ROOT"/kits/NativePrelink/patches/*.patch; do
  # Boot progress is off: its patch only adds call sites, and the fuzz fallback
  # below drops them at file scope in sleh.c (statement outside a function).
  # ponytail: re-enable with XNU_BOOT_PROGRESS=1 only after the patch context is
  # rebased on this tree.
  if [ "$(basename "$PATCH")" = zzz-boot-progress.patch ] && [ "${XNU_BOOT_PROGRESS:-0}" != 1 ]; then
    continue
  fi
  if git -C .cache/xnu-work apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    continue            # already applied
  fi
  if git -C .cache/xnu-work apply --check "$PATCH" >/dev/null 2>&1; then
    git -C .cache/xnu-work apply "$PATCH"
  else
    # The patch set drifted against this tree: offline-owner reshaped the bsd_init
    # rootauth block and kern_exec paths, and the later zzz/zzy patches assume that
    # reshape. git apply is strict about context, so fall back to patch --fuzz, which
    # tolerates the line drift these patches accumulated.
    echo "nabu: strict apply failed, retrying with fuzz: $(basename "$PATCH")"
    ( cd .cache/xnu-work && patch -p1 --forward --fuzz=3 --no-backup-if-mismatch -i "$PATCH" ) \
      || echo "nabu: WARN patch unresolved: $(basename "$PATCH")"
  fi
done
# --- nabu: early checkpoint markers (diagnostic only) ---
# Placed AFTER the patch loop: patches/xnu/native-4k-user-abi.patch and
# patches/xnu/zzz-boot-progress.patch both edit osfmk/arm/arm_init.c, and
# patches/xnu/source-machine-layer.patch edits osfmk/conf/files.arm64.
# Editing either before the loop breaks their apply context.
if [ -d .cache/xnu-work/osfmk/arm ]; then
  cat > .cache/xnu-work/osfmk/arm/nabu_early_mark.h <<'MKH'
/* The framebuffer is a physical address here and is NOT mapped yet, so the early
 * checkpoints only record RAM state; rebind() replays them once the console has
 * mapped the screen. */
void nabu_mark_init(const unsigned long *video);
void nabu_mark_rebind(const unsigned long *video);
/* Map the video aperture ourselves once the VM is up and replay what we have. */
void nabu_mark_map(unsigned long pbase, unsigned long row, unsigned long w, unsigned long h);
void nabu_mark_show(int n);
void nabu_mark_val(int v);
void nabu_mark_quad(int a, int b, int c, int d);
void nabu_mark(int n);
#define NABU_MARK(n) nabu_mark(n)
MKH
  cat > .cache/xnu-work/osfmk/arm/nabu_early_mark.c <<'MKC'
#include "nabu_early_mark.h"
#include <stddef.h>
#include <machine/machine_routines.h>
#include <vm/pmap.h>
#include <vm/vm_map.h>
static volatile unsigned int *g_fb = NULL;
static unsigned long g_px = 0;
static unsigned int g_w = 0, g_h = 0;
static int g_slot = 0;
static void draw_all(void);   /* defined below; nabu_mark keeps the screen current */
static unsigned long long g_hits = 0; /* bit n-1 set == checkpoint n was reached */
#define NABU_MAX_MARK 64
static const unsigned int g_palette[8] = {
  0xFFFFFFFF, 0xFFFFFF00, 0xFF00FFFF, 0xFF00FF00,
  0xFFFF00FF, 0xFFFF8000, 0xFF0000FF, 0xFFFF0000
};
/* 3x5 digits, drawn large so the checkpoint number is readable in a photo. */
static const unsigned char g_font[10][5] = {
  {7,5,5,5,7}, {2,6,2,2,7}, {7,1,7,4,7}, {7,1,7,1,7}, {5,5,7,1,1},
  {7,4,7,1,7}, {7,4,7,5,7}, {7,1,1,1,1}, {7,5,7,5,7}, {7,5,7,1,7}
};
static void fill(unsigned int x0, unsigned int y0, unsigned int w, unsigned int h, unsigned int c)
{
  unsigned int x, y, xe = x0 + w, ye = y0 + h;
  if (g_fb == NULL) { return; }
  if (xe > g_w) { xe = g_w; }
  if (ye > g_h) { ye = g_h; }
  for (y = y0; y < ye; y++) { for (x = x0; x < xe; x++) { g_fb[(unsigned long)y * g_px + x] = c; } }
}
static int sane(unsigned long row, unsigned long w, unsigned long h)
{
  return row >= 4 && row <= 65536 && w >= 1 && w <= 8192 && h >= 1 && h <= 8192;
}
static int set_geom(const unsigned long *v)
{
  unsigned long row, w, h;
  int fallback = 0;
  g_fb = NULL; g_px = 0; g_w = 0; g_h = 0;
  if (v == NULL || v[0] == 0) { return 0; }
  /* struct Boot_Video order: base, display, rowBytes, width, height, depth */
  row = v[2]; w = v[3]; h = v[4];
  if (!sane(row, w, h)) {
    /* legacy boot_args.Video array order: base, rowBytes, width, height, ... */
    row = v[1]; w = v[2]; h = v[3];
    fallback = 1;
    if (!sane(row, w, h)) { return 0; }
  }
  g_fb = (volatile unsigned int *)(unsigned long)v[0];
  g_px = row / 4;
  g_w = (unsigned int)w; g_h = (unsigned int)h;
  return fallback ? 2 : 1;
}
/* Arm WITHOUT touching the framebuffer. Before PE_create_console the kernel has no
 * mapping for the video aperture, so a store to it faults and ends the boot; the
 * checkpoints must therefore stay in RAM until the console maps the screen. */
void nabu_mark_init(const unsigned long *v)
{
  (void)v;
  g_fb = NULL; g_px = 0; g_w = 0; g_h = 0;
  g_slot = 0; g_hits = 0;
}
void nabu_mark(int n)
{
  if (n < 1 || n > NABU_MAX_MARK) { return; }
  g_hits |= (1ULL << (n - 1));
  if (g_fb == NULL) { return; }   /* RAM only until the screen is mapped */
  draw_all();                     /* keep the strip current, no replay needed */
}
static void draw_digit(unsigned int x0, unsigned int y0, int d, unsigned int s)
{
  int r, c;
  for (r = 0; r < 5; r++) {
    for (c = 0; c < 3; c++) {
      if ((g_font[d][r] >> (2 - c)) & 1) {
        fill(x0 + (unsigned int)c * s, y0 + (unsigned int)r * s, s, s, 0xFFFFFFFF);
      }
    }
  }
}
static void draw_number(unsigned int x0, unsigned int y0, int value, unsigned int s)
{
  /* Clear the whole two-digit cell first: without this a smaller value leaves the
   * previous tens digit behind and "4" reads as "54". */
  fill(x0, y0, 7 * s, 5 * s, 0xFF000000);
  if (value < 0) { value = 0; }
  if (value > 99) { value = 99; }
  if (value >= 10) { draw_digit(x0, y0, value / 10, s); }
  draw_digit(x0 + 4 * s, y0, value % 10, s);
}
/* Highest checkpoint reached: the number on screen, independent of the colours. */
static int max_hit(void)
{
  int n, m = 0;
  for (n = 1; n <= NABU_MAX_MARK; n++) {
    if (g_hits & (1ULL << (n - 1))) { m = n; }
  }
  return m;
}
/* Show a live number without recording a checkpoint: used inside the startup
 * scheduler loop, where the value is data (the subsystem being brought up), not
 * a fixed checkpoint id. */
void nabu_mark_show(int n)
{
  /* Two readouts, because one digit is not enough: a subsystem can hold hundreds
   * of entries (ZALLOC has 767), so the subsystem id alone cannot name the entry.
   * Left cell = subsystem, right cell = how many of its entries already returned. */
  static int last_sys = -1, within = 0;
  if (n != last_sys) { last_sys = n; within = 0; }
  within++;
  if (g_fb == NULL) { return; }
  draw_number(32, 132, n, 18);
  draw_number(220, 132, within, 18);
}
/* Four values at once. One flash/photo cycle should answer several questions, so
 * every probe site can dump a small tuple instead of a single number. */
void nabu_mark_quad(int a, int b, int c, int d)
{
  if (g_fb == NULL) { return; }
  draw_number(32, 132, a, 18);
  draw_number(220, 132, b, 18);
  draw_number(32, 300, c, 18);
  draw_number(220, 300, d, 18);
}
/* Draw a value with no bookkeeping: used where the number is data, not a
 * checkpoint (e.g. the kobject type currently being registered). */
void nabu_mark_val(int v)
{
  if (g_fb == NULL) { return; }
  draw_number(32, 132, v, 20);
}
static void draw_all(void)
{
  int n;
  if (g_fb == NULL) { return; }
  fill(0, 0, g_w, 420, 0xFF000000);
  g_slot = 0;
  {
    /* Draw the newest 24 hits, not the lowest 24: with 30+ checkpoints the
     * late ones (45/46/60/...) would otherwise never appear on the strip. */
    int first = 1, total = 0;
    for (n = 1; n <= NABU_MAX_MARK; n++) {
      if (g_hits & (1ULL << (n - 1))) { total++; }
    }
    if (total > 24) {
      int seen = 0;
      for (n = 1; n <= NABU_MAX_MARK; n++) {
        if (g_hits & (1ULL << (n - 1))) {
          seen++;
          if (seen == total - 23) { first = n; break; }
        }
      }
    }
    for (n = first; n <= NABU_MAX_MARK && g_slot < 24; n++) {
      if ((g_hits & (1ULL << (n - 1))) == 0) { continue; }
      fill(32 + (unsigned int)g_slot * 64, 32, 48, 48, g_palette[(n - 1) & 7]);
      g_slot++;
    }
  }
  /* two large digits under the strip: "12" means checkpoint 12 was the last hit */
  draw_number(32, 132, max_hit(), 20);
}
/* Replay through an address the caller already knows is kernel-virtual. */
void nabu_mark_rebind(const unsigned long *v)
{
  int geom = set_geom(v);
  if (geom == 0) { return; }
  draw_all();
  if (geom == 2 || (v[5] & 0xFF) != 32) { fill(32 + 7 * 64, 32, 48, 48, 0xFFFF0000); }
}
/* Map the video aperture with the kernel's own io_map. vcattach is not reached until
 * kernel_bootstrap (PE_init_iokit), so before this call the physical base address is
 * unmapped and every store to it faults. Call after arm_vm_init. */
void nabu_mark_map(unsigned long pbase, unsigned long row, unsigned long w, unsigned long h)
{
  vm_offset_t va;
  unsigned long size;

  if (pbase == 0 || row < 4 || row > 65536 || w == 0 || w > 8192 || h == 0 || h > 8192) { return; }
  size = row * h;
  if (size == 0) { return; }
  va = ml_io_map_unmappable((vm_map_offset_t)(pbase & ~0xFFFUL),
                            (vm_map_size_t)round_page(size), VM_WIMG_WCOMB);
  if (va == 0) { return; }
  g_fb = (volatile unsigned int *)(unsigned long)(va + (pbase & 0xFFFUL));
  g_px = row / 4;
  g_w = (unsigned int)w; g_h = (unsigned int)h;
  draw_all();
}

MKC
  grep -q nabu_early_mark .cache/xnu-work/osfmk/conf/files.arm64 || \
    printf 'osfmk/arm/nabu_early_mark.c\tstandard\n' >> .cache/xnu-work/osfmk/conf/files.arm64
  python3 - .cache/xnu-work/osfmk/arm/arm_init.c .cache/xnu-work/osfmk/console/video_console.c .cache/xnu-work/osfmk/kern/startup.c .cache/xnu-work/pexpert/arm/pe_init.c .cache/xnu-work/osfmk/kern/ipc_kobject.c .cache/xnu-work/osfmk/arm64/sleh.c <<'MKP'
import io,re,sys
p=sys.argv[1]; vcp=sys.argv[2]; stp=sys.argv[3]
s=io.open(p,encoding='utf-8').read()

def ins_before_in(txt, pat, lines, label):
    if lines[0] in txt:
        return txt
    m=re.search(pat,txt,re.M)
    if not m:
        print('  WARN: mark anchor missing (%s)'%label); return txt
    ind=m.group(1)
    return txt[:m.start()]+''.join(ind+l+'\n' for l in lines)+txt[m.start():]

def ins_after_in(txt, pat, lines, label):
    if lines[-1] in txt:
        return txt
    m=re.search(pat,txt,re.M)
    if not m:
        print('  WARN: mark anchor missing (%s)'%label); return txt
    ind=m.group(1)
    return txt[:m.end()+1]+''.join(ind+l+'\n' for l in lines)+txt[m.end()+1:]

def ins_body_start(txt, pat, lines, label):
    if lines[0] in txt:
        return txt
    m=re.search(pat,txt,re.M)
    if not m:
        print('  WARN: mark anchor missing (%s)'%label); return txt
    return txt[:m.end()]+''.join('\t'+l+'\n' for l in lines)+txt[m.end():]

def add_include(txt, anchor):
    if '#include <arm/nabu_early_mark.h>' in txt:
        return txt
    if anchor in txt:
        return txt.replace(anchor, anchor+'\n#include <arm/nabu_early_mark.h>', 1)
    m0=re.search(r'^#include [<"][^\n]*$',txt,re.M)
    if m0:
        print('  note: include after first #include')
        return txt[:m0.end()]+'\n#include <arm/nabu_early_mark.h>'+txt[m0.end():]
    print('  WARN: no include anchor')
    return txt

s = add_include(s, '#include <pexpert/arm/consistent_debug.h>')
s = ins_before_in(s, r'^([ \t]*)arm_setup_pre_sign\(\);',
      ['nabu_mark_init((const unsigned long *)&args->Video);','NABU_MARK(1);'], 'arm_init entry')
s = ins_before_in(s, r'^([ \t]*)PE_init_platform\(FALSE,[ \t]*args\);', ['NABU_MARK(2);'], 'PE_init_platform')
s = ins_after_in(s, r'^([ \t]*)arm_vm_init\(xmaxmem,[ \t]*args\);',
      ['nabu_mark_map(args->Video.v_baseAddr, args->Video.v_rowBytes, args->Video.v_width, args->Video.v_height);',
       'NABU_MARK(6);',
       # Console as early as it can work. vcattach() is otherwise only reached from
       # PE_init_iokit(), which runs after the mach-IPC round -- precisely the region
       # that stays invisible. The kernel pmap exists by now, so this maps the
       # framebuffer and every later kprintf, panic text included, reaches the panel.
       'PE_init_printf(TRUE); /* UNIXNU: early screen console */'], 'arm_vm_init')
s = ins_before_in(s, r'^([ \t]*)PE_create_console\(\);', ['NABU_MARK(3);'], 'PE_create_console before')
s = ins_after_in(s, r'^([ \t]*)PE_create_console\(\);', ['NABU_MARK(4);'], 'PE_create_console after')
s = ins_after_in(s, r'^([ \t]*)PE_init_platform\(TRUE,[ \t]*&BootCpuData\);', ['NABU_MARK(5);'], 'PE_init_platform TRUE')
s = ins_before_in(s, r'^([ \t]*)machine_startup\(args\);', ['NABU_MARK(7);'], 'machine_startup')
io.open(p,'w',encoding='utf-8',newline='').write(s)

vc=io.open(vcp,encoding='utf-8').read()
if 'nabu_mark_rebind' not in vc:
    vc=add_include(vc, '#include <pexpert/pexpert.h>')
    m=re.search(r'^vcattach\(void\)\n\{\n',vc,re.M)
    if m:
        if 'NABU_MARK(11)' not in vc:
            vc=vc[:m.end()]+'\tNABU_MARK(11);\n'+vc[m.end():]
            m=re.search(r'^vcattach\(void\)\n\{\n',vc,re.M)
        i=m.end(); depth=1
        while i<len(vc) and depth>0:
            if vc[i]=='{': depth+=1
            elif vc[i]=='}': depth-=1
            i+=1
        ins=('\t/* nabu: vcattach just mapped the framebuffer; replay the checkpoints. */\n'
             '\tif ((unsigned long)PE_state.video.v_baseAddr >= 0xFFFFFFF000000000UL) {\n'
             '\t\tnabu_mark_rebind((const unsigned long *)&PE_state.video);\n'
             '\t}\n')
        vc=vc[:i-1]+ins+vc[i-1:]
        print('  rebind hooked at the end of vcattach')
    else:
        print('  WARN: vcattach anchor missing')
    vc=ins_after_in(vc, r'^([ \t]*)initialize_screen\(NULL,[ \t]*kPEAcquireScreen\);',
                    ['NABU_MARK(12);'], 'initialize_screen acquire')
    io.open(vcp,'w',encoding='utf-8',newline='').write(vc)

pep=sys.argv[4]
pe=io.open(pep,encoding='utf-8').read()
# pexpert/arm is compiled without the osfmk include root, so <arm/...> does not resolve
# there; a quoted relative include from pexpert/arm to osfmk/arm always does.
if '#include "../../osfmk/arm/nabu_early_mark.h"' not in pe:
    m0=re.search(r'^#include [<"][^\n]*$',pe,re.M)
    if m0:
        pe=pe[:m0.end()]+'\n#include "../../osfmk/arm/nabu_early_mark.h"'+pe[m0.end():]
    else:
        print('  WARN: pe_init.c has no include line')
pe=ins_body_start(pe, r'^PE_init_iokit\(void\)\n\{\n', ['NABU_MARK(10);'], 'PE_init_iokit entry')
pe=ins_after_in(pe, r'^([ \t]*)PE_init_printf\(TRUE\);', ['NABU_MARK(13);'], 'PE_init_printf TRUE')
io.open(pep,'w',encoding='utf-8',newline='').write(pe)

kop=sys.argv[5]
ko=io.open(kop,encoding='utf-8').read()
# The mig descriptors generated for this build carry no reply size for some mach_vm
# routines (mach_vm_allocate is the first one hit), and mig_init turns that into a
# panic. Fall back to the subsystem's advertised max reply size so the boot can
# continue; the value is conservative, not exact.
_old_panic = 'panic("kroutine must have precise size %d %d", mig_e[i]->start, j);'
_new_fallback = ('/* UNIXNU: this descriptor lost its reply size and its layout */\n'
                 '\t\t\t\t\t/* cannot be trusted either (reading reply_descr_count here */\n'
                 '\t\t\t\t\t/* faults). Advertise the subsystem maximum and leave the */\n'
                 '\t\t\t\t\t/* descriptor counts at zero. */\n'
                 '\t\t\t\t\tmig_buckets[pos].kreply_size = mig_e[i]->maxsize;')
if _old_panic in ko:
    ko = ko.replace(_old_panic, _new_fallback, 1)
    print('  mig: kroutine size panic replaced with maxsize fallback')
else:
    print('  mig: WARN kroutine panic anchor not found')
# mig_init ends with a diagnostics printf. kprintf before the console exists is a
# fault, which is why the boot still stopped right after the kroutine fallback
# stopped panicking. The line is informational only.
_old_printf = ('\tprintf("mig_table_max_displ = %d mach_kobj_count = %d\\n",\n'
               '\t    mig_table_max_displ, mach_kobj_count);')
_new_printf = ('\t/* UNIXNU: diagnostics only; kprintf before the console is a fault. */')
if _old_printf in ko:
    ko = ko.replace(_old_printf, _new_printf, 1)
    print('  mig: trailing diagnostics printf removed')
else:
    print('  mig: WARN trailing printf anchor not found')
# mig_init stores into mig_buckets and register_startup stores into
# ipc_kobject_ops_array; both are SECURITY_READ_ONLY_LATE, i.e. __DATA_CONST, which
# this kernel has already locked read-only by the time the mach-IPC round runs. Every
# store faults, which is why the counter never leaves 0 and why "31 registrations
# succeeded" never showed up. Drop the hardening for these two tables.
for _old, _new in (
        ('static SECURITY_READ_ONLY_LATE(mig_hash_t) mig_buckets[MAX_MIG_ENTRIES];',
         'static mig_hash_t mig_buckets[MAX_MIG_ENTRIES];'),
        ('static struct ipc_kobject_ops __security_const_late\n    ipc_kobject_ops_array[IKOT_MAX_TYPE];',
         'static struct ipc_kobject_ops\n    ipc_kobject_ops_array[IKOT_MAX_TYPE];'),
):
    if _old in ko:
        ko = ko.replace(_old, _new, 1)
        print('  writable: %s' % _new.split('[')[0].strip()[-30:])
    else:
        print('  WARN hardening anchor not found')
io.open(kop,'w',encoding='utf-8',newline='').write(ko)

# Exception-vector hold: every synchronous exception enters sleh_synchronous_sp1 with
# esr and far already decoded by hardware. A kernel abort gets its trap data painted
# and then spins, so the panel keeps the scene instead of losing it on reboot. Only
# abort classes are trapped; SVC/BRK/MSR traps must keep flowing.
slc=sys.argv[6]
sl=io.open(slc,encoding='utf-8').read()
if 'nabu_abort_hold' not in sl:
    sl=add_include(sl, '#include <pexpert/pexpert.h>')
    _hold = ('\t/* nabu_abort_hold: kernel abort -> paint ESR/FAR and stop here. */\n'
             '\t{\n'
             '\t\tuint32_t _ec = (esr >> 26) & 0x3F;\n'
             '\t\tif (_ec == 0x24 || _ec == 0x25 || _ec == 0x20 || _ec == 0x21) {\n'
             '\t\t\tnabu_mark_quad((int)_ec,\n'
             '\t\t\t    (int)((far >> 12) & 0xFF),\n'
             '\t\t\t    (int)((far >> 20) & 0xFF),\n'
             '\t\t\t    (int)((far >> 28) & 0xFF));\n'
             '\t\t\tfor (;;) { __asm__ __volatile__("nop"); }\n'
             '\t\t}\n'
             '\t}\n')
    sl = ins_body_start(sl, r'^sleh_synchronous_sp1\(arm_context_t \*context, uint32_t esr, vm_offset_t far __unused\)\n\{\n',
                        [_hold], 'sleh abort hold')
    io.open(slc,'w',encoding='utf-8',newline='').write(sl)
ko=io.open(kop,encoding='utf-8').read()
ko=add_include(ko, '#include <pexpert/pexpert.h>')
# Show the kobject type being registered: the value on screen when it dies is the
# type that was registered twice (that panic is the only one in this function).
# Bisect inside the call: if block 60 ever appears, the function did return at
# least once, so the fault is not in the store itself.
ko=ins_after_in(ko, r'^([ \t]*)ipc_kobject_ops_array\[ops->iko_op_type\] = \*ops;',
                ['NABU_MARK(60);'], 'kobject register returned')
# 77 on screen means the "already registered" test read a non-zero garbage type,
# i.e. the ops array was never zeroed rather than a genuine double registration.
ko=ins_before_in(ko, r'^([ \t]*)panic\("trying to register kobject',
                 ['nabu_mark_val(77);'], 'kobject duplicate panic')
# mig_init() has five different panics; tag each so the panel names the one taken.
for _num, _pat, _lbl in (
    (71, r'^([ \t]*)panic\("the msgh_ids in mig_e\[\] aren.t valid!"\);', 'mig ids invalid'),
    (72, r'^([ \t]*)panic\("mig subsystem %d \(%p\) replies are too large', 'mig reply too large'),
    (73, r'^([ \t]*)panic\("multiple entries with the same msgh_id"\);', 'mig duplicate id'),
    (74, r'^([ \t]*)panic\("the mig dispatch table is too small"\);', 'mig table too small'),
    (75, r'^([ \t]*)panic\("kroutine must have precise size', 'mig kroutine size'),
):
    ko = ins_before_in(ko, _pat, ['nabu_mark_val(%d);' % _num], _lbl)
# Progress inside mig_init: i (subsystem), n (count), mach_kobj_count (entries
# registered so far). If the panel freezes with a constant count, the inner bucket
# probe loop is spinning rather than faulting.
ko = ins_after_in(ko, r'^([ \t]*)for \(i = 0; i < n; i\+\+\) \{',
                  ['nabu_mark_quad((int)i, (int)n, (int)mach_kobj_count, 0);'],
                  'mig loop progress')
# One quad on the kroutine panic: i, j, msgid, and the stub address low bits.
# Together they name the exact routine without another build.
ko = ins_before_in(ko, r'^([ \t]*)panic\("kroutine must have precise size',
                   ['nabu_mark_quad((int)i, (int)j, (int)((mig_e[i]->start + j) % 100),'
                    ' (int)((((unsigned long)mig_e[i]->kroutine[j].kstub_routine) >> 4) & 0x3F));'],
                   'mig kroutine quad')

# 81 immediately before the store, 60 immediately after it: the pair says whether
# the fault is the store itself or something after it returned.
ko=ins_before_in(ko, r'^([ \t]*)ipc_kobject_ops_array\[ops->iko_op_type\] = \*ops;',
                 ['nabu_mark_val(81);'], 'before kobject store')
io.open(kop,'w',encoding='utf-8',newline='').write(ko)

st=io.open(stp,encoding='utf-8').read()
st=add_include(st, '#include <pexpert/pexpert.h>')
st=ins_body_start(st, r'^kernel_bootstrap\(void\)\n\{\n', ['NABU_MARK(8);'], 'kernel_bootstrap')
# kernel_startup_initialize_upto() walks the __startup table and calls each entry.
# Show the subsystem id of the entry being run: whatever is on screen when it dies
# is the subsystem that faulted.
st=ins_before_in(st, r'^([ \t]*)while \(cur < startup_entries_end && cur->subsystem <= upto\) \{$',
                 ['NABU_MARK(50);'], 'startup loop entry')
st=ins_after_in(st, r'^([ \t]*)cur->func\(cur->arg\);',
                ['nabu_mark_show((int)cur->subsystem);'], 'startup entry done')
# Identify the entry itself: bits 6..11 of the function address, 0..63. Matches the
# static table so the value on screen names the function that faulted.
st=ins_before_in(st, r'^([ \t]*)cur->func\(cur->arg\);',
                 ['nabu_mark_val((int)((((unsigned long)cur->func) >> 6) & 0x3F));'],
                 'startup entry id')
# The digits said 26 (mac_policy_init) but 27 (PMAP_ACTIVATE_KERNEL) never came.
# Split the ten lines in between: 45 = mac_policy_init returned, 46 = mach_ipc done.
st=ins_after_in(st, r'^([ \t]*)mac_policy_init\(\);', ['NABU_MARK(45);'], 'mac_policy_init done')
st=ins_after_in(st, r'^([ \t]*)kernel_startup_initialize_upto\(STARTUP_SUB_MACH_IPC\);',
                ['NABU_MARK(46);'], 'mach_ipc done')
# Auto-number every kernel_bootstrap log site. The log calls already trace the
# phases, so each one doubles as a checkpoint and the digits name the exact line
# the boot stops after.
mfn=re.search(r'^kernel_bootstrap\(void\)\n\{\n',st,re.M)
if mfn and 'NABU_MARK(18);' in st:
    print('  auto marks already present')
elif mfn:
    i=mfn.end(); depth=1; j=i
    while j<len(st) and depth>0:
        if st[j]=='{': depth+=1
        elif st[j]=='}': depth-=1
        j+=1
    body=st[i:j-1]
    counter=[17]
    def _mark(mo):
        counter[0]+=1
        return mo.group(0)+'\n'+mo.group(1)+'NABU_MARK(%d);'%counter[0]
    body=re.sub(r'^([ \t]*)kernel_bootstrap(?:_thread)?_log\("[^"]*"\);', _mark, body, flags=re.M)
    st=st[:i]+body+st[j-1:]
    print('  auto marks in kernel_bootstrap: %d' % (counter[0]-17))
else:
    print('  WARN: kernel_bootstrap body not found')
st=ins_after_in(st, r'^([ \t]*)PE_init_iokit\(\);', ['NABU_MARK(9);'], 'PE_init_iokit')
io.open(stp,'w',encoding='utf-8',newline='').write(st)

print('  marks placed: 1..9, map=%s' % ('nabu_mark_map(' in s))
MKP
fi
# --- end nabu markers ---
export XNU_AVAILABILITY_PL=$ROOT/.cache/fakeroot/usr/local/libexec/availability.pl
python3 scripts/prepare-xnu-source.py
# Fix: IORPC.h guards IORPCMessageFromMach with #ifndef KERNEL, but mig-generated
# DriverKit C++ in kernel builds calls it. Re-declare it after the guard closes.
IORPCH=.cache/xnu-work/iokit/DriverKit/IORPC.h
if [ -f "$IORPCH" ] && ! grep -q "UNIXNU_KERNEL_DECL" "$IORPCH"; then
  cp "$IORPCH" "$IORPCH.bak"
  python3 - "$IORPCH" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
decl = "\n/* UNIXNU_KERNEL_DECL: mig-generated DriverKit C++ calls this; kernel has no user-space impl */\n#if KERNEL\nstatic inline IORPCMessage * IORPCMessageFromMach(IORPCMessageMach * msg, bool reply) { (void)reply; return (IORPCMessage *)msg; }\n#endif\n"
anchor = "IORPCMessageFromMach(IORPCMessageMach * msg, bool reply);"
i = s.find(anchor)
if i < 0:
    print("anchor missing"); sys.exit(1)
j = s.find("#endif /* KERNEL */", i)
if j < 0:
    print("endif missing"); sys.exit(1)
k = j + len("#endif /* KERNEL */")
s = s[:k] + decl + s[k:]
open(p, "w").write(s)
print("patched IORPC.h at offset", k)
PYEOF
fi
# Fix: mig-generated OSObject.iig.cpp references IORPCMessageFromMach; make sure the
# generated header chain can see it by force-including IORPC.h into OSObject.iig itself.
OSOBJ=.cache/xnu-work/iokit/DriverKit/OSObject.iig
if [ -f "$OSOBJ" ] && ! grep -q 'DriverKit/IORPC.h' "$OSOBJ"; then
  printf '#include <DriverKit/IORPC.h>\n' | cat - "$OSOBJ" > "$OSOBJ.tmp" && mv "$OSOBJ.tmp" "$OSOBJ"
  echo "patched: prepended IORPC.h to OSObject.iig"
fi

BOOT_PROGRESS=${XNU_BOOT_PROGRESS:-0}
if [ "$BOOT_PROGRESS" != 0 ] && [ "$BOOT_PROGRESS" != 1 ]; then
  echo 'XNU_BOOT_PROGRESS must be 0 or 1' >&2
  exit 1
fi
if [ "$BOOT_PROGRESS" = 1 ]; then
  # ponytail: kits/sheng is a self-contained framebuffer logger, so it no longer
  # requires the UFS/owner-root/Virtio/corecrypto diagnostic build.
  python3 scripts/build-boot-progress.py
fi
python3 - "$BOOT_PROGRESS" <<'PY'
from pathlib import Path
import hashlib, sys
mode = sys.argv[1]
out = Path('build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837')
stamp = out / '.boot-progress-mode'
identity = mode + ':' + (hashlib.sha256(Path('build/boot-progress/libBootProgress.a').read_bytes()).hexdigest() if mode == '1' else 'disabled')
if not stamp.exists() or stamp.read_text() != identity:
    for directory, names in [('osfmk', ['arm_init','startup','video_console','serial_console','sleh']),
                             ('bsd', ['bsd_init','kern_exec','kern_exit']), ('pexpert', ['pe_kprintf'])]:
        for name in names:
            (out / directory / 'DEVELOPMENT' / (name + '.o')).unlink(missing_ok=True)
    (out / 'mach.development.bcm2837.unstripped.noctf').unlink(missing_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    stamp.write_text(identity)
PY
if [ ! -d refer/libplatform/.git ]; then
  git clone --depth 1 --branch "$LIBPLATFORM_TAG" https://github.com/apple-oss-distributions/libplatform.git refer/libplatform
fi
export KERNEL_SDKROOT=$ROOT/.cache/fakeroot
mkdir -p "$KERNEL_SDKROOT/usr/local/include/kernel" "$ROOT/build/xnu/obj/EXPORT_HDRS/libsa"
ditto refer/libplatform/include "$KERNEL_SDKROOT/usr/local/include"
ditto refer/libplatform/private "$KERNEL_SDKROOT/usr/local/include"
ditto refer/libplatform/private/platform "$KERNEL_SDKROOT/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform"
if [ ! -d refer/libdispatch/.git ]; then
  git clone --depth 1 --branch "$LIBDISPATCH_TAG" https://github.com/apple-oss-distributions/libdispatch.git refer/libdispatch
fi
python3 - <<'PY'
from pathlib import Path
import subprocess
output = Path('.cache/fakeroot/usr/local/include/os')
output.mkdir(parents=True, exist_ok=True)
for header in Path('refer/libdispatch/os').glob('*.h'):
    result = subprocess.run(['unifdef', '-DKERNEL=1', '-DOS_FIREHOSE_SPI=1',
                             '-DOS_VOUCHER_ACTIVITY_SPI_TYPES=1',
                             '-UOS_VOUCHER_ACTIVITY_SPI', str(header)], capture_output=True)
    if result.returncode not in (0, 1):
        raise SystemExit(result.stderr.decode())
    target = output / header.name
    if not target.exists() or target.read_bytes() != result.stdout:
        target.write_bytes(result.stdout)
PY
if [ ! -f "$KERNEL_SDKROOT/.xnu-$XNU_VERSION-headers" ]; then
  make -C .cache/xnu-work installhdrs SDKROOT=macosx ARCH_CONFIGS=ARM64 \
    MACHINE_CONFIGS=BCM2837 KERNEL_CONFIGS=DEVELOPMENT \
    RC_DARWIN_KERNEL_VERSION="$XNU_DARWIN" RC_ProjectSourceVersion="$XNU_VERSION" \
    MAKEJOBS=-j"${JOBS:-4}" OBJROOT="$ROOT/build/xnu/obj" \
    SYMROOT="$ROOT/build/xnu/sym" DSTROOT="$KERNEL_SDKROOT"
  touch "$KERNEL_SDKROOT/.xnu-$XNU_VERSION-headers"
fi
if [ ! -f "$KERNEL_SDKROOT/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
  bash scripts/build-firehose.sh
fi
# The baseline builds the kernel; `all` also checks the Apple kext export ABI.
EXTRA_MAKE_ARGS=()
ARM_DT_PLATFORM=${XNU_ARM_DT_PLATFORM:-0}
if [ "$ARM_DT_PLATFORM" != 0 ] && [ "$ARM_DT_PLATFORM" != 1 ]; then
  echo 'XNU_ARM_DT_PLATFORM must be 0 or 1' >&2
  exit 1
fi
if [ "${XNU_ARMCPU:-0}" = 1 ] && { [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ] || \
     { [ "${XNU_ARMVIRT_PLATFORM:-0}" != 1 ] && [ "$ARM_DT_PLATFORM" != 1 ]; }; }; then
  echo 'ArmCpu bring-up requires the real source provider and a real platform driver' >&2
  exit 1
fi
if [ "${XNU_SOURCE_PTHREAD:-0}" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The current pthread source-link recipe requires XNU_SOURCE_CORECRYPTO14=1' >&2
  exit 1
fi
CRYPTO_BOOTSTRAP_MODE=${XNU_CRYPTO_BOOTSTRAP:-source}
if [ "$CRYPTO_BOOTSTRAP_MODE" != source ] && [ "$CRYPTO_BOOTSTRAP_MODE" != prelinked ]; then
  echo 'XNU_CRYPTO_BOOTSTRAP must be source or prelinked' >&2
  exit 1
fi
CRYPTO_OBJECT_DIR=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/osfmk/DEVELOPMENT
if [ -d "$CRYPTO_OBJECT_DIR" ]; then
  if [ "$(cat "$CRYPTO_OBJECT_DIR/.crypto-bootstrap-mode" 2>/dev/null || echo source)" != "$CRYPTO_BOOTSTRAP_MODE" ]; then
    rm -f "$CRYPTO_OBJECT_DIR/prng_random.o"
  fi
  printf '%s\n' "$CRYPTO_BOOTSTRAP_MODE" > "$CRYPTO_OBJECT_DIR/.crypto-bootstrap-mode"
fi
if [ "$CRYPTO_BOOTSTRAP_MODE" = prelinked ]; then
  # The original component must initialize through real OSKext startup.
  # Only this source-provider entry is omitted; no POST or missing-provider
  # failure is suppressed, and no replacement crypto callbacks are supplied.
  EXTRA_MAKE_ARGS+=("prng_random.o_CFLAGS_ADD=-UXNU_SOURCE_CORECRYPTO14")
else
  EXTRA_MAKE_ARGS+=("prng_random.o_CFLAGS_ADD=")
fi
if [ "${XNU_NATIVE_AES:-0}" = 1 ]; then
  if [ "$CRYPTO_BOOTSTRAP_MODE" != prelinked ] || [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
    echo 'NativeAES currently requires the qualified original AES/crypto prelink closure' >&2
    exit 1
  fi
  PERSONALITY_CFLAGS=-DXNU_NATIVE_AES=1
else
  PERSONALITY_CFLAGS=
fi
if [ "${XNU_NATIVE_VIRTIO_BLOCK:-0}" = 1 ]; then
  if [ "${XNU_NATIVE_AES:-0}" != 1 ]; then
    echo 'NativeVirtioBlock currently requires the qualified NativeAES/original-storage prelink baseline' >&2
    exit 1
  fi
  PERSONALITY_CFLAGS="$PERSONALITY_CFLAGS -DXNU_NATIVE_VIRTIO_BLOCK=1"
fi
NATIVE_RAM_BLOCK=${XNU_NATIVE_RAM_BLOCK:-0}
if [ "$NATIVE_RAM_BLOCK" != 0 ] && [ "$NATIVE_RAM_BLOCK" != 1 ]; then
  echo 'XNU_NATIVE_RAM_BLOCK must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_RAM_BLOCK" = 1 ]; then
  if [ "${XNU_NATIVE_AES:-0}" != 1 ]; then
    echo 'NativeRamBlock requires the qualified original storage/AES prelink closure' >&2
    exit 1
  fi
  PERSONALITY_CFLAGS="$PERSONALITY_CFLAGS -DXNU_NATIVE_RAM_BLOCK=1"
fi
if [ "${XNU_NATIVE_UFS:-0}" = 1 ]; then
  PERSONALITY_CFLAGS="$PERSONALITY_CFLAGS -DXNU_NATIVE_UFS=1"
fi
NATIVE_VIRTIO_CONSOLE=${XNU_NATIVE_VIRTIO_CONSOLE:-0}
if [ "$NATIVE_VIRTIO_CONSOLE" != 0 ] && [ "$NATIVE_VIRTIO_CONSOLE" != 1 ]; then
  echo 'XNU_NATIVE_VIRTIO_CONSOLE must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_VIRTIO_CONSOLE" = 1 ]; then
  PERSONALITY_CFLAGS="$PERSONALITY_CFLAGS -DXNU_NATIVE_VIRTIO_CONSOLE=1"
fi
EXTRA_MAKE_ARGS+=("KernelConfigTables.cpo_CFLAGS_ADD=$PERSONALITY_CFLAGS")
TRUST_CACHE_MODE=${XNU_TRUST_CACHE_RUNTIME:-0}
if [ "$TRUST_CACHE_MODE" != 0 ] && [ "$TRUST_CACHE_MODE" != 1 ]; then
  echo 'XNU_TRUST_CACHE_RUNTIME must be 0 or 1' >&2
  exit 1
fi
if [ -d "$CRYPTO_OBJECT_DIR" ]; then
  if [ "$(cat "$CRYPTO_OBJECT_DIR/.trust-cache-mode" 2>/dev/null || echo 0)" != "$TRUST_CACHE_MODE" ]; then
    rm -f "$CRYPTO_OBJECT_DIR/startup.o"
  fi
  printf '%s\n' "$TRUST_CACHE_MODE" > "$CRYPTO_OBJECT_DIR/.trust-cache-mode"
fi
EXTRA_MAKE_ARGS+=("startup.o_CFLAGS_ADD=-DXNU_NATIVE_TRUST_CACHE=$TRUST_CACHE_MODE")
MOCKFS_MODE=${XNU_SOURCE_MOCKFS:-0}
if [ "$MOCKFS_MODE" != 0 ] && [ "$MOCKFS_MODE" != 1 ]; then
  echo 'XNU_SOURCE_MOCKFS must be 0 or 1' >&2
  exit 1
fi
# The bootstrap pass forces ARMCPU/pthread off to collect compile records, so enforce
# this only in the pass that links.
if [ "$MOCKFS_MODE" = 1 ] && [ -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/osfmk/DEVELOPMENT/startup.o.json" ] && { [ "${XNU_ARMCPU:-0}" != 1 ] || [ "${XNU_SOURCE_PTHREAD:-0}" != 1 ]; }; then
  echo 'The offline executable-root fixture requires the real CPU/pthread components' >&2
  exit 1
fi
MOCKFS_OBJECT_DIR=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT
if [ -d "$MOCKFS_OBJECT_DIR" ]; then
  if [ "$(cat "$MOCKFS_OBJECT_DIR/.source-mockfs-mode" 2>/dev/null || echo 0)" != "$MOCKFS_MODE" ]; then
    rm -f "$MOCKFS_OBJECT_DIR/vfs_conf.o"
  fi
  printf '%s\n' "$MOCKFS_MODE" > "$MOCKFS_OBJECT_DIR/.source-mockfs-mode"
fi
EXTRA_MAKE_ARGS+=("vfs_conf.o_CFLAGS_ADD=-DMOCKFS=$MOCKFS_MODE")
CS_HASH_CACHE_MODE=${XNU_NATIVE_CS_HASH_CACHE:-0}
if [ "$CS_HASH_CACHE_MODE" != 0 ] && [ "$CS_HASH_CACHE_MODE" != 1 ]; then
  echo 'XNU_NATIVE_CS_HASH_CACHE must be 0 or 1' >&2
  exit 1
fi
if [ -d "$MOCKFS_OBJECT_DIR" ]; then
  if [ "$(cat "$MOCKFS_OBJECT_DIR/.native-cs-hash-cache-mode" 2>/dev/null || echo 0)" != "$CS_HASH_CACHE_MODE" ]; then
    rm -f "$MOCKFS_OBJECT_DIR/ubc_subr.o"
  fi
  printf '%s\n' "$CS_HASH_CACHE_MODE" > "$MOCKFS_OBJECT_DIR/.native-cs-hash-cache-mode"
fi
EXTRA_MAKE_ARGS+=("ubc_subr.o_CFLAGS_ADD=-DXNU_NATIVE_CS_HASH_CACHE=$CS_HASH_CACHE_MODE")
EXTRA_CFLAGS=${XNU_EXTRA_CFLAGS:--Wno-reserved-identifier -Wno-pre-c11-compat -Wno-missing-designated-field-initializers -Wno-suggest-override -Wno-unnecessary-virtual-specifier -Wno-suggest-destructor-override -Wno-ms-bitfield-padding}
OWNER_ROOT_PROBE=${XNU_VERIFIED_ROOT_PROBE:-0}
if [ "$OWNER_ROOT_PROBE" != 0 ] && [ "$OWNER_ROOT_PROBE" != 1 ]; then
  echo 'XNU_VERIFIED_ROOT_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_ROOT_PROBE" = 1 ] && { [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ] || [ "${XNU_CRYPTO_BOOTSTRAP:-source}" != prelinked ]; }; then
  echo 'The owner crypto probe requires the qualified original prelinked crypto provider' >&2
  exit 1
fi
OWNER_ROOT_AUDIT=${XNU_OWNER_ROOT_AUDIT:-0}
if [ "$OWNER_ROOT_AUDIT" != 0 ] && [ "$OWNER_ROOT_AUDIT" != 1 ]; then
  echo 'XNU_OWNER_ROOT_AUDIT must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_ROOT_AUDIT" = 1 ] && [ "$OWNER_ROOT_PROBE" != 1 ]; then
  echo 'The root-binding audit requires real owner-verified block crypto' >&2
  exit 1
fi
OWNER_ROOT_TRUST=${XNU_OWNER_ROOT_TRUST:-0}
if [ "$OWNER_ROOT_TRUST" != 0 ] && [ "$OWNER_ROOT_TRUST" != 1 ]; then
  echo 'XNU_OWNER_ROOT_TRUST must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_ROOT_TRUST" = 1 ] && { [ "$OWNER_ROOT_AUDIT" != 1 ] || [ "${XNU_NATIVE_VIRTIO_BLOCK:-0}" != 1 ]; }; then
  echo 'Owner root acceptance requires actual mounted-media binding and verified block storage' >&2
  exit 1
fi
ADRENO_FIRMWARE_PROBE=${XNU_ADRENO_FIRMWARE_PROBE:-0}
if [ "$ADRENO_FIRMWARE_PROBE" != 0 ] && [ "$ADRENO_FIRMWARE_PROBE" != 1 ]; then
  echo 'XNU_ADRENO_FIRMWARE_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$ADRENO_FIRMWARE_PROBE" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The offline Adreno planner probe requires the qualified crypto build' >&2
  exit 1
fi
ADRENO_PM4_PROBE=${XNU_ADRENO_PM4_PROBE:-0}
if [ "$ADRENO_PM4_PROBE" != 0 ] && [ "$ADRENO_PM4_PROBE" != 1 ]; then
  echo 'XNU_ADRENO_PM4_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$ADRENO_PM4_PROBE" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The offline PM4 fixture requires the qualified native kernel configuration' >&2
  exit 1
fi
SMMU4K_PROBE=${XNU_SMMU4K_PROBE:-0}
if [ "$SMMU4K_PROBE" != 0 ] && [ "$SMMU4K_PROBE" != 1 ]; then
  echo 'XNU_SMMU4K_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$SMMU4K_PROBE" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The offline native-table fixture requires the qualified kernel configuration' >&2
  exit 1
fi
CONSTANT_UPLOADS_PROBE=${XNU_CONSTANT_UPLOADS_PROBE:-0}
if [ "$CONSTANT_UPLOADS_PROBE" != 0 ] && [ "$CONSTANT_UPLOADS_PROBE" != 1 ]; then
  echo 'XNU_CONSTANT_UPLOADS_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$CONSTANT_UPLOADS_PROBE" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The offline constant upload fixture requires the qualified kernel configuration' >&2
  exit 1
fi
NATIVE_OFFLINE_GPU=${XNU_NATIVE_OFFLINE_GPU:-0}
if [ "$NATIVE_OFFLINE_GPU" != 0 ] && [ "$NATIVE_OFFLINE_GPU" != 1 ]; then
  echo 'XNU_NATIVE_OFFLINE_GPU must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_OFFLINE_GPU" = 1 ] && [ "$NATIVE_VIRTIO_CONSOLE" != 1 ]; then
  echo 'The private offline GPU broker requires the actual byte transport' >&2
  exit 1
fi
SHENG_PMGR=${XNU_SHENG_PMGR:-0}
if [ "$SHENG_PMGR" != 0 ] && [ "$SHENG_PMGR" != 1 ]; then
  echo 'XNU_SHENG_PMGR must be 0 or 1' >&2
  exit 1
fi
if [ "$SHENG_PMGR" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The sheng PMGR instrument requires the original-component kernel configuration' >&2
  exit 1
fi
SHENG_PMGR_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.sheng-pmgr-mode
if [ "$(cat "$SHENG_PMGR_STAMP" 2>/dev/null || echo 0)" != "$SHENG_PMGR" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/bsd_init.o"
  printf '%s\n' "$SHENG_PMGR" > "$SHENG_PMGR_STAMP"
fi
EXTRA_MAKE_ARGS+=("bsd_init.o_CFLAGS_ADD=-DXNU_SHENG_PMGR=$SHENG_PMGR -DXNU_VERIFIED_ROOT_PROBE=$OWNER_ROOT_PROBE -DXNU_OWNER_ROOT_AUDIT=$OWNER_ROOT_AUDIT -DXNU_OWNER_ROOT_TRUST=$OWNER_ROOT_TRUST -DXNU_ADRENO_FIRMWARE_PROBE=$ADRENO_FIRMWARE_PROBE -DXNU_ADRENO_PM4_PROBE=$ADRENO_PM4_PROBE -DXNU_SMMU4K_PROBE=$SMMU4K_PROBE -DXNU_CONSTANT_UPLOADS_PROBE=$CONSTANT_UPLOADS_PROBE -DXNU_NATIVE_LEGACY_DISPLAY=${XNU_NATIVE_LEGACY_DISPLAY:-0} -DXNU_NATIVE_OFFLINE_GPU=$NATIVE_OFFLINE_GPU")
NATIVE_MOBILE_DISPLAY=${XNU_NATIVE_MOBILE_DISPLAY:-0}
if [ "$NATIVE_MOBILE_DISPLAY" != 0 ] && [ "$NATIVE_MOBILE_DISPLAY" != 1 ]; then
  echo 'XNU_NATIVE_MOBILE_DISPLAY must be 0 or 1' >&2
  exit 1
fi
NATIVE_LEGACY_DISPLAY=${XNU_NATIVE_LEGACY_DISPLAY:-0}
if [ "$NATIVE_LEGACY_DISPLAY" != 0 ] && [ "$NATIVE_LEGACY_DISPLAY" != 1 ]; then
  echo 'XNU_NATIVE_LEGACY_DISPLAY must be 0 or 1' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("IOUserClient.cpo_CFLAGS_ADD=-DXNU_NATIVE_MOBILE_DISPLAY=$NATIVE_MOBILE_DISPLAY -DXNU_NATIVE_LEGACY_DISPLAY=$NATIVE_LEGACY_DISPLAY")
MOBILE_DISPLAY_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.native-mobile-display-mode
if [ "$(cat "$MOBILE_DISPLAY_STAMP" 2>/dev/null || echo 0)" != "$NATIVE_MOBILE_DISPLAY:$NATIVE_LEGACY_DISPLAY" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/iokit/DEVELOPMENT/IOUserClient.cpo"
  printf '%s\n' "$NATIVE_MOBILE_DISPLAY:$NATIVE_LEGACY_DISPLAY" > "$MOBILE_DISPLAY_STAMP"
fi
OWNER_ROOT_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.owner-root-probe-mode
if [ "$(cat "$OWNER_ROOT_STAMP" 2>/dev/null || echo 0:0:0:0:0:0)" != "$OWNER_ROOT_PROBE:$OWNER_ROOT_AUDIT:$OWNER_ROOT_TRUST:$ADRENO_FIRMWARE_PROBE:$ADRENO_PM4_PROBE:$SMMU4K_PROBE:$CONSTANT_UPLOADS_PROBE:$NATIVE_LEGACY_DISPLAY:$NATIVE_OFFLINE_GPU" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/bsd_init.o"
  printf '%s\n' "$OWNER_ROOT_PROBE:$OWNER_ROOT_AUDIT:$OWNER_ROOT_TRUST:$ADRENO_FIRMWARE_PROBE:$ADRENO_PM4_PROBE:$SMMU4K_PROBE:$CONSTANT_UPLOADS_PROBE:$NATIVE_LEGACY_DISPLAY:$NATIVE_OFFLINE_GPU" > "$OWNER_ROOT_STAMP"
fi
OWNER_CACHE_MOUNT=${XNU_OWNER_CACHE_MOUNT:-0}
if [ "$OWNER_CACHE_MOUNT" != 0 ] && [ "$OWNER_CACHE_MOUNT" != 1 ]; then
  echo 'XNU_OWNER_CACHE_MOUNT must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_CACHE_MOUNT" = 1 ] && [ "$OWNER_ROOT_TRUST" != 1 ]; then
  echo 'The offline SystemOS mount requires real independent owner root enforcement' >&2
  exit 1
fi
OWNER_CACHE_STARTUP=${XNU_OWNER_CACHE_STARTUP:-0}
if [ "$OWNER_CACHE_STARTUP" != 0 ] && [ "$OWNER_CACHE_STARTUP" != 1 ]; then
  echo 'XNU_OWNER_CACHE_STARTUP must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_CACHE_STARTUP" = 1 ] && [ "$OWNER_CACHE_MOUNT" != 1 ]; then
  echo 'Owner dyld startup selection requires authenticated actual cache mounting' >&2
  exit 1
fi
OWNER_BOOT_MANIFEST=${XNU_OWNER_BOOT_MANIFEST:-0}
if [ "$OWNER_BOOT_MANIFEST" != 0 ] && [ "$OWNER_BOOT_MANIFEST" != 1 ]; then
  echo 'XNU_OWNER_BOOT_MANIFEST must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_BOOT_MANIFEST" = 1 ] && [ "$OWNER_CACHE_STARTUP" != 1 ]; then
  echo 'Owner boot metadata requires real authenticated owner root/cache startup' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("IOKitBSDInit.cpo_CFLAGS_ADD=-DXNU_OWNER_BOOT_MANIFEST=$OWNER_BOOT_MANIFEST")
OWNER_MANIFEST_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.owner-boot-manifest-mode
if [ "$(cat "$OWNER_MANIFEST_STAMP" 2>/dev/null || echo 0)" != "$OWNER_BOOT_MANIFEST" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/iokit/DEVELOPMENT/IOKitBSDInit.cpo"
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_BOOT_MANIFEST" > "$OWNER_MANIFEST_STAMP"
fi
OWNER_DATA_MOUNT=${XNU_OWNER_DATA_MOUNT:-0}
if [ "$OWNER_DATA_MOUNT" != 0 ] && [ "$OWNER_DATA_MOUNT" != 1 ]; then
  echo 'XNU_OWNER_DATA_MOUNT must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_DATA_MOUNT" = 1 ] && [ "$OWNER_BOOT_MANIFEST" != 1 ]; then
  echo 'Scratch Data requires authenticated original OS/owner metadata startup' >&2
  exit 1
fi
OWNER_DATA_HEADER=$ROOT/build/xnu/owner-data-volume.h
python3 - "$OWNER_DATA_HEADER" "$OWNER_DATA_MOUNT" "$NATIVE_RAM_BLOCK" "${XNU_OWNER_DATA_VOLUME_UUID:-}" <<'PY_DATA_UUID'
from pathlib import Path
import sys
import uuid
path = Path(sys.argv[1])
text = '/* Scratch Data IOKit selection disabled. */\n'
if sys.argv[2:4] == ['1', '1']:
    try:
        value = str(uuid.UUID(sys.argv[4])).upper()
    except ValueError:
        raise SystemExit('Set XNU_OWNER_DATA_VOLUME_UUID to the actual observed scratch APFS volume UUID')
    text = '#define XNU_OWNER_DATA_VOLUME_UUID "' + value + '"\n'
path.parent.mkdir(parents=True, exist_ok=True)
if not path.exists() or path.read_text() != text:
    path.write_text(text)
PY_DATA_UUID
OWNER_DATA_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.owner-data-mount-mode
if [ "$(cat "$OWNER_DATA_STAMP" 2>/dev/null || echo 0)" != "$OWNER_DATA_MOUNT:$NATIVE_RAM_BLOCK" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_DATA_MOUNT:$NATIVE_RAM_BLOCK" > "$OWNER_DATA_STAMP"
fi
OWNER_CRYPTEX_FILES=${XNU_OWNER_CRYPTEX_FILES:-0}
if [ "$OWNER_CRYPTEX_FILES" != 0 ] && [ "$OWNER_CRYPTEX_FILES" != 1 ]; then
  echo 'XNU_OWNER_CRYPTEX_FILES must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_CRYPTEX_FILES" = 1 ] && [ "$OWNER_CACHE_STARTUP" != 1 ]; then
  echo 'Owner Cryptex file lookup requires authenticated mounted SystemOS startup' >&2
  exit 1
fi
OWNER_CRYPTEX_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.owner-cryptex-files-mode
if [ "$(cat "$OWNER_CRYPTEX_STAMP" 2>/dev/null || echo 0)" != "$OWNER_CRYPTEX_FILES" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_CRYPTEX_FILES" > "$OWNER_CRYPTEX_STAMP"
fi
OWNER_UNION_SYSTEMOS=${XNU_OWNER_UNION_SYSTEMOS:-0}
if [ "$OWNER_UNION_SYSTEMOS" != 0 ] && [ "$OWNER_UNION_SYSTEMOS" != 1 ]; then
  echo 'XNU_OWNER_UNION_SYSTEMOS must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_UNION_SYSTEMOS" = 1 ] && { [ "$OWNER_CACHE_STARTUP" != 1 ] || [ "$OWNER_CRYPTEX_FILES" != 0 ]; }; then
  echo 'Owner union composition requires authenticated startup and no fallback-path experiment' >&2
  exit 1
fi
OWNER_UNION_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.owner-union-systemos-mode
if [ "$(cat "$OWNER_UNION_STAMP" 2>/dev/null || echo 0)" != "$OWNER_UNION_SYSTEMOS" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_UNION_SYSTEMOS" > "$OWNER_UNION_STAMP"
fi
NATIVE_AIR_INIT=${XNU_NATIVE_AIR_INIT:-0}
if [ "$NATIVE_AIR_INIT" != 0 ] && [ "$NATIVE_AIR_INIT" != 1 ]; then
  echo 'XNU_NATIVE_AIR_INIT must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_AIR_INIT" = 1 ] && { [ "$OWNER_CACHE_MOUNT" != 1 ] || [ "$OWNER_DATA_MOUNT" != 1 ] || [ "$OWNER_ROOT_TRUST" != 1 ]; }; then
  echo 'Offline AIR init requires the actual owner root, SystemOS and scratch Data path' >&2
  exit 1
fi
NATIVE_AIR_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.native-air-init-mode
if [ "$(cat "$NATIVE_AIR_STAMP" 2>/dev/null || echo 0)" != "$NATIVE_AIR_INIT" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$NATIVE_AIR_INIT" > "$NATIVE_AIR_STAMP"
fi
EXTRA_MAKE_ARGS+=("kern_exec.o_CFLAGS_ADD=-DXNU_NATIVE_AIR_INIT=$NATIVE_AIR_INIT -DXNU_OWNER_CACHE_MOUNT=$OWNER_CACHE_MOUNT -DXNU_OWNER_CACHE_STARTUP=$OWNER_CACHE_STARTUP -DXNU_OWNER_BOOT_MANIFEST=$OWNER_BOOT_MANIFEST -DXNU_OWNER_DATA_MOUNT=$OWNER_DATA_MOUNT -DXNU_NATIVE_RAM_BLOCK=$NATIVE_RAM_BLOCK -DXNU_OWNER_CRYPTEX_FILES=$OWNER_CRYPTEX_FILES -DXNU_OWNER_UNION_SYSTEMOS=$OWNER_UNION_SYSTEMOS -include $OWNER_DATA_HEADER")
OWNER_CACHE_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.owner-cache-mount-mode
if [ "$(cat "$OWNER_CACHE_STAMP" 2>/dev/null || echo 0:0)" != "$OWNER_CACHE_MOUNT:$OWNER_CACHE_STARTUP" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_CACHE_MOUNT:$OWNER_CACHE_STARTUP" > "$OWNER_CACHE_STAMP"
fi
OWNER_CACHE_CARRIER=${XNU_OWNER_CACHE_CARRIER:-0}
OWNER_CACHE_CARRIER_WRONG_UUID=${XNU_OWNER_CACHE_CARRIER_WRONG_UUID:-0}
if { [ "$OWNER_CACHE_CARRIER" != 0 ] && [ "$OWNER_CACHE_CARRIER" != 1 ]; } ||
   { [ "$OWNER_CACHE_CARRIER_WRONG_UUID" != 0 ] && [ "$OWNER_CACHE_CARRIER_WRONG_UUID" != 1 ]; }; then
  echo 'Owner cache carrier selectors must be 0 or 1' >&2
  exit 1
fi
if { [ "$OWNER_CACHE_CARRIER" = 1 ] && [ "$OWNER_CACHE_STARTUP" != 1 ]; } ||
   { [ "$OWNER_CACHE_CARRIER_WRONG_UUID" = 1 ] && [ "$OWNER_CACHE_CARRIER" != 1 ]; }; then
  echo 'Owner carrier policy requires authenticated owner startup; wrong UUID is an isolated negative control' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("vm_unix.o_CFLAGS_ADD=-DXNU_OWNER_CACHE_CARRIER=$OWNER_CACHE_CARRIER -DXNU_OWNER_CACHE_CARRIER_WRONG_UUID=$OWNER_CACHE_CARRIER_WRONG_UUID")
OWNER_CARRIER_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.owner-cache-carrier-mode
if [ "$(cat "$OWNER_CARRIER_STAMP" 2>/dev/null || echo 0:0)" != "$OWNER_CACHE_CARRIER:$OWNER_CACHE_CARRIER_WRONG_UUID" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/bsd/DEVELOPMENT/vm_unix.o"
  printf '%s\n' "$OWNER_CACHE_CARRIER:$OWNER_CACHE_CARRIER_WRONG_UUID" > "$OWNER_CARRIER_STAMP"
fi
DT_PANIC_REGION=${XNU_DT_PANIC_REGION:-0}
if [ "$DT_PANIC_REGION" != 0 ] && [ "$DT_PANIC_REGION" != 1 ]; then
  echo 'XNU_DT_PANIC_REGION must be 0 or 1' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("pe_init.o_CFLAGS_ADD=-DXNU_DT_PANIC_REGION=$DT_PANIC_REGION")
DT_PANIC_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.dt-panic-region-mode
if [ "$(cat "$DT_PANIC_STAMP" 2>/dev/null || echo 0)" != "$DT_PANIC_REGION" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/pexpert/DEVELOPMENT/pe_init.o"
  printf '%s\n' "$DT_PANIC_REGION" > "$DT_PANIC_STAMP"
fi
ZONE_PGZ_PROBE=${XNU_ZONE_PGZ_ALIGNMENT_PROBE:-0}
if [ "$ZONE_PGZ_PROBE" != 0 ] && [ "$ZONE_PGZ_PROBE" != 1 ]; then
  echo 'XNU_ZONE_PGZ_ALIGNMENT_PROBE must be 0 or 1' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("zalloc.o_CFLAGS_ADD=-DXNU_ZONE_PGZ_ALIGNMENT_PROBE=$ZONE_PGZ_PROBE")
ZONE_PGZ_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.zone-pgz-probe-mode
if [ "$(cat "$ZONE_PGZ_STAMP" 2>/dev/null || echo 0)" != "$ZONE_PGZ_PROBE" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/osfmk/DEVELOPMENT/zalloc.o"
  printf '%s\n' "$ZONE_PGZ_PROBE" > "$ZONE_PGZ_STAMP"
fi
NATIVE_ARCH_TIMER=${XNU_NATIVE_ARCH_TIMER:-${XNU_ARMCPU:-0}}
if [ "$NATIVE_ARCH_TIMER" != 0 ] && [ "$NATIVE_ARCH_TIMER" != 1 ]; then
  echo 'XNU_NATIVE_ARCH_TIMER must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_ARCH_TIMER" = 1 ] && [ "${XNU_ARMCPU:-0}" != 1 ]; then
  echo 'Architectural timer entry requires the actual ArmCpu interrupt provider' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("start.o_SFLAGS_ADD=-DXNU_NATIVE_ARCH_TIMER=$NATIVE_ARCH_TIMER")
NATIVE_TIMER_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/.native-arch-timer-mode
if [ "$(cat "$NATIVE_TIMER_STAMP" 2>/dev/null || echo 0)" != "$NATIVE_ARCH_TIMER" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/osfmk/DEVELOPMENT/start.o"
  printf '%s\n' "$NATIVE_ARCH_TIMER" > "$NATIVE_TIMER_STAMP"
fi
NATIVE_PAN=${XNU_NATIVE_PAN:-0}
if [ "$NATIVE_PAN" != 0 ] && [ "$NATIVE_PAN" != 1 ]; then
  echo 'XNU_NATIVE_PAN must be 0 or 1' >&2
  exit 1
fi
EXTRA_CFLAGS="$EXTRA_CFLAGS -DXNU_NATIVE_PAN=$NATIVE_PAN"
if [ "$NATIVE_PAN" = 1 ]; then
  EXTRA_MAKE_ARGS+=("copyio.o_CFLAGS_ADD=-march=armv8.1-a")
  EXTRA_MAKE_ARGS+=("pcb.o_CFLAGS_ADD=-march=armv8.1-a")
  EXTRA_MAKE_ARGS+=("platform_tests.o_CFLAGS_ADD=-march=armv8.1-a")
else
  EXTRA_MAKE_ARGS+=("copyio.o_CFLAGS_ADD=")
  EXTRA_MAKE_ARGS+=("pcb.o_CFLAGS_ADD=")
  EXTRA_MAKE_ARGS+=("platform_tests.o_CFLAGS_ADD=")
fi
# The driver builds the board archives between its two passes, but a cold tree
# can reach the link without them. Build the ones the defconfig enables here,
# but only once the compile records exist (the builders read them).
RECORDS=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/osfmk/DEVELOPMENT/startup.o.json
ensure_archive() {
  [ -f "$1" ] && return 0
  [ -f "$RECORDS" ] || return 0
  shift
  echo "building missing archive: $*"
  ( cd "$ROOT/scripts" && python3 "$@" ) || true
}
if [ "${XNU_SOURCE_CORECRYPTO14:-0}" = 1 ]; then
  CRYPTO_ARCHIVE=$ROOT/build/corecrypto-2023/libcorecrypto_kernel_noasm-namespaced.a
  if [ ! -f "$CRYPTO_ARCHIVE" ]; then
    ensure_archive "$CRYPTO_ARCHIVE" build-corecrypto-14.py
    ensure_archive "$CRYPTO_ARCHIVE" build-corecrypto-14.py --namespace
  fi
  [ -f "$CRYPTO_ARCHIVE" ] || echo "WARN: $CRYPTO_ARCHIVE missing; archives are built after the record pass" >&2
  EXTRA_CFLAGS="$EXTRA_CFLAGS -DXNU_SOURCE_CORECRYPTO14=1"
  KERNEL_EXTRA_ARCHIVES="-L$KERNEL_SDKROOT/usr/local/lib/kernel -lfirehose_kernel $CRYPTO_ARCHIVE"
  KERNEL_ARCHIVE_DEPENDENCIES=$CRYPTO_ARCHIVE
  if [ "$ADRENO_FIRMWARE_PROBE" = 1 ]; then
    ADRENO_PROBE_ARCHIVE=$ROOT/build/adreno-firmware-probe/libAdrenoFirmwareProbe.a
    [ -f "$ADRENO_PROBE_ARCHIVE" ] || echo "WARN: $ADRENO_PROBE_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ADRENO_PROBE_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ADRENO_PROBE_ARCHIVE"
  fi
  if [ "$ADRENO_PM4_PROBE" = 1 ]; then
    PM4_PROBE_ARCHIVE=$ROOT/build/adreno-pm4-probe/libAdrenoPM4Probe.a
    [ -f "$PM4_PROBE_ARCHIVE" ] || echo "WARN: $PM4_PROBE_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$PM4_PROBE_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $PM4_PROBE_ARCHIVE"
  fi
  if [ "$SMMU4K_PROBE" = 1 ]; then
    SMMU4K_PROBE_ARCHIVE=$ROOT/build/smmu4k-probe/libArmSmmu4KProbe.a
    [ -f "$SMMU4K_PROBE_ARCHIVE" ] || echo "WARN: $SMMU4K_PROBE_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$SMMU4K_PROBE_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $SMMU4K_PROBE_ARCHIVE"
  fi
  if [ "$CONSTANT_UPLOADS_PROBE" = 1 ]; then
    CONSTANT_UPLOADS_ARCHIVE=$ROOT/build/constant-uploads-probe/libConstantUploadsProbe.a
    [ -f "$CONSTANT_UPLOADS_ARCHIVE" ] || echo "WARN: $CONSTANT_UPLOADS_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$CONSTANT_UPLOADS_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $CONSTANT_UPLOADS_ARCHIVE"
  fi
  if [ "${XNU_ARMVIRT_PLATFORM:-0}" = 1 ]; then
    ARMVIRT_ARCHIVE=$ROOT/build/armvirt-platform/libArmVirtPlatform.a
    [ -f "$ARMVIRT_ARCHIVE" ] || echo "WARN: $ARMVIRT_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ARMVIRT_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ARMVIRT_ARCHIVE"
  fi
  if [ "$ARM_DT_PLATFORM" = 1 ]; then
    ARM_DT_ARCHIVE=$ROOT/build/armdt-platform/libArmDTPlatform.a
    [ -f "$ARM_DT_ARCHIVE" ] || echo "WARN: $ARM_DT_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ARM_DT_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ARM_DT_ARCHIVE"
  fi
  if [ "${XNU_ARMCPU:-0}" = 1 ]; then
    ARMCPU_ARCHIVE=$ROOT/build/armcpu/libArmCpu.a
    [ -f "$ARMCPU_ARCHIVE" ] || echo "WARN: $ARMCPU_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ARMCPU_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ARMCPU_ARCHIVE"

# nabu: replace the driver's SM8550 GccUfs.h with the SM8150 board constants.
# NativeUfs reads only; the offsets differ between the two SoCs and must not be mixed.
NABU_GCC_UFS="$ROOT/scripts/GccUfs-nabu.h"
DRV_GCC_UFS="$ROOT/drivers/NativeUfs/GccUfs.h"
if [ -f "$NABU_GCC_UFS" ] && [ -f "$DRV_GCC_UFS" ]; then
  cp "$DRV_GCC_UFS" "$DRV_GCC_UFS.sm8550.orig"
  cp "$NABU_GCC_UFS" "$DRV_GCC_UFS"
  echo "nabu: installed SM8150 GccUfs.h over driver default (SM8550)"
fi
  fi
  if [ "${XNU_NATIVE_UFS:-0}" = 1 ]; then
    UFS_ARCHIVE=$ROOT/build/native-ufs/libNativeUfs.a
    [ -f "$UFS_ARCHIVE" ] || echo "WARN: $UFS_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$UFS_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $UFS_ARCHIVE"
    # nabu: NativeUfsBlock derives from IOBlockStorageDevice, which lives in the
    # IOStorageFamily kext rather than the kernel. audit-storage-interface.py compiles
    # the real IOBlockStorageDevice.cpp with the kernel's own compile arguments into
    # build/storage-abi/IOBlockStorageDevice-reference.o; linking that object supplies
    # the base class, its vtable and gMetaClass so make-stage linking succeeds.
    STORAGE_REF=$ROOT/build/storage-abi/IOBlockStorageDevice-reference.o
    if [ -f "$STORAGE_REF" ]; then
      KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES $STORAGE_REF"
      echo "nabu: linking $STORAGE_REF for IOBlockStorageDevice"
    else
      echo "nabu: WARNING storage reference object missing; NativeUfs will not link" >&2
    fi
  fi
  if [ "${XNU_NATIVE_ADRENO:-0}" = 1 ]; then
    # NativeAdreno plus its kits (scripts/build-native-adreno-kits.py). No personality is installed: the
    # board probe calls NativeAdrenoGmuContextBringup directly once it has powered the GPU CX domain.
    ADRENO_ARCHIVE=$ROOT/build/native-adreno/libNativeAdreno.a
    [ -f "$ADRENO_ARCHIVE" ] || echo "WARN: $ADRENO_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ADRENO_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ADRENO_ARCHIVE"
  fi
  if [ "$NATIVE_MOBILE_DISPLAY" = 1 ]; then
    MOBILE_DISPLAY_ARCHIVE=$ROOT/build/native-mobile-display/libNativeMobileDisplay.late.a
    [ -f "$MOBILE_DISPLAY_ARCHIVE" ] || echo "WARN: $MOBILE_DISPLAY_ARCHIVE missing; archives are built after the record pass" >&2
    python3 - "$MOBILE_DISPLAY_ARCHIVE" <<'PY_MOBILE_DISPLAY'
import hashlib, json, sys
from pathlib import Path
archive = Path(sys.argv[1])
report = json.loads(archive.with_name('build-report.json').read_text())
if hashlib.sha256(archive.read_bytes()).hexdigest() != report['archive_sha256']:
    raise SystemExit('Rebuild and qualify the exact own display archive before linking')
PY_MOBILE_DISPLAY
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$MOBILE_DISPLAY_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $MOBILE_DISPLAY_ARCHIVE"
  fi
  if [ "$NATIVE_LEGACY_DISPLAY" = 1 ]; then
    LEGACY_DISPLAY_ARCHIVE=$ROOT/build/native-legacy-display/libNativeLegacyDisplay.late.a
    [ -f "$LEGACY_DISPLAY_ARCHIVE" ] || echo "WARN: $LEGACY_DISPLAY_ARCHIVE missing; archives are built after the record pass" >&2
    python3 - "$LEGACY_DISPLAY_ARCHIVE" "$ROOT" <<'PY_LEGACY_DISPLAY'
import hashlib, json, sys
from pathlib import Path
archive=Path(sys.argv[1]);root=Path(sys.argv[2]);report=json.loads(archive.with_name('build-report.json').read_text())
if hashlib.sha256(archive.read_bytes()).hexdigest()!=report['archive_sha256']:
    raise SystemExit('Rebuild and qualify the exact owned Legacy archive before linking')
for name,digest in report['source_sha256'].items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Rebuild the owned Legacy archive after changing '+name)
PY_LEGACY_DISPLAY
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$LEGACY_DISPLAY_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $LEGACY_DISPLAY_ARCHIVE"
  fi
  if [ "${XNU_NATIVE_AES:-0}" = 1 ]; then
    AES_ARCHIVE=${XNU_NATIVE_AES_ARCHIVE:-$ROOT/build/native-aes/libNativeAES.a}
    [ -f "$AES_ARCHIVE" ] || echo "WARN: $AES_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$AES_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $AES_ARCHIVE"
  fi
  if [ "${XNU_NATIVE_VIRTIO_BLOCK:-0}" = 1 ]; then
    VIRTIO_ARCHIVE=${XNU_NATIVE_VIRTIO_BLOCK_ARCHIVE:-$ROOT/build/native-virtio-block/libNativeVirtioBlock.a}
    [ -f "$VIRTIO_ARCHIVE" ] || echo "WARN: $VIRTIO_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$VIRTIO_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $VIRTIO_ARCHIVE"
  fi
  if [ "$NATIVE_OFFLINE_GPU" = 1 ]; then
    GPU_BROKER_ARCHIVE=$ROOT/build/native-offline-gpu/libNativeOfflineGPU.late.a
    [ -f "$GPU_BROKER_ARCHIVE" ] || echo "WARN: $GPU_BROKER_ARCHIVE missing; archives are built after the record pass" >&2
    python3 - "$GPU_BROKER_ARCHIVE" "$ROOT" <<'PY_GPU_BROKER'
import hashlib,json,sys
from pathlib import Path
archive=Path(sys.argv[1]);root=Path(sys.argv[2]);report=json.loads(archive.with_name('build-report.json').read_text())
if hashlib.sha256(archive.read_bytes()).hexdigest()!=report['archive_sha256']:
    raise SystemExit('Rebuild the exact private GPU broker archive')
for name,digest in report['source_sha256'].items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Rebuild the GPU broker after changing '+name)
if hashlib.sha256((root/'build/native-virtio-console/libNativeVirtioConsole.a').read_bytes()).hexdigest()!=report['console_archive_sha256']:
    raise SystemExit('Rebuild the GPU broker against the actual byte-transport archive')
PY_GPU_BROKER
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$GPU_BROKER_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $GPU_BROKER_ARCHIVE"
  fi
  if [ "$NATIVE_VIRTIO_CONSOLE" = 1 ]; then
    CONSOLE_ARCHIVE=$ROOT/build/native-virtio-console/libNativeVirtioConsole.a
    [ -f "$CONSOLE_ARCHIVE" ] || echo "WARN: $CONSOLE_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$CONSOLE_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $CONSOLE_ARCHIVE"
  fi
  if [ "$NATIVE_RAM_BLOCK" = 1 ]; then
    RAM_BLOCK_ARCHIVE=$ROOT/build/native-ram-block/libNativeRamBlock.a
    [ -f "$RAM_BLOCK_ARCHIVE" ] || echo "WARN: $RAM_BLOCK_ARCHIVE missing; archives are built after the record pass" >&2
    if [ "${XNU_NATIVE_VIRTIO_BLOCK:-0}" = 1 ]; then
      # Both transports import the same original class. Keep one exact alias
      # definition; link the real RAM transport object, not duplicate aliases.
      python3 - "$VIRTIO_ARCHIVE" "$RAM_BLOCK_ARCHIVE" <<'PY_BINDINGS'
import json
from pathlib import Path
import sys
import hashlib
records = [json.loads(Path(p).with_name('bindings.json').read_text()) for p in sys.argv[1:]]
for archive, record in zip(sys.argv[1:], records):
    path = Path(archive)
    obj = path.with_name(path.stem.removeprefix('lib') + '.o')
    if hashlib.sha256(obj.read_bytes()).hexdigest() != record['compiled_object_sha256']:
        raise SystemExit('Re-audit the actual compiled storage object before linking')
first, second = [record['bindings'] for record in records]
if any(first.get(name) != value for name, value in second.items()):
    raise SystemExit('RAM transport imports must match the already linked original storage bindings')
PY_BINDINGS
      RAM_BLOCK_OBJECT=$ROOT/build/native-ram-block/NativeRamBlock.o
      [ -f "$RAM_BLOCK_OBJECT" ] || echo "WARN: $RAM_BLOCK_OBJECT missing; archives are built after the record pass" >&2
      KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES $RAM_BLOCK_OBJECT"
    else
      KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$RAM_BLOCK_ARCHIVE"
    fi
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $RAM_BLOCK_ARCHIVE"
  fi
  if [ "${XNU_SOURCE_PTHREAD:-0}" = 1 ]; then
    PTHREAD_ARCHIVE=$ROOT/build/libpthread-kernel/libpthread_kernel.a
    PTHREAD_BOOTSTRAP=$ROOT/build/libpthread-kernel/source_pthread_bootstrap.o
    ensure_archive "$PTHREAD_ARCHIVE" build-libpthread-kernel.py
    [ -f "$PTHREAD_ARCHIVE" ] || echo "WARN: $PTHREAD_ARCHIVE missing; archives are built after the record pass" >&2
    [ -f "$PTHREAD_BOOTSTRAP" ] || echo "WARN: $PTHREAD_BOOTSTRAP missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$PTHREAD_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $PTHREAD_ARCHIVE"
  fi
  if [ "$OWNER_ROOT_PROBE" = 1 ]; then
    VERIFIED_ROOT_ARCHIVE=${XNU_VERIFIED_ROOT_ARCHIVE:-$ROOT/build/verified-root-xnu/libVerifiedRootProbe.a}
    [ -f "$VERIFIED_ROOT_ARCHIVE" ] || echo "WARN: $VERIFIED_ROOT_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$VERIFIED_ROOT_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $VERIFIED_ROOT_ARCHIVE"
  fi
  if [ "$MOCKFS_MODE" = 1 ]; then
    MOCKFS_ARCHIVE=$ROOT/build/mockfs-fixture/libmockfs_fixture.a
    ensure_archive "$MOCKFS_ARCHIVE" build-mockfs-fixture.py
    [ -f "$MOCKFS_ARCHIVE" ] || echo "WARN: $MOCKFS_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$MOCKFS_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $MOCKFS_ARCHIVE"
  fi
  if [ "$SHENG_PMGR" = 1 ]; then
    PMGR_ARCHIVE=$ROOT/build/sheng-platform-power/libShengPlatformPower.a
    [ -f "$PMGR_ARCHIVE" ] || echo "WARN: $PMGR_ARCHIVE missing; archives are built after the record pass" >&2
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$PMGR_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $PMGR_ARCHIVE"
  fi
  # Optional extra link inputs (e.g. a stub for an unselected offline probe hook).
  if [ "$BOOT_PROGRESS" = 1 ]; then
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ROOT/build/boot-progress/libBootProgress.a"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ROOT/build/boot-progress/libBootProgress.a"
  fi
  KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES ${XNU_EXTRA_LD_ARCHIVES:-}"
fi
python3 - "${XNU_NATIVE_AES:-0}" "${XNU_NATIVE_AES_ARCHIVE:-$ROOT/build/native-aes/libNativeAES.a}" \
  "${XNU_NATIVE_VIRTIO_BLOCK:-0}" "${XNU_NATIVE_VIRTIO_BLOCK_ARCHIVE:-$ROOT/build/native-virtio-block/libNativeVirtioBlock.a}" \
  "$OWNER_ROOT_PROBE" "${XNU_VERIFIED_ROOT_ARCHIVE:-$ROOT/build/verified-root-xnu/libVerifiedRootProbe.a}" \
  "$NATIVE_RAM_BLOCK" "$ROOT/build/native-ram-block/libNativeRamBlock.a" \
  "$ADRENO_FIRMWARE_PROBE" "$ROOT/build/adreno-firmware-probe/libAdrenoFirmwareProbe.a" \
  "$ADRENO_PM4_PROBE" "$ROOT/build/adreno-pm4-probe/libAdrenoPM4Probe.a" \
  "$SMMU4K_PROBE" "$ROOT/build/smmu4k-probe/libArmSmmu4KProbe.a" \
  "$CONSTANT_UPLOADS_PROBE" "$ROOT/build/constant-uploads-probe/libConstantUploadsProbe.a" \
  "$NATIVE_VIRTIO_CONSOLE" "$ROOT/build/native-virtio-console/libNativeVirtioConsole.a" \
  "$NATIVE_OFFLINE_GPU" "$ROOT/build/native-offline-gpu/libNativeOfflineGPU.late.a" \
  "$SHENG_PMGR" "$ROOT/build/sheng-platform-power/libShengPlatformPower.a" \
  "${XNU_NATIVE_ADRENO:-0}" "$ROOT/build/native-adreno/libNativeAdreno.a" <<'PY'
import hashlib
from pathlib import Path
import sys
directory = Path('build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837')
stamp = directory / '.native-aes-link-input'
identity = '|'.join(mode + ':' + (hashlib.sha256(Path(archive).read_bytes()).hexdigest() if mode == '1' else 'disabled')
                    for mode, archive in zip(sys.argv[1::2], sys.argv[2::2]))
if not stamp.exists() or stamp.read_text() != identity:
    # Make does not track selection of an older alternative external archive.
    # Rebuild the conditional personality and relink when this input changes.
    for relative in ('mach.development.bcm2837.unstripped.noctf',
                     'iokit/DEVELOPMENT/KernelConfigTables.cpo'):
        (directory / relative).unlink(missing_ok=True)
    directory.mkdir(parents=True, exist_ok=True)
    stamp.write_text(identity)
PY
EXTRA_CFLAGS="$EXTRA_CFLAGS -DXNU_BOOT_PROGRESS=$BOOT_PROGRESS"
# Stub for native_legacy_display_probe (implementation lives only in UniXNU-sheng)
STUB_DIR="$ROOT/build/legacy-display-probe"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/LegacyDisplayProbe.cpp" <<'CPPEOF'
extern "C" void native_legacy_display_probe(void) {}
extern "C" void native_legacy_display_late_probe(void) {}
CPPEOF
# Weak observer used by NativeUfs window reads; Apple ld treats the weak ref as
# strong under -new_linker + force_load, so provide an empty strong definition.
# With the boot console enabled the real one lives in libBootProgress.a, and a
# second definition would be a duplicate symbol.
if [ "$BOOT_PROGRESS" != 1 ]; then
  printf 'extern "C" void boot_progress_poll(void) {}\n' >> "$STUB_DIR/LegacyDisplayProbe.cpp"
fi
if [ ! -f "$STUB_DIR/libLegacyDisplayProbe.a" ]; then
  xcrun --sdk iphoneos clang++ -target arm64-apple-ios17.0 -mkernel -ffreestanding -fno-builtin -std=gnu++2b -O2 -c \
    -o "$STUB_DIR/LegacyDisplayProbe.o" "$STUB_DIR/LegacyDisplayProbe.cpp" 2>/dev/null || true
  ar rcs "$STUB_DIR/libLegacyDisplayProbe.a" "$STUB_DIR/LegacyDisplayProbe.o" 2>/dev/null || true
  echo "built libLegacyDisplayProbe.a"
fi
KERNEL_EXTRA_ARCHIVES="${KERNEL_EXTRA_ARCHIVES:-} -Wl,-force_load,$STUB_DIR/libLegacyDisplayProbe.a"
KERNEL_ARCHIVE_DEPENDENCIES="${KERNEL_ARCHIVE_DEPENDENCIES:-} $STUB_DIR/libLegacyDisplayProbe.a"
echo "stub archive wired: $KERNEL_EXTRA_ARCHIVES"

# nabu: VerifiedRoot symbols for NativeUfs. The real vr_open / vr_verify_block come from
# kits/VerifiedRoot; the policy table is empty (count=0) so configureVerification fails
# closed and the UFS device is never published until a signed policy exists.
if [ "${XNU_NATIVE_UFS:-0}" = 1 ] && [ -d "$ROOT/kits/VerifiedRoot" ]; then
  VR_SRC="$ROOT/kits/VerifiedRoot"
  VR_OUT="$ROOT/build/verified-root-stub"
  if [ ! -f "$VR_OUT/libVerifiedRootStub.a" ]; then
    mkdir -p "$VR_OUT"
    cat > "$VR_OUT/vr_data.cpp" <<'CPPEOF'
#include "verified_root.h"
#include "VerifiedBlockPolicy.h"
extern "C" {
// C++ const defaults to internal linkage; the extern redeclarations force
// external linkage so the linker can see these two (policies/count already
// carry extern in VerifiedBlockPolicy.h).
extern const uint8_t verified_root_key[VR_KEY_BYTES];
extern const struct vr_crypto vr_xnu_crypto;
const uint8_t verified_root_key[VR_KEY_BYTES] = {0};
const NativeVerifiedBlockPolicy verified_root_policies[1] = {{nullptr, 0}};
const uint64_t verified_root_policy_count = 0;
const struct vr_crypto vr_xnu_crypto = {nullptr, nullptr};
}
CPPEOF
    xcrun --sdk iphoneos clang++ -target arm64-apple-ios17.0 -mkernel -ffreestanding -fno-builtin -std=gnu++2b -O2       -I "$VR_SRC/include" -I "$ROOT/drivers/NativeVirtioBlock"       -c -o "$VR_OUT/vr_data.o" "$VR_OUT/vr_data.cpp" || echo "vr_data compile failed"
    xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -mkernel -ffreestanding -fno-builtin -std=gnu99 -O2       -I "$VR_SRC/include"       -c -o "$VR_OUT/verified_root.o" "$VR_SRC/src/verified_root.c" || echo "verified_root compile failed"
    ar rcs "$VR_OUT/libVerifiedRootStub.a" "$VR_OUT/vr_data.o" "$VR_OUT/verified_root.o" 2>/dev/null || true
    echo "nabu: built VerifiedRoot stub archive"
  fi
  KERNEL_EXTRA_ARCHIVES="${KERNEL_EXTRA_ARCHIVES:-} -Wl,-force_load,$VR_OUT/libVerifiedRootStub.a"
  KERNEL_ARCHIVE_DEPENDENCIES="${KERNEL_ARCHIVE_DEPENDENCIES:-} $VR_OUT/libVerifiedRootStub.a"
fi

# Every archive above has to reach make in one argument: a second
# LD_KERNEL_ARCHIVES= in the argv silently replaces the first, which dropped
# firehose/corecrypto/pthread/mockfs and failed the link on their symbols.
# The compile-record pass runs before the archives are built, and make treats
# every entry here as a prerequisite. Drop the ones that do not exist yet; the
# pass that links has all of them.
_filter_existing() {
  _keep=
  for _token in $1; do
    case "$_token" in
      *.a|*.o) [ -f "$_token" ] && _keep="$_keep $_token" ;;
      *) _keep="$_keep $_token" ;;
    esac
  done
  printf '%s' "$_keep"
}
KERNEL_ARCHIVE_DEPENDENCIES=$(_filter_existing "${KERNEL_ARCHIVE_DEPENDENCIES:-}")
EXTRA_MAKE_ARGS+=("LD_KERNEL_ARCHIVES=${KERNEL_EXTRA_ARCHIVES:-}")
EXTRA_MAKE_ARGS+=("XNU_EXTERNAL_KERNEL_ARCHIVES=${KERNEL_ARCHIVE_DEPENDENCIES:-}")

# nabu: NativeUfs/RamBlock/VirtioBlock include <IOKit/storage/*.h> from
# build/storage-abi/include. The full audit (audit-storage-interface.py) also needs a
# prelinked kernel that does not exist yet at this point, so generate the header tree
# here -- the ABI qualification itself is a later, non-blocking gate.
STABI="$ROOT/build/storage-abi"
if [ -d "$ROOT/refer/IOStorageFamily" ] && [ ! -d "$STABI/include/IOKit/storage" ]; then
  mkdir -p "$STABI/include/IOKit/storage"
  cp "$ROOT"/refer/IOStorageFamily/*.h "$STABI/include/IOKit/storage/" 2>/dev/null || true
  sdk_path=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)
  if [ -n "$sdk_path" ] && [ -f "$sdk_path/usr/include/TargetConditionals.h" ]; then
    cp "$sdk_path/usr/include/TargetConditionals.h" "$STABI/include/" 2>/dev/null || true
  fi
  echo "nabu: generated $STABI/include/IOKit/storage ($(ls "$STABI/include/IOKit/storage" | wc -l | tr -d ' ') headers)"
fi

make -C .cache/xnu-work "${XNU_BUILD_TARGET:-build}" SDKROOT="${XNU_SDKROOT:-iphoneos}" ARCH_CONFIGS=ARM64 V="${XNU_MAKE_V:-0}" \
  OTHER_CXXFLAGS="-include $ROOT/.cache/xnu-work/iokit/DriverKit/IORPC.h" \
  MACHINE_CONFIGS=BCM2837 KERNEL_CONFIGS=DEVELOPMENT \
  ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64 LARGE_MEMORY_DEFINE=-UARM_LARGE_MEMORY \
  ARM64_LINK_ADDR=0xfffffff007004000 ARM64_PLKSEG_ADDR=0xfffffff004004000 \
  DEPLOYMENT_TARGET_FLAGS="-miphoneos-version-min=17.0 -DXNU_TARGET_OS_IOS" \
  DEPLOYMENT_LINKER_FLAGS="-Wl,-ios_version_min,17.0" \
  RC_DARWIN_KERNEL_VERSION="$XNU_DARWIN" RC_ProjectSourceVersion="$XNU_VERSION" \
  BUILD_LTO=0 BOUND_CHECKS=0 BUILD_WERROR="${XNU_BUILD_WERROR:-0}" MAKEJOBS=-j"${JOBS:-4}" \
  CFLAGS_EXTRA="$EXTRA_CFLAGS" "${EXTRA_MAKE_ARGS[@]}" \
  OBJROOT="$ROOT/build/xnu/ios-obj" SYMROOT="$ROOT/build/xnu/ios-sym" DSTROOT="$ROOT/build/xnu/ios-dst" || {
    echo "=== MAKE FAILED, dumping generated OSObject.iig.cpp ==="
    find build/xnu -name "OSObject.iig.cpp" -print 2>/dev/null | head -3
    F=$(find build/xnu -name "OSObject.iig.cpp" 2>/dev/null | head -1)
    if [ -n "$F" ]; then
      echo "--- first 40 lines of $F ---"
      head -40 "$F"
      echo "--- grep IORPC ---"
      grep -n "IORPC" "$F" || echo "(no IORPC reference)"
    fi
    echo "=== IORPC.h exists? ==="
    ls -la .cache/xnu-work/iokit/DriverKit/IORPC.h 2>/dev/null || echo "(missing)"
    echo "=== OSObject.iig first 8 lines ==="
    head -8 .cache/xnu-work/iokit/DriverKit/OSObject.iig 2>/dev/null || echo "(missing)"
    echo "=== OSObject.h first 20 lines ==="
    head -20 build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/iokit/DriverKit/OSObject.h 2>/dev/null || echo "(missing)"
    exit 1
  }
if [ "${XNU_SOURCE_CORECRYPTO14:-0}" = 1 ] && [ "$CRYPTO_BOOTSTRAP_MODE" = source ]; then
  python3 scripts/seal-source-crypto-kernel.py \
    build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837.unstripped.noctf
fi

