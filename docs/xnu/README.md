# XNU on the Samsung gta4l (SM-T505 / SM-T500, SM6115)

Everything in this directory is about getting `xnu-10063` to run on a retail
Galaxy Tab A7 (gta4l) with **no serial console**: the only evidence channel is
the panel.

Status is a snapshot, not a promise. The authoritative state lives in
[`../../build/probe/AUDIT.md`](../../build/probe/AUDIT.md) and in the CI
artifacts; these pages explain the why and the how.

| page | content |
|---|---|
| [01-boot-chain.md](01-boot-chain.md) | firmware → boot.img → payload → kernel, with the verified byte layout |
| [02-handoff-abi.md](02-handoff-abi.md) | the exact `boot_args` / DT / register contract DarwinBoot hands to XNU |
| [03-panel-console.md](03-panel-console.md) | the in-kernel framebuffer logger and what it can and cannot show |
| [04-probe-playbook.md](04-probe-playbook.md) | the reset/band probe ladder and how to read a single flash |
| [05-findings.md](05-findings.md) | verified findings: PAN, instruction scan, GIC, timer, framebuffer |
| [06-open-questions.md](06-open-questions.md) | what is still unproven and the next experiment for each |

## Ground rules used for every claim here

- The kernel artifact from CI is the source of truth. `boot.img` is assembled
  locally from that artifact, never rebuilt from a different source tree.
- A claim is only written down if it is backed by a log, a source line, or a
  disassembly of the exact binary being flashed. "Maybe" is not a finding.
- The retail bootloader is locked; nothing here depends on unlocking it, and no
  step in this tree modifies firmware partitions. Flashing is done by the device
  owner with `heimdall flash --BOOT ...`.
