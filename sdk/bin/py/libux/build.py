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
                       platform's float engine: sys 42) in place of lib's,
                       and fstr.asm (numbers to text and back: ftoa, atof)
    libux/libtty.ssa   libux/tty.asm: the stream and console kinds' text
                       through the terminal (platform/screen-kinds.md)
    libux/librbc.ssa   libux/rbc/*.asm: the BASIC compiler's clean-room
                       routines in place of the 48K ROM's (rbc --ux)
    libux/librom.ssa   the ROM's own entry points, for those with no
                       clean-room routine yet (rbc/ux.py; a Spectrum only)

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
EXTRA = ('fstr.asm',)       # libux's own: numbers to text and back


def members(paths, prefix='', extra=()):
    """paths' members (each file's text after prefix); extra: (name, text)."""
    objs, seen = [], {}
    for f, text in [(f, prefix + open(f).read()) for f in paths] + list(extra):
        base = os.path.basename(f)[:-4]
        for mname, src, labels in libbuild.split(text, base):
            for l in labels:
                if l in seen:
                    raise SystemExit('build: %s defined in %s and %s' % (l, seen[l], mname))
                seen[l] = mname
            try:
                objs.append((mname, ras.assemble_text(src, mname)))
            except ras.AsmError as e:
                raise SystemExit('build: %s: %s\n%s' % (mname, e, src))
    return objs


def _keyboard():
    sys.path.insert(0, SDK)
    spec = importlib.util.spec_from_file_location('rbckeyboard', os.path.join(HERE, 'rbc', 'keyboard.py'))
    kb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kb)
    return kb


def keyboard_names():
    """The keyboard's shape (libux/rbc/keyboard.py), for keyboard.asm."""
    kb = _keyboard()
    return '\n'.join([
        'KPORT   equ %d' % kb.PORT,
        'KFIRST  equ %d' % kb.ROWS[0][0],
        'KBITS   equ %d' % len(kb.ROWS[0][1]),
        'K_CAPSI equ %d' % kb.index('CAPS'),
        'K_SYMI  equ %d' % kb.index('SYMBOL'), '']) + '\n'


def keys_asm():
    """@rkeys: each key's four characters (keyboard.py's legends)."""
    t = _keyboard().table()
    rows = ['        db ' + ','.join(str(b) for b in t[i:i + 16]) for i in range(0, len(t), 16)]
    return '        section text\n        global @rkeys\n@rkeys:\n' + '\n'.join(rows) + '\n'


def consts_asm():
    """The numbers the calculator stacks (1, 1/2, pi/2), written in the
    five-byte format by the float engine's own encoder (drivers/fp/mkfpk.py)."""
    from fractions import Fraction
    spec = importlib.util.spec_from_file_location(
        'mkfpk', os.path.join(os.path.dirname(os.path.dirname(SDK)), '..', 'drivers', 'fp', 'mkfpk.py'))
    mk = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mk)
    out = ['        section text', '        global @cone,@chalf,@cpi2']
    for name, v in (('@cone', 1), ('@chalf', Fraction(1, 2)), ('@cpi2', mk.PI / 2)):
        out.append('%-7s db %s' % (name + ':', ','.join(str(b) for b in mk.five(v))))
    return '\n'.join(out) + '\n'


def tokens_asm():
    """@rtok: a keyword printed by PRINT, its words from the BASIC compiler's
    token table (rbc/bas2tap.py), the last letter of each with bit 7 set."""
    sys.path.insert(0, os.path.join(SDK, 'rbc'))
    from rbc.bas2tap import TOKENS
    rows = []
    for code in range(0xA5, 0x100):
        w = TOKENS[code].encode('ascii')
        rows.append('        db %s     ; %02Xh %s' % (
            ','.join(str(b) for b in w[:-1] + bytes([w[-1] | 0x80])), code, TOKENS[code]))
    return TOKEN_CODE + '\n'.join(rows) + '\n'


TOKEN_CODE = """
        section text
        global @rtok
; @rtok: keyword A (C_TOKEN and up) on the screen, as PRINT spaces it: a
; leading space for statements and operators that begin with a letter
; (none after a space), a trailing one after words from C_TOKFN on that
; end in a letter or '$'.
@rtok:  ld b,a
        sub C_TOKEN
        ld hl,@rtokt
        ld c,a
.sk:    ld a,c
        or a
        j z,.fnd
.w:     bit 7,(hl)
        inc hl
        j z,.w
        dec c
        j .sk
.fnd:   ld a,b
        cp C_TOKST
        j c,.word
        ld a,(hl)
        cp 'A'
        j c,.word
        ld a,(FLAGS)
        bit FL_SP,a
        j nz,.word
        push bc
        push hl
        ld a,' '
        call @rpo
        pop hl
        pop bc
.word:  ld a,(hl)
        and 7Fh
        ld c,a
        push bc
        push hl
        call @rpo
        pop hl
        pop bc
        bit 7,(hl)
        inc hl
        j z,.word
        ld a,b
        cp C_TOKFN
        ret c
        ld a,c
        cp '$'
        j z,.tr
        cp 'A'
        ret c
.tr:    ld a,' '
        j @rpo
@rtokt:
"""


def main():
    paths = []
    for f in sorted(glob.glob(os.path.join(LIB, '*.asm'))):
        name = os.path.basename(f)
        if name == 'forth_rt.asm':
            continue
        paths.append(os.path.join(HERE, name) if name in OVERRIDE else f)
    paths += [os.path.join(HERE, name) for name in EXTRA]
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
    inc = open(os.path.join(HERE, 'rbc', 'rbc.inc')).read() + keyboard_names()
    rbc = members(sorted(glob.glob(os.path.join(HERE, 'rbc', '*.asm'))), inc,
                  [('tokens.asm', inc + tokens_asm()), ('consts.asm', consts_asm()),
                   ('keys.asm', inc + keys_asm())])
    with open(os.path.join(HERE, 'librbc.ssa'), 'wb') as f:
        f.write(rld.write_archive(rbc))
    sys.path.insert(0, os.path.join(SDK, 'rbc'))
    from rbc import ux
    with open(os.path.join(HERE, 'librom.ssa'), 'wb') as f:
        f.write(ux.rom_archive())
    print('libux: libc48.ssa %d members, libtty.ssa %d members, librbc.ssa %d members'
          % (len(objs), len(tty), len(rbc)))


if __name__ == '__main__':
    main()
