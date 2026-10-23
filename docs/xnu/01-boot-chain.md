# Boot chain, byte for byte

```
PBL  ->  XBL (Qualcomm UEFI)  ->  ABL  ->  boot.img  ->  EDK2 inside the kernel slot
     ->  payload.img (ESP)  ->  DarwinBoot.efi  ->  kernel.macho  ->  XNU
```

## 1. Firmware below boot.img

Taken from `~/SM-T505-analysis/SM-T505-FIRMWARE-ANALYSIS-FULL.txt`
(sections 1/2/7/11/16) and cross-checked against this unit's dmesg:

| stage | fact |
|---|---|
| XBL | QC UEFI 1.2.8.f, entry `0xc225908`, UEFI FD mapped at `0x5fc00000` (3 MiB), stack `0x5ff90000` |
| ABL | ELF32 ARM, entry `0x9fa00000`, LZMA-compressed in the `abl` partition, built with `avbtool 1.1.0` |
| boot.img | Android header v2, page size 4096, kernel load `0x00008000`, ramdisk `0x02000000`, tags `0x01e00000`, board id `SRPTC24A008` |
| device tree | `dtbo` partition, 20 overlays; `fdt_14` = tablet, 15 of them are 1200x2000 panels. This unit: `qcom,mdss_dsi_nt36523_lide_hsd_video` |
| UART | `0x4a90000` exists in the SoC but is not wired to anything usable on this board |

The retail bootloader is locked. XBL/ABL/TZ are not modified by this project;
the only partition written is `BOOT`.

## 2. What our boot.img actually contains

The kernel slot does **not** hold XNU. It holds EDK2, packaged in the arm64
Linux `Image` container that ABL knows how to start (`ARMd` magic at `0x38`,
gzip-compressed, 1,800,907 bytes on disk, 3,145,840 bytes inflated). The
Android ramdisk slot holds the EFI payload image:

```
boot.img (85,766,144 B, header v2, page 4096)
  kernel   @ file 0x1000   1,800,907 B   gzip(EDK2 as arm64 Image)  -> load 0x40008000
  ramdisk  @ file 0x1B9000 83,886,080 B  payload.img (FAT ESP)      -> load 0x41000000
  dtb      appended
```

`payload.img` is a FAT32 volume (label `MTOO4049`) whose `/EFI/...` tree holds
`DarwinBoot.efi`, the ADT, and `kernel.macho` at byte offset 670,720. That is
the file the probe tool patches and the file DarwinBoot loads.

Verified on the flashed image: the embedded `kernel.macho` is byte-identical to
the CI artifact after probing (`sha256 c4ee694b…` for the arm_vm_init ladder).

## 3. DarwinBoot

`UniXNU/drivers/DarwinBoot/DarwinBootPkg/Driver/DarwinBoot.c`, read as source:

1. `ParseKernel()` requires Mach-O `0xfeedfacf`, `cputype 0x100000c`,
   `subtype 0`, `filetype 2`. Segments come from `LC_SEGMENT_64`
   (`cmd 0x19`); a segment with `filesize == 0` is ignored.
2. The entry point comes from `LC_UNIXTHREAD` (`cmd 0x5`), which must be
   exactly 288 bytes, `flava 6`, `count 68`; the PC is read at
   `command + 272`. For this kernel: `0xfffffff0073ef488` (`__start`).
   The loader additionally requires that address to fall inside an
   executable segment.
3. `AllocateWindow()` finds the largest run of `EfiConventionalMemory` and
   carves a 1.5 GiB (`0x60000000`) window from it. Segments are copied to
   `Address + segment.vmaddr - Kernel.Base`; the window keeps VA-PA constant.
4. The boot args, ADT and ramdisk follow the kernel inside the window. Observed
   layout: kernel `0x89e7c000`, args `0x8e104000`, tree `0x8e105000`, used
   `0x4290000`, window end `0xe9e7c000`.
5. `DarwinEnter(Args, Entry, Address, WindowSize, Video[0], rowBytes*height)`
   turns off the MMU and caches, cleans the D/I ranges, paints a green bar over
   the top 1/16 of the panel, and `br x1`.

The green bar proves only that this stub ran. It says nothing about XNU.

## 4. Kernel layout used by the probes

| symbol | value |
|---|---|
| entry (`__start`) | `0xfffffff0073ef488` — four `nop`s, then fall-through to `_start_first_cpu` |
| layout base | `0xfffffff007004000` |
| `gVirtBase` / `gPhysBase` | `0xfffffff00427c000` / `0x89e7c000` |
| window / used | `0x60000000` / `0x4290000` |
| MMU enable (`msr sctlr_el1, x0`) | unique occurrence at `0xfffffff0073f1350` in `common_start` |
| artifact | `kernel.macho`, 53,477,376 B |

`_start_first_cpu` reloads `args` into `x20` (`0xfffffff0073f1064`) and keeps it
there across `common_start`, which is why the probe caves can read boot args
from `x20` after the MMU is on.
