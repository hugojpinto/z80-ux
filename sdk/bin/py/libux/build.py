#!/usr/bin/env python3
# =====================================================================
# ZX-UX 48K Sinclair ZX Spectrum Unix.
# Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
# Non-commercial use only under the repository LICENSE.
# Commercial use prohibited without separate written permission.
# =====================================================================
"""Build the z80-ux C48 runtime (rcc --ux), beside the original one.

    libux/libc48.ssa   lib/*.asm and lib/*.c as lib/build.py builds them,
                       with libux's crt0.asm (no screen claimed at start:
                       @scrstart), console.asm (the display file where
                       system call 41 puts it) and sys.asm (no keyboard
                       rows behind a terminal) and float.asm (the
                       platform's float engine: sys 42) in place of lib's
    libux/libtty.ssa   libux/tty.asm: the stream and console kinds' text
                       through the terminal (platform/screen-kinds.md)

lib/ and lib/libc48.ssa are not touched: the original runtime still
rebuilds the shipped examples byte for byte.
"""
import glob
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.dirname(HERE)
LIB = os.path.join(SDK, 'lib')
sys.path.insert(0, SDK)
import ras  # noqa: E402
import rld  # noqa: E402
from rcc.driver import compile_to_asm  # noqa: E402

spec = importlib.util.spec_from_file_location('libbuild', os.path.join(LIB, 'build.py'))
libbuild = importlib.util.module_from_spec(spec)
spec.loader.exec_module(libbuild)

OVERRIDE = ('crt0.asm', 'console.asm', 'sys.asm', 'float.asm')


def members(paths):
    objs, seen = [], {}
    for f in paths:
        base = os.path.basename(f)[:-4]
        for mname, src, labels in libbuild.split(open(f).read(), base):
            for l in labels:
                if l in seen:
                    raise SystemExit('build: %s defined in %s and %s' % (l, seen[l], mname))
                seen[l] = mname
            try:
                objs.append((mname, ras.assemble_text(src, mname)))
            except ras.AsmError as e:
                raise SystemExit('build: %s: %s\n%s' % (mname, e, src))
    return objs


def main():
    paths = []
    for f in sorted(glob.glob(os.path.join(LIB, '*.asm'))):
        name = os.path.basename(f)
        if name == 'forth_rt.asm':
            continue
        paths.append(os.path.join(HERE, name) if name in OVERRIDE else f)
    objs = members(paths)
    from rcc import bcops
    objs.append(('vmtab.sso', ras.assemble_text(bcops.vm_table(), 'vmtab')))
    for f in sorted(glob.glob(os.path.join(LIB, '*.c'))):
        text, prog, g = compile_to_asm(f, {'lib': True})
        objs.append((os.path.basename(f)[:-2] + '.sso', ras.assemble_text(text, os.path.basename(f))))
    with open(os.path.join(HERE, 'libc48.ssa'), 'wb') as f:
        f.write(rld.write_archive(objs))
    tty = members([os.path.join(HERE, 'tty.asm')])
    with open(os.path.join(HERE, 'libtty.ssa'), 'wb') as f:
        f.write(rld.write_archive(tty))
    print('libux: libc48.ssa %d members, libtty.ssa %d members' % (len(objs), len(tty)))


if __name__ == '__main__':
    main()
