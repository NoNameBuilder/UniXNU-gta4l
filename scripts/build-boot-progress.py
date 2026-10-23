#!/usr/bin/env python3
"""Build the framebuffer boot log against this source kernel's real ABI.

Compiled with the exact flags the kernel used for osfmk/kern/startup.o, so the
struct offsets and the kernel headers can never drift from the kernel itself.
"""
import json
import shutil
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/boot-progress'
OUT.mkdir(parents=True, exist_ok=True)

record = json.loads((ROOT / 'build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/osfmk/DEVELOPMENT/startup.o.json').read_text().strip().rstrip(','))
source = ROOT / 'kits/sheng/BootProgress.c'
obj = OUT / 'BootProgress.o'

command = []
args = record['arguments']
i = 0
while i < len(args):
    arg = args[i]
    if arg == record['file']:
        command.append(str(source))
    elif arg in ('-o', '-MF', '-MT', '-MJ'):
        if arg == '-o':
            command += ['-o', str(obj)]
        i += 1
    elif arg == '-Xclang' and args[i + 1].startswith('-W'):
        i += 1
    elif arg == '-D' and args[i + 1].startswith('XNU_BOOT_PROGRESS='):
        i += 1
    elif not arg.startswith(('-W', '-DXNU_BOOT_PROGRESS=')):
        command.append(arg)
    i += 1

command += ['-DXNU_BOOT_PROGRESS=1', '-mgeneral-regs-only', '-Wall', '-Wextra', '-Werror',
            '-I', str(ROOT / '.cache/xnu-work/osfmk'),
            '-I', str(source.parent)]
subprocess.run(command, cwd=record['directory'], check=True, timeout=180)
(OUT / 'compile-command.json').write_text(json.dumps(command, indent=2) + '\n')

ar = shutil.which('ar')
if ar is None:
    raise SystemExit('ar not found')
archive = OUT / 'libBootProgress.a'
archive.unlink(missing_ok=True)
subprocess.run([ar, 'rcs', str(archive), str(obj)], check=True, timeout=60)
print('PASS: boot progress object and archive built')
