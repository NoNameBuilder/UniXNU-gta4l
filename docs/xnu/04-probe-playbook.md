# Probe playbook: one flash, one question

With no serial port, a hang produces exactly one observable: what the panel
shows, and whether the device reboots. Every probe below is designed so a
single flash answers a single yes/no question.

Tooling: `build/probe/patch-xnu-entry-probe.py`. It patches a **copy** of the
CI `kernel.macho`.

## Safety rails inside the tool

Before writing anything it refuses to run unless

- the word at the entry point still encodes `b _start_first_cpu`,
- the unique `msr sctlr_el1, x0` word is `0xd5181000` and the following word is
  `0xd2a00600`,
- every cave candidate is 0x60 bytes of zeros inside an executable segment.

Caves are discovered dynamically (three of them, stages 1/2/3-4), so a new
kernel build moves them without breaking the probes.

## Band encoding

The framebuffer is 1200x2000 BGRA8888, stride 4800. `band` is one sixteenth of
the framebuffer, so each band is 125 rows tall.

| stage | where it runs | band | colour |
|---|---|---|---|
| 0 | loader `DarwinEnter`, before `br x1` | 0 | green `0xFF00FF00` |
| 1 | first instruction of `__start` (MMU off) | 0 | blue `0xFF0000FF` |
| 2 | just before `msr sctlr_el1, x0` (MMU off) | 2 | magenta `0xFFFF00FF` |
| 3 | 6 s after the MMU is on | none | device resets |
| 4 | N s after a named call in `arm_init` | none | device resets |

Stage 1 paints over the green bar on purpose: **green means the kernel entry
never executed**, which is a loader/flash problem, not an XNU problem. (Earlier
images painted stage 1 into band 1, which made "green only" ambiguous; that is
fixed.)

## Reading one flash

| panel | conclusion |
|---|---|
| green only | XNU entry never ran. Check that the flashed image contains the patched kernel and that `Kernel->Entry` from `LC_UNIXTHREAD` is the patched address. |
| green + blue | `__start` ran; execution stopped before the MMU enable. |
| green + blue + magenta | MMU is on. |
| blue + magenta, device reboots after ~6 s | `arm_vm_init` **returned** (stage 4 reset fired). |
| blue + magenta, no reboot | hung inside `arm_vm_init` (or the reset cave never ran). |
| any single band only | inconclusive; rebuild, the bands accumulate. |

The reset is a PSCI `SYSTEM_RESET` (`0x84000009` via `smc #0`) after a spin on
`cntpct_el0` at 19.2 MHz, so it works with the MMU on or off and without any
kernel services.

## Commands

```sh
# fresh copy of the verified artifact
cp build/kernel-artifact/kernel/kernel.macho build/probe/band0/kernel.macho

# blue at entry, magenta before the MMU, reset 6 s after _arm_vm_init returns
python3 build/probe/patch-xnu-entry-probe.py build/probe/band0/kernel.macho \
    --reset-after _arm_vm_init --in _arm_init --reset-delay 6

# splice the patched kernel into the payload inside boot.img (same length)
#   ramdisk offset 0x1B9000, kernel.macho at +670720
```

`--reset-before _arm_vm_init` answers the complementary question ("did the call
itself fault?"): if the device reboots, the call site was reached.

`--panic-screen` exists but is useless before `initialize_screen()`: it reads
`vinfo.v_baseaddr`, which is still zero. Use `--reset-*` instead.

## Built images

| file | meaning | sha256 (image) |
|---|---|---|
| `build/boot-out/boot-panfix.img` | PAN fix, no probes; green only is expected | — |
| `build/boot-out/boot-probe-armvminit.img` | stage 1 in band 1, stage 2, reset after `_arm_vm_init` | `6b769e15…` |
| `build/boot-out/boot-probe-band0.img` | stage 1 in band 0 (over the green bar), stage 2, reset after `_arm_vm_init` | `e0306cd6…` |

Flash with `heimdall flash --BOOT <image>`; the device owner does this, nothing
in this repository writes a partition by itself.
