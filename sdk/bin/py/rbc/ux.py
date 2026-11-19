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

WORK = 512                  # the stack's region grows by this: the workspace and
                            # the calculator stack are there (@rinit: from @end)
KIND_FIXED = 0x0E           # SSX1 flags: declared, bitmap fixed at 4000h
KIND_BITMAP = 0x0C          # declared, bitmap on any page (call 41)
KIND_CONSOLE = 0x1A         # declared, console, 32 columns (bit 4): the kernel's console

# A BASIC program with none of these draws no pixels: the console kind
# (libux/rbc/con: PRINT through the kernel's console).  POKE or PEEK of
# the screen's addresses (16384 - 23295, written as a number) too.
PIXELS = re.compile(r'\b(PLOT|DRAW|CIRCLE|POINT|SCREEN\$|ATTR)\b')
SCREEN_ADDR = re.compile(r'\b(POKE|PEEK)\s*\(?\s*(\d{5})\b')

# The Spectrum's system variables, which the compiled program names by
# address ($5C3A, 0x5c65, 23692): in the program instead (@rsv + n,
# libux/rbc/sv.asm), IY = @rsv + 3Ah.
SV_LO, SV_HI = 0x5C00, 0x5CB6
SV_REF = re.compile(r'(?<![\w$])(\$5[cC][0-9a-fA-F]{2}|0[xX]5[cC][0-9a-fA-F]{2}|\d{5})(?![\w])')
# The runtime's ATTR forms the attributes' page as 58h + the third: the
# display file's page instead (@rattrh).  rbc's POKE and PEEK reach the
# screen (and PEEK the ROM) at these labels: through @rmap.
ATTR_PAGE = re.compile(r'^(\s+)xor 0x58\s*$')
MAPPED = ('rbc_poke_entry_local_write_public:', 'rbc_peek_entry_local_read_public:')


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


CALL_LBL = re.compile(r'^\s+call\s+([A-Za-z_]\w*)\s*(?:;.*)?$')
DB = re.compile(r'^\s+db\s+(.*?)\s*(?:;.*)?$', re.I)
LABEL_LINE = re.compile(r'^([A-Za-z_]\w*):\s*$')
RT_KEY = re.compile(r'^(?:source|original_rt)_([0-9a-f]{4})$')


def _db_bytes(line):
    m = DB.match(line)
    return [_val(x.strip()) for x in m.group(1).split(',')] if m else None


def inline_data(text):
    """The runtime's own calls of routines that take data written after the
    call (a number to stack: 5 bytes; a string: its length, then it) are
    followed, in the checked source, by those bytes disassembled as
    instructions - which must not be rewritten.  -> the text with them as
    db, label by label (each label kept at its place)."""
    lines = text.split('\n')
    kinds = {}                          # the routine's address -> 5 or 'len'
    for i in range(len(lines) - 1):
        m = CALL_LBL.match(lines[i])
        k = m and RT_KEY.match(m.group(1))
        if not k or not DB.match(lines[i + 1]):
            continue
        data = []
        j = i + 1
        while j < len(lines) and DB.match(lines[j]):
            data += _db_bytes(lines[j])
            j += 1
        kind = 5 if len(data) == 5 else 'len' if len(data) >= 2 and data[0] + 256 * data[1] + 2 == len(data) else None
        if kinds.get(k.group(1), kind) != kind:
            kind = None
        kinds[k.group(1)] = kind
    kinds = {a: k for a, k in kinds.items() if k}
    if not kinds:
        return text
    asm = ras.Asm('rbc-original.s')
    asm.load(text)
    asm.assemble()
    code = asm.out['text']

    def off(label):
        v = asm.syms.get(label)
        return v.v if v is not None and v.base == ('sec', 'text') else None
    out = []
    i = 0
    while i < len(lines):
        out.append(lines[i])
        m = CALL_LBL.match(lines[i])
        k = m and RT_KEY.match(m.group(1))
        if (k and k.group(1) in kinds and i + 1 < len(lines) and not DB.match(lines[i + 1])
                and LABEL_LINE.match(lines[i + 1]) and m.group(1).startswith('original_rt_')):
            start = off(LABEL_LINE.match(lines[i + 1]).group(1))
            n = kinds[k.group(1)]
            n = 5 if n == 5 else 2 + code[start] + 256 * code[start + 1]
            end = start + n
            j = i + 1
            labels = []                 # the labels in the data, and their places
            while j < len(lines):
                lm = LABEL_LINE.match(lines[j])
                if lm:
                    o = off(lm.group(1))
                    if o is not None and o >= end:
                        break
                    labels.append((lm.group(1), o))
                elif lines[j].strip() and not lines[j].lstrip().startswith(';'):
                    pass                # an instruction of the data: dropped
                j += 1
            for (name, o), nxt in zip(labels, [o for _, o in labels[1:]] + [end]):
                out.append(name + ':')
                if nxt > o:
                    out.append('    db ' + ','.join(str(b) for b in code[o:nxt]))
            i = j
            continue
        i += 1
    return '\n'.join(out)


