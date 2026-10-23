# Open questions and the next experiment for each

Ordered by what blocks the next step.

## 1. Where does the PAN-fixed kernel stop?

Unknown: the PAN-fixed image shipped without probes, so "green only" was
expected and says nothing.

**Experiment:** flash `build/boot-out/boot-probe-band0.img` (blue at the entry
over the green bar, magenta before the MMU, reset 6 s after `_arm_vm_init`
returns) and read it with the table in
[04-probe-playbook.md](04-probe-playbook.md).

## 2. If it is still green only: does the CPU jump to the patched entry at all?

The artifact chain is verified, so a green-only result would mean the loaded
bytes are not the ones we patched, or the jump lands elsewhere.

**Experiment:** rebuild the payload with a `DiagDraw` in DarwinBoot right before
`DarwinEnter` that prints `Kernel.Entry`, `Kernel.Base`, `Entry PA` and the four
words read at the entry PA. Requires the UEFI payload build, not a kernel build.

## 3. Is the hardware SHA-256 path reachable on a v8.0 core?

`_AccelerateCrypto_SHA256_compress` is the only place where the kernel executes
an instruction this CPU does not implement (`sha256h.*`). It should only be
selected when corecrypto's CPU dispatch sees SHA-2 support, which this unit does
not report, but that is asserted rather than proven.

**Experiment:** in the `corecrypto-2023` feed, follow the `ccdigest_sha256`
init path to the ARM64 capability check, and confirm the software block is the
fallback when `HWCAP_SHA2` is clear. If it is not, add the equivalent of
`CONFIG_XNU_NATIVE_AES=n` for SHA-2, or patch the dispatch.

## 4. Does `initialize_screen()` actually put text on the panel?

The console logger only becomes visible when the framebuffer mapping succeeds in
`PE_create_console`, after `arm_vm_init`. If the boot progresses that far, the
green bar is replaced by `xnu: framebuffer console up`.

**Experiment:** the same band-0 flash: a rendered line instead of bands is the
positive result. No separate build is needed.

## 5. Root filesystem

No storage driver is linked (no UFS/NVMe/virtio-block in the archive list), and
`vfs_mountroot` has nothing to mount. Even a perfect bring-up will stop there.

**Experiment:** enable `XNU_NATIVE_UFS` (config already exists) and map the
`ufshc` node into the ADT at `0x4800000` with its real clock/GIC wiring from the
stock DTB; then feed a minimal ramdisk with `/sbin/launchd`.

## 6. Secondary CPUs and PSCI

The ADT advertises 8 CPUs and an `arm,psci-1.0` node with `method = "smc"`, but
nothing so far exercises `CPU_ON`. If the kernel reaches `machine_startup`, a
wrong PSCI conduit shows up as a hang with no output.

**Experiment:** after console output exists, boot with `cpus=1` in the command
line to separate "PSCI broken" from "platform init broken".

## 7. Interface details that are still guesses

- `PE_state.video.v_scale` is taken from `v_depth` bits 16-23, which we pass as
  0 → scale 1. If the console appears too small/large, that is the knob.
- `panel-rot=270` is only an argument to userspace today; the in-kernel console
  ignores rotation, so text is drawn in the panel's native landscape orientation.
- The ADT has no `/aliases` and no `serial` node; both are optional for the boot
  paths audited in `build/probe/AUDIT.md`, but IOKit drivers may want them later.
