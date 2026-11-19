# =====================================================================
# ZX-UX 48K Sinclair ZX Spectrum Unix.
# Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
# Non-commercial use only under the repository LICENSE.
# Commercial use prohibited without separate written permission.
# =====================================================================
"""rbc --ux: a compiled BASIC program without the 48K ROM (platform/basic.md).

The checked HiSoft source (native_rbc_cli.compile_native) calls the ROM
by address: CALL nnnn, JP nnnn, RST n.  Here each of those becomes a
symbol, @rNNNN (RST n: CALL @rNN, its inline bytes kept), and the program
is linked with:

  libux/librbc.ssa   the clean-room routines (libux/rbc/*.asm), first;
  libux/libc48.ssa   what they use from the C48 runtime (@fstr, @fop...);
  libux/librom.ssa   for an address with no clean-room routine yet: @rNNNN
                     equ NNNN, the ROM itself (a Spectrum only).

`rom` in the report lists the ROM addresses still reached that way; a
program with none runs on a machine without the ROM.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.dirname(HERE)
LIBUX = os.path.join(SDK, 'libux')
if SDK not in sys.path:
    sys.path.insert(0, SDK)
import ras  # noqa: E402
import rld  # noqa: E402

NUM = r'(\$[0-9a-fA-F]+|0x[0-9a-fA-F]+|[0-9a-fA-F]+h|[0-9]+)'
BRANCH = re.compile(r'^(\s+)(call|jp)(\s+)((?:n?z|n?c|po|pe|p|m)\s*,\s*)?' + NUM + r'(\s*(?:;.*)?)$', re.I)
RST = re.compile(r'^(\s+)rst(\s+)' + NUM + r'(\s*(?:;.*)?)$', re.I)
JR = re.compile(r'^(\s+)jr(\s+)', re.I)
DJNZ = re.compile(r'^(\s*)([A-Za-z_.][\w.]*:?\s+)?djnz\s+(\S+)\s*(;.*)?$', re.I)

KIND_FIXED = 0x0E           # SSX1 flags: declared, bitmap fixed at 4000h
KIND_BITMAP = 0x0C          # declared, bitmap on any page (call 41)


# The ROM entry points the 100 examples reach (build/rbcs: rbc -S), for
# librom.ssa.  A program reaching another fails to link: add it here.
ROM_ENTRIES = (
    0x08, 0x10, 0x28, 0x30, 0x38,
    0x028E, 0x02BF, 0x031E, 0x0333, 0x03F8, 0x0D4D, 0x0D6B, 0x0D6E, 0x0DD9,
    0x1097, 0x111D, 0x1601, 0x1652, 0x16BF, 0x19E8, 0x1CAD, 0x1E52, 0x1E56,
    0x203C, 0x20A0, 0x21D6, 0x2211, 0x2297, 0x22AA, 0x22DF, 0x22E5, 0x232D,
    0x2477, 0x24B7, 0x2538, 0x2AB6, 0x2B7F, 0x2BF1, 0x2D2B, 0x2D7F, 0x2DA2,
    0x2DE3, 0x300F, 0x3014, 0x30CA, 0x31AD, 0x31AF, 0x3214, 0x3297, 0x33B4,
    0x343C, 0x346A, 0x346E, 0x3492, 0x34BC, 0x34E9, 0x350B, 0x359C, 0x35BF,
    0x35D0, 0x35DC, 0x35DE, 0x361F, 0x36AF, 0x36C4, 0x3713, 0x37AA, 0x37B5,
    0x384A, 0x3851)


def symbol(a):
    return '@r%02X' % a if a < 0x40 else '@r%04X' % a


def rom_archive():
    """librom.ssa: @rNNNN equ NNNN, one member each."""
    objs = []
    for a in ROM_ENTRIES:
        s = symbol(a)
        text = '        global %s\n%s equ %d\n' % (s, s, a)
        objs.append((s[1:] + '.sso', ras.assemble_text(text, s)))
    return rld.write_archive(objs)


class UxError(Exception):
    pass


def _val(t):
    t = t.lower()
    if t.startswith('$'):
        return int(t[1:], 16)
    if t.startswith('0x'):
        return int(t, 16)
    if t.endswith('h'):
        return int(t[:-1], 16)
    return int(t)


def rewrite(text):
    """The ROM's addresses as symbols -> (text, {symbol: address})."""
    out, used = [], {}
    for line in text.split('\n'):
        m = BRANCH.match(line)
        if m and _val(m.group(5)) < 0x4000:
            a = _val(m.group(5))
            sym = symbol(a)
            used[sym] = a
            line = '%s%s%s%s%s%s' % (m.group(1), m.group(2), m.group(3), m.group(4) or '', sym, m.group(6))
        else:
            m = RST.match(line)
            if m:
                a = _val(m.group(3))
                sym = symbol(a)
                used[sym] = a
                line = '%scall%s%s%s' % (m.group(1), m.group(2), sym, m.group(4))
            elif JR.match(line):
                line = JR.sub(r'\1j\2', line, count=1)      # JR, or JP if it no longer reaches
        out.append(line)
    return '\n'.join(out), used


def _assemble(text, name):
    """ras, with any DJNZ the longer calls put out of reach replaced."""
    for _ in range(64):
        try:
            return ras.assemble_text(text, name), text
        except ras.AsmError as e:
            m = re.search(r':(\d+): relative jump out of range', str(e))
            if not m:
                raise
            lines = text.split('\n')
            i = int(m.group(1)) - 1
            d = DJNZ.match(lines[i])
            if not d:
                raise
            lab = d.group(2) or ''
            lines[i:i + 1] = ['%s%sdec b' % (d.group(1) if not lab else '', lab or '    '),
                              '    jp nz,%s' % d.group(3)]
            text = '\n'.join(lines)
    raise UxError('too many DJNZ out of range')


def archives():
    out = []
    for name in ('librbc.ssa', 'libc48.ssa', 'librom.ssa'):
        p = os.path.join(LIBUX, name)
        if not os.path.exists(p):
            raise UxError('%s is missing: run sdk/bin/py/libux/build.py' % p)
        out.append(rld.read_archive(open(p, 'rb').read(), p))
    return out


def link(text, stack, kind=KIND_FIXED):
    """The --ux program -> (source, ssx, report)."""
    src, used = rewrite(text)
    obj, src = _assemble(src, 'rbc-ux.s')
    libs = archives()
    rom_members = {id(m) for m in libs[2]}
    try:
        ssx, bss, ent, gaddr, chosen = rld.link([rld.Obj(obj, 'rbc-ux.sso')], libs,
                                                entry='start', stack=stack, flags=kind)
    except rld.LinkError as e:
        raise UxError('link: %s' % e) from e
    rom = sorted(n for m in chosen if id(m) in rom_members for n in m.defs())
    syms = {n: a for n, (a, rel) in gaddr.items() if rel and n.startswith('@r')}
    return src, ssx, {'rom': rom, 'clean_room': sorted(n for n in used if n not in rom),
                      'symbols': syms}