def _sv(m):
    t = m.group(1)
    v = int(t[1:], 16) if t[0] == '$' else int(t, 16) if t[:2].lower() == '0x' else int(t)
    return '@rsv+%d' % (v - SV_LO) if SV_LO <= v < SV_HI else t


def own_memory(text):
    """The system variables, the display file's page and PEEK/POKE's
    addresses, the program's own (above).  IY set at the start."""
    out = []
    lines = text.split('\n')
    for i, line in enumerate(lines):
        code, sep, comment = line.partition(';')
        if ATTR_PAGE.match(code):
            code = ATTR_PAGE.sub(r'\1call @rattrh', code)
        elif not code.lstrip().lower().startswith(('db', 'dw', 'ds', 'defb', 'defw')):
            code = SV_REF.sub(_sv, code)
        out.append(code + sep + comment)
        if line.strip() == 'start:':
            out.append('    ld iy,@rsv+%d' % (0x5C3A - SV_LO))
        elif line.strip() in MAPPED:
            out.append('    call @rmap')
    return '\n'.join(out)


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


def kind_of(basic):
    """KIND_CONSOLE for a BASIC program that draws no pixels, else
    KIND_BITMAP.  (Strings and REM do not count.)"""
    code = re.sub(r'"[^"\n]*"', '""', basic)
    code = '\n'.join(l for l in code.split('\n') if not re.match(r'\s*\d+\s+REM\b', l))
    if PIXELS.search(code):
        return KIND_BITMAP
    for m in SCREEN_ADDR.finditer(code):
        if 16384 <= int(m.group(2)) < 23296:
            return KIND_BITMAP
    return KIND_CONSOLE


def archives(kind=KIND_BITMAP):
    out = []
    names = ('librbc.ssa', 'libc48.ssa', 'librom.ssa')
    if kind == KIND_CONSOLE:
        names = ('librbccon.ssa',) + names
    for name in names:
        p = os.path.join(LIBUX, name)
        if not os.path.exists(p):
            raise UxError('%s is missing: run sdk/bin/py/libux/build.py' % p)
        out.append(rld.read_archive(open(p, 'rb').read(), p))
    return out


CLAIMED = '    ld a,39\n    call $6003\n'      # the wrapper's claim of the screen (call 39)
EXIT = 'rbc_wrapper_exit:\n'                   # ... and its way out
NO_TOKENS = """        section text
        global @rtok
@rtok:  ld a,'?'
        jp @rpo
"""
TOKEN_ESCAPE = re.compile(r'\{([0-9A-Fa-f]{2})\}')


def needs_tokens(basic):
    """Can the program print a keyword's code (A5h-FFh)?  Through CHR$, or a
    string written with one ({C4}).  Else @rtok prints '?' (libux's keyword
    printer, ~0.5 KB, is not linked)."""
    from .bas2tap import TOKENS
    return 'CHR$' in basic.upper() or any(
        int(m.group(1), 16) >= min(c for c in TOKENS if c >= 0xA5)
        for m in TOKEN_ESCAPE.finditer(basic))


def link(text, stack, kind=KIND_BITMAP, tokens=True):
    """The --ux program -> (source, ssx, report)."""
    if CLAIMED not in text:
        raise UxError('the wrapper does not claim the screen (call 39)')
    if kind == KIND_CONSOLE:            # no screen to claim: the console's
        text = text.replace(CLAIMED, '    ld e,0\n    call @rinit\n', 1)
        text = text.replace(EXIT, EXIT + '    call @rcexit\n', 1)    # its colours back
    else:
        text = text.replace(CLAIMED, CLAIMED + '    call @rinit\n', 1)   # then the page: call 41
    src, used = rewrite(own_memory(inline_data(text)))
    obj, src = _assemble(src, 'rbc-ux.s')
    libs = archives(kind)
    rom_members = {id(m) for m in libs[-1]}
    objs = [rld.Obj(obj, 'rbc-ux.sso')]
    if not tokens:
        objs.append(rld.Obj(ras.assemble_text(NO_TOKENS, 'notokens'), 'notokens.sso'))
    try:
        ssx, bss, ent, gaddr, chosen = rld.link(objs, libs,
                                                entry='start', stack=stack + WORK, flags=kind)
    except rld.LinkError as e:
        raise UxError('link: %s' % e) from e
    rom = sorted(n for m in chosen if id(m) in rom_members for n in m.defs())
    syms = {n: a for n, (a, rel) in gaddr.items() if rel and n.startswith('@r')}
    return src, ssx, {'rom': rom, 'clean_room': sorted(n for n in used if n not in rom),
                      'symbols': syms}
