# Verified findings

Each item lists the evidence that produced it. Nothing here is inferred from
Apple silicon behaviour; all of it comes from this unit or this binary.

## 1. The first failure was PAN, not the MMU or the DT

`osfmk/arm/arm_init.c` executes `msr pan, #1` when `__ARM_PAN_AVAILABLE__` is
compiled in. This unit is a v8.0-A part:

- dmesg `CPU features: detected:` lists GICv3, erratum 845719, Spectre v2/v4/BHB,
  32-bit EL0/EL1, CRC32, PMUv3 — and **no `PAN`**.
- `MIDR 0x51af8014` = Qualcomm Kryo (Cortex-A73/A53 class).

With PAN compiled in, that `msr` is an UNDEF at EL1. The reset-probe campaign
agreees with this: the deepest gate that ever fired was the
`_ml_parse_cpu_topology` call site `0x79b9c34`, while the
`--reset-after _arm_vm_init` gate at `0x79c4a14` never fired — i.e. control died
between those two addresses, exactly where `msr pan, #1` sits (`0x79b9d50`).

Fix: `CONFIG_XNU_NATIVE_PAN=n` (with `CONFIG_XNU_NATIVE_ARCH_TIMER=y` to keep
the arch timer). Verified in the rebuilt kernel: the count of `msr PAN` is **0**.

## 2. The rest of the instruction set is safe

Full disassembly of the artifact (53,477,376 B, 370 distinct mnemonics) was
filtered for everything above ARMv8.0-A:

| class | result |
|---|---|
| LSE atomics (`ldadd*`, `cas*`, `swp*`, `ldumin*`, …) | **none** in real text |
| MTE (`irg`, `addg`, `subg`, `stg`, `ldg`, `gmi`) | one `subg` — inside `K256`, a constants table, i.e. data decoded as code |
| SVE/SVE2/SME (`ldff1*`, `sttp`, `fmopa`, `cmla`, `cmphi`) | only in `K256` and in the padding after `_lz4_encode_2gb`, again data/padding |
| PAC (`pac*`, `aut*`, `xpac*`, `bti`) | none |
| `stlr`/`stlr*` | 142 occurrences, all baseline v8.0 store-release |
| SHA-2 crypto (`sha256h.4s`, `sha256h2.4s`, `sha256su0/1.4s`) | 80 instructions, all in `_AccelerateCrypto_SHA256_compress` — **the only real hazard left**, see below |

So the kernel does not execute a v8.1+ instruction on any path we can see *except*
the hardware SHA-256 compressor. This unit's dmesg does **not** report `sha1`/
`sha2`/`aes`, so those instructions would UNDEF if dispatched to. The function is
reachable only through corecrypto's CPU-feature dispatch; that dispatch is
asserted, not proven, so it stays an open question (page 06).

Reproduce: `build/research/mnemonic-counts.txt`, `hazard-insns.txt`,
`sha-all.txt` (the last one is the annotated list used above).

## 3. Hardware facts the kernel is configured for

| fact | value | source |
|---|---|---|
| DRAM | base `0x40000000`, node 0 size to `0xffffffff` | dmesg e820 equivalent |
| GIC | GICv3, distributor `0x0f200000`, redistributor `0x0f300000`, 640 SPIs, stride `0x20000` | dmesg + ADT generator |
| arch timer | 19.2 MHz | dmesg `arch_timer` + `/cpus timebase-frequency` |
| framebuffer carveout | `0x5c000000`–`0x5cefffff`, 1200x2000 BGRA8888, stride 4800 | dmesg `simple-framebuffer` |
| panel | `qcom,mdss_dsi_nt36523_lide_hsd_video`, rotation 270 | dtbo overlay `fdt_14` |
| UART | `0x4a90000` exists, not usable | firmware analysis |

The ADT generator (`scripts/make-gta4l-adt.py`) uses exactly these numbers. Its
only non-deterministic output is `/chosen/random-seed`, so its own sha256 changes
per build; the DT content does not.

## 4. Handoff is self-consistent

- `LC_UNIXTHREAD` entry = `0xfffffff0073ef488`; `__start` is four `nop`s then
  fall-through into `_start_first_cpu`, so patching the first word is safe and
  the loader's "entry inside an executable segment" check still passes.
- `Args->Video[0] = fb PA | 1` is interpreted by `initialize_screen()` as
  "physical, map it yourself"; the FB PA (`0x5c000000`) is below `gPhysBase`,
  which is handled by `pmap_cache_attributes()` → `VM_WIMG_IO`, not a panic.
- `physBase`/`virtBase` pair and the mach-header-relative rebase in `start.s`
  land on the link address and on the real DT, confirmed by DT reads that
  succeed before `arm_vm_init`.

## 5. The flashed image contained the patched kernel

Checked on the exact file that was flashed, not on the build directory:

- `boot.img` header v2, page 4096, ramdisk at file `0x1b9000`, size 83,886,080 B;
- embedded ramdisk is byte-identical to `build/boot-out/gta4l/payload/payload.img`;
- `kernel.macho` at payload offset 670,720 is byte-identical to the probe kernel
  (`sha256 c4ee694b…`);
- the entry word inside the image is `12eeff17` = `b 0xfffffff0073eacd0`.

This rules out "the wrong kernel got flashed" for the band-1 probe image.
