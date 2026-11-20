#!/usr/bin/env python3
"""rbc's libux clean-room routines against the 48K ROM's, one by one.

    python3 test/basic/romdiff.py [-v] [N] [routine ...]

libux/librbc.ssa is linked at 8000h, system call 42 giving libux's ROM
adapter as the float engine (the ROM's calculator, as a Spectrum binds it) and each routine @rNNNN is
run on the SDK's Z80 (zxcore) beside the ROM's own NNNN on a second one,
from the same state: the system variables, a calculator stack of random
numbers (small integers, the full form, large, tiny, negative), the same
registers.  What each routine promises (sdk/bin/py/libux/rbc/*.asm) must
match: the registers and flags it returns, the calculator stack, STKEND,
ERR_NR.  N cases per routine (default 200).
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'test', 'fp'))
sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
import zxcore  # noqa: E402
import ras  # noqa: E402
import rld  # noqa: E402
from fptest import five  # noqa: E402

ORG = 0x8000
STK = 0xA000            # STKBOT: the calculator stack
NUM = 0xB000            # a number given by address
CODE = 0xC000           # inline calculator code
TRAP = 0xFE00           # returns (and the error handler) end here
SP = 0xF000
SV = dict(ERRNR=0x5C3A, ERRSP=0x5C3D, CHADD=0x5C5D, WORKSP=0x5C61, STKBOT=0x5C63,
          STKEND=0x5C65, MEM=0x5C68)
F_C, F_Z = 0x01, 0x40


def build():
    subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux', 'build.py')],
                   check=True, capture_output=True)
    d = os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux')
    libs = [rld.read_archive(open(os.path.join(d, n), 'rb').read(), n)
            for n in ('librbc.ssa', 'libc48rom.ssa', 'libc48.ssa')]   # (@romfp: the ROM's engine)
    names = sorted(s for m in libs[0] for s in m.defs() if s.startswith('@r') and s != '@rsv')
    stub = ('        section text\n        global start,@rsv\n'
            '@rsv    equ 5C00h          ; the system variables where the ROM has them\n'
            'start:\n') + ''.join('        dw %s\n' % n for n in names + ['@romfp'])
    image, bss, ent, gaddr, chosen = rld.link([rld.Obj(ras.assemble_text(stub, 'stub'), 'stub')],
                                              libs, org=ORG)
    return bytes(image), {n: ORG + a for n, (a, r) in gaddr.items()}


FP_ORG = 0xD000


def clean_engine():
    """drivers/fp/fp.asm, the clean-room float engine, at FP_ORG."""
    work = os.path.join(ROOT, 'build', 'romdiff')
    os.makedirs(work, exist_ok=True)
    sj = os.environ.get('SJASMPLUS', os.path.join(ROOT, 'fdd3000', 'tools', 'bin', 'sjasmplus'))
    with open(os.path.join(work, 'fp.asm'), 'w') as f:
        f.write('        DEVICE NOSLOT64K\n        org 0%04Xh\nb:\n        include "%s"\ne:\n'
                '        SAVEBIN "fp.bin", b, e-b\n'
                % (FP_ORG, os.path.join(ROOT, 'drivers', 'fp', 'fp.asm')))
    subprocess.run([sj, '--nologo', '--msg=war', '-I' + os.path.join(ROOT, 'drivers', 'fp'), 'fp.asm'],
                   cwd=work, check=True, capture_output=True)
    return open(os.path.join(work, 'fp.bin'), 'rb').read()


class Pair:
    """The ROM's machine and ours, set up alike."""

    def __init__(self):
        self.image, self.sym = build()
        self.rom = zxcore.Spectrum()
        self.ux = zxcore.Spectrum()
        self.ux.mem[ORG:ORG + len(self.image)] = self.image
        e = self.sym['@romfp']                          # system call 42: libux's ROM adapter
        if os.environ.get('ROMDIFF_ENGINE') == 'clean':   # ... or the clean-room engine
            e = FP_ORG
            self.ux.mem[FP_ORG:FP_ORG + len(clean_engine())] = clean_engine()
        self.engine = e
        self.install(self.ux.mem)

    def install(self, m):
        """Our routines at ORG, the engine, system call 42 giving it."""
        m[ORG:ORG + len(self.image)] = self.image
        if self.engine == FP_ORG:
            m[FP_ORG:FP_ORG + len(clean_engine())] = clean_engine()
        e = self.engine
        m[0x6003:0x6008] = bytes([0x21, e & 255, e >> 8, 0xB7, 0xC9])   # ld hl,e / or a / ret

    def setup(self, nums, regs, boot=False):
        out = []
        for zx in (self.rom, self.ux):
            m = zx.mem
            if boot:                            # the ROM's own state (streams, channels)
                m[0x4000:] = booted()
                if zx is self.ux:
                    self.install(m)
            else:
                m[0x5C00:0x5CC0] = bytes(0xC0)
            m[STK - 16:STK + 400] = bytes(416)
            p = STK
            for b in nums:
                m[p:p + 5] = b
                p += 5
            w = lambda a, v: m.__setitem__(slice(a, a + 2), bytes([v & 255, v >> 8 & 255]))  # noqa
            w(SV['WORKSP'], STK)
            w(SV['STKBOT'], STK)
            w(SV['STKEND'], p)
            w(SV['MEM'], 0x5C92)
            m[SV['ERRNR']] = 0xFF
            w(SP - 2, TRAP)                      # ERR_SP: an error ends at TRAP
            w(SV['ERRSP'], SP - 2)
            w(SP - 4, TRAP)                      # the call's return
            r = dict(a=0, f=0, bc=0, de=0, hl=0)
            r.update(regs)
            zx.set(iy=0x5C3A, sp=SP - 4, iff1=False, iff2=False, **r)
            out.append(p)
        return out[0]

    def go(self, which, pc):
        zx = self.rom if which == 'rom' else self.ux
        zx.set(pc=pc)
        if not zx.run((TRAP,), zx.t + 30_000_000):
            raise RuntimeError('%s %04X did not return' % (which, pc))
        m = zx.mem
        r = lambda a: m[a] | m[a + 1] << 8  # noqa
        return dict(a=zx.a, f=zx.flags, bc=zx.bc, de=zx.de, hl=zx.hl, sp=zx.sp,
                    errnr=m[SV['ERRNR']], stkend=r(SV['STKEND']), stkbot=r(SV['STKBOT']),
                    mem=r(SV['MEM']), m=m)


_BOOT = []


def booted():
    """RAM (4000h-FFFFh) as the ROM leaves it at its first key wait, then
    its own CLS: channels, streams, positions, colours."""
    if not _BOOT:
        zx = zxcore.Spectrum(read_port=lambda p: 0xFF)
        zx.set(pc=0, sp=0xFFFF)
        if not zx.run((0x15D4,), zx.t + 200_000_000):
            raise RuntimeError('the ROM did not start')
        zx.set(iy=0x5C3A, sp=SP - 2, iff1=False, iff2=False)
        zx.mem[SP - 2:SP] = bytes([TRAP & 255, TRAP >> 8])
        zx.set(pc=0x0D6B)
        zx.run((TRAP,), zx.t + 50_000_000)
        zx.mem[0x5C8C] = 255                     # SCR_CT, as rbc keeps it
        _BOOT.append(bytes(zx.mem[0x4000:]))
    return _BOOT[0]


PRINTVARS = [('S_POSN', 0x5C88, 2), ('DF_CC', 0x5C84, 2), ('S_POSNL', 0x5C8A, 2),
             ('DFCCL', 0x5C86, 2), ('DF_SZ', 0x5C6B, 1), ('ATTR_P', 0x5C8D, 2),
             ('ATTR_T', 0x5C8F, 2), ('P_FLAG', 0x5C91, 1), ('ERR_NR', 0x5C3A, 1),
             ('BORDCR', 0x5C48, 1), ('SEED', 0x5C76, 2)]


def stream(rng, n):
    out = []
    while len(out) < n:
        k = rng.random()
        if k < 0.55:
            out.append(rng.randrange(32, 128))
        elif k < 0.63:
            out.append(13)
        elif k < 0.68:
            out.append(6)
        elif k < 0.72:
            out += [0x16, rng.randrange(0, 22), rng.randrange(0, 32)]
        elif k < 0.75:
            out += [0x17, rng.randrange(0, 64), 0]
        elif k < 0.82:
            c = rng.randrange(0x10, 0x16)
            v = rng.choice([0, 1, 8, 9, 2, 7] if c < 0x12 else [0, 1, 8] if c < 0x14 else [0, 1])
            out += [c, v]
        elif k < 0.86:
            if out and 32 <= out[-1] < 128:     # (not from the top left: the ROM draws
                out.append(8)                   # "line -1" into the attributes)
        elif k < 0.88:
            out.append(9)
        elif k < 0.94:
            out.append(rng.randrange(0x80, 0xA5))
        elif k < 0.96:
            out.append(rng.randrange(0xA5, 0x100))
        else:
            out.append(rng.choice([0, 1, 7, 10, 11, 12, 14, 15, 0x18, 0x1F]))
    return out


def rnum(rng):
    k = rng.random()
    if k < 0.3:
        v = rng.randint(-65535, 65535)
    elif k < 0.45:
        v = rng.choice([0, 1, -1, 0.5, -0.5, 65535, -65535, 65536, 2, 100])
    elif k < 0.7:
        v = rng.uniform(-1000, 1000)
    else:
        v = rng.choice([1, -1]) * 10 ** rng.uniform(-30, 30)
    return bytes(five(v))


def stack_bytes(st):
    return bytes(st['m'][STK:st['stkend']]) if st['stkend'] >= STK else b'?'


# Each routine: (inputs(rng) -> (numbers, registers, extra memory),
#                what is compared: names of st fields or ('mem', addr, n))
def at_num(b):
    return {NUM: b}


CASES = {}


def case(addr, outs, n_stack=0, regs=None, extra=None, flags=0):
    CASES[addr] = (n_stack, regs, extra, outs, flags)


def topregs(n):
    return lambda p: dict(hl=p - 5, de=p)


def pairregs(n):
    return lambda p: dict(hl=p - 10, de=p - 5)


case(0x33B4, ['hl', 'de', 'stack', 'stkend'], 1, lambda p: dict(hl=NUM), 'num')
case(0x35BF, ['hl', 'de'], 2)
case(0x2BF1, ['a', 'de', 'bc', 'hl', 'stkend'], 2)
case(0x2AB6, ['hl', 'bc', 'de', 'stack', 'stkend'], 1, None, 'random')
case(0x2D2B, ['hl', 'de', 'stack', 'stkend'], 1, None, 'random')
case(0x2D7F, ['c', 'de', 'a', 'hl'], 0, lambda p: dict(hl=NUM), 'smallnum')
case(0x2DA2, ['bc', 'a', 'de', 'hl', 'stack', 'stkend', 'errnr'], 2, None, None, F_C | F_Z)
case(0x3297, ['a', 'hl', 'de', 'bc', ('mem', NUM, 5)], 0, lambda p: dict(hl=NUM), 'num')
case(0x343C, ['hl', 'de', 'stack'], 2, pairregs(2))
case(0x34E9, ['a', 'bc', 'hl'], 0, lambda p: dict(hl=NUM), 'num', F_C | F_Z)
case(0x350B, ['hl', ('mem', NUM, 5)], 0, lambda p: dict(hl=NUM), 'carry', F_C)
case(0x3492, ['hl', 'stack'], 1, topregs(1))
for a in (0x3014, 0x300F, 0x30CA, 0x31AF):      # HL = x, DE = y
    case(a, ['errnr', 'result2', 'de'], 2, pairregs(2))
case(0x3851, ['errnr', 'result1', 'hl', 'de', 'stkend'], 3, lambda p: dict(hl=0x1234, de=0x4321))
for a in (0x346E, 0x346A, 0x3214):              # HL = the number
    case(a, ['errnr', 'result1', 'hl', 'de'], 1, topregs(1))
for a in (0x36AF, 0x36C4, 0x3713, 0x37AA, 0x37B5, 0x384A):  # calculator routines: the top
    case(a, ['errnr', 'result1', 'hl', 'de', 'stkend'], 2, lambda p: dict(hl=0x1234, de=0x4321))
case(0x16BF, ['hl', 'stkbot', 'stkend', 'mem'], 2)
case(0x16C5, ['hl', 'stkend', 'mem'], 2)
CALC = {'cmp': None, 'rnd': [0xA1, 0x0F, 0x34, 0x37, 0x16, 0x04, 0x34, 0x80, 0x41, 0, 0, 0x80,
                             0x32, 0x02, 0xA1, 0x03, 0x31, 0x38],
        'pi2': [0xA3, 0x38], 'atn': [0x24, 0x38]}


def compare(name, outs, flags, a, b):
    bad = []
    for o in outs:
        if isinstance(o, tuple):
            x, y = bytes(a['m'][o[1]:o[1] + o[2]]), bytes(b['m'][o[1]:o[1] + o[2]])
        elif o == 'stack':
            x, y = stack_bytes(a), stack_bytes(b)
        elif o == 'result1':
            if a['errnr'] != 0xFF:
                continue
            x, y = bytes(a['m'][a['hl']:a['hl'] + 5]), bytes(b['m'][b['hl']:b['hl'] + 5])
        elif o == 'result2':
            if a['errnr'] != 0xFF:
                continue
            x, y = bytes(a['m'][a['de'] - 5:a['de']]), bytes(b['m'][b['de'] - 5:b['de']])
        elif o in ('c', 'b', 'e', 'd'):
            reg = {'c': ('bc', 0), 'b': ('bc', 8), 'e': ('de', 0), 'd': ('de', 8)}[o]
            x, y = a[reg[0]] >> reg[1] & 255, b[reg[0]] >> reg[1] & 255
        else:
            if o in ('hl', 'de', 'bc', 'a') and 'errnr' in outs and a['errnr'] != 0xFF:
                continue
            if name == '2DA2' and o in ('bc', 'a') and a['f'] & F_C:
                continue                # too big: BC is not promised
            x, y = a[o], b[o]
        if x != y:
            bad.append('%s: ROM %s, ours %s' % (o, x.hex() if isinstance(x, bytes) else '%X' % x,
                                                 y.hex() if isinstance(y, bytes) else '%X' % y))
    if flags and (a['errnr'] == 0xFF) and (a['f'] & flags) != (b['f'] & flags):
        bad.append('flags: ROM %02X, ours %02X' % (a['f'] & flags, b['f'] & flags))
    return bad


def print_case(pair, rng, stream_no, chars, pre=(), post=()):
    """chars printed on stream stream_no on both; -> (rom, ux) states."""
    out = []
    for which, zx in (('rom', pair.rom), ('ux', pair.ux)):
        zx.mem[0x4000:] = booted()
        if which == 'ux':
            pair.install(zx.mem)
        sym = (lambda n, a: a) if which == 'rom' else (lambda n, a: pair.sym[n])
        code = []

        def calls(ops):
            out = []
            for name, addr, a, bc, de in ops:     # (routine, A, BC, DE)
                t = sym(name, addr)
                out += [0x3E, a, 0x01, bc & 255, bc >> 8, 0x11, de & 255, de >> 8,
                        0xCD, t & 255, t >> 8]
            return out
        code += calls(pre)
        if stream_no is not None:
            t = sym('@r1601', 0x1601)
            code += [0x3E, stream_no & 255, 0xCD, t & 255, t >> 8]
        p10 = sym('@r10', 0x10)
        for c in chars:
            code += [0x3E, c] + ([0xD7] if which == 'rom' else [0xCD, p10 & 255, p10 >> 8])
        code += calls(post) + [0xC3, TRAP & 255, TRAP >> 8]
        zx.mem[0xC000:0xC000 + len(code)] = bytes(code)
        m = zx.mem
        m[SP - 2:SP] = bytes([TRAP & 255, TRAP >> 8])
        m[0x5C3D:0x5C3F] = bytes([(SP - 2) & 255, (SP - 2) >> 8])
        m[0x5C3A] = 0xFF
        zx.set(iy=0x5C3A, sp=SP - 2, iff1=False, iff2=False, a=0, bc=0, de=0, hl=0, pc=0xC000)
        if not zx.run((TRAP,), zx.t + 200_000_000):
            raise RuntimeError('%s: the stream did not end' % which)
        out.append(zx)
    return out


def print_compare(a, b):
    bad = []
    if a.mem[0x5C3A] != 0xFF or b.mem[0x5C3A] != 0xFF:
        if a.mem[0x5C3A] != b.mem[0x5C3A]:
            return ['ERR_NR: ROM %02X, ours %02X' % (a.mem[0x5C3A], b.mem[0x5C3A])]
    for i in range(0x4000, 0x5B00):
        if a.mem[i] != b.mem[i]:
            if i < 0x5800:
                o = i - 0x4000
                line = (o >> 5 & 0xC0) | (o >> 2 & 0x38) | (o >> 8 & 7)
                bad.append('pixels line %d col %d: ROM %02X, ours %02X' % (line, o & 31, a.mem[i], b.mem[i]))
            else:
                o = i - 0x5800
                bad.append('attribute %d,%d: ROM %02X, ours %02X' % (o >> 5, o & 31, a.mem[i], b.mem[i]))
            break
    for name, addr, n in PRINTVARS:
        x, y = bytes(a.mem[addr:addr + n]), bytes(b.mem[addr:addr + n])
        if x != y:
            bad.append('%s: ROM %s, ours %s' % (name, x.hex(), y.hex()))
    if (a.mem[0x5C3C] ^ b.mem[0x5C3C]) & 1:
        bad.append('TV_FLAG bit 0: ROM %02X, ours %02X' % (a.mem[0x5C3C], b.mem[0x5C3C]))
    return bad


def print_tests(pair, rng, n, only, verbose):
    fails = {}
    tests = {
        'PRINT:S': lambda: (2, stream(rng, rng.randrange(1, 400)), ()),
        'PRINT:K': lambda: (0, [c for c in stream(rng, rng.randrange(1, 60)) if c != 0x16], ()),
        'CLS': lambda: (2, stream(rng, 100), ()),
        'CO-TEMP': lambda: (2, [65], [('@r2211', 0x2211, rng.randrange(0x10, 0x16),
                                       0, rng.choice([0, 1, 2, 7, 8, 9, 10]) << 8)]),
        'CL-SET': lambda: (2, [65], [('@r0DD9', 0x0DD9, 0, rng.randrange(3, 25) << 8 | rng.randrange(2, 34), 0)]),
        'PR-STRING': lambda: (2, [], [('@r203C', 0x203C, 0, 20, 0x3D00 + rng.randrange(0, 600))]),
        'BORDER': lambda: (2, [65], [('@r2297', 0x2297, rng.randrange(0, 8), 0, 0)]),
        # (RANDOMIZE 0: the kernel's ticks for libux, FRAMES for the ROM: not compared)
        'RANDOMIZE': lambda: (2, [], [('@r1E52', 0x1E52, 0, rng.randrange(1, 65536), 0)]),
    }
    count = 0
    for name, gen in tests.items():
        if only and not any(o in name for o in only):
            continue
        count += 1
        for i in range(n // 4 or 1):
            st, chars, pre = gen()
            post = ()
            if name == 'CLS':                   # after a stream (CLS sets SCR_CT to 1:
                post = [('@r0D6B', 0x0D6B, 0, 0, 0)]    # "scroll?" would follow)
            a, b = print_case(pair, rng, st, chars, pre, post)
            bad = print_compare(a, b)
            if bad:
                fails.setdefault(name, []).append('%s: %s' % (
                    ' '.join('%02X' % c for c in chars[:80]), '; '.join(bad[:4])))
        if verbose or name in fails:
            print('%-12s %s' % (name, 'FAIL (%d)' % len(fails[name]) if name in fails else 'ok'))
            for f in fails.get(name, [])[:3]:
                print('    ' + f)
    return count, len(fails)


def room_tests(pair, rng, n, only, verbose):
    """MAKE-ROOM, ONE-SPACE, RECLAIM-2, BC-SPACES on random pointers VARS ..
    STKEND (ascending) in a region of random bytes."""
    fails = {}
    count = 0
    lo, hi = 0xA000, 0xA300
    for name, addr in (('MAKE-ROOM', 0x1655), ('ONE-SPACE', 0x1652), ('RECLAIM-2', 0x19E8),
                       ('BC-SPACES', 0x30)):
        if only and not any(o in name for o in only):
            continue
        count += 1
        sym = '@r%04X' % addr if addr > 0xFF else '@r%02X' % addr
        for i in range(n):
            ptrs = sorted(rng.randrange(lo, hi) for _ in range(14))
            if rng.random() < 0.3:
                ptrs[12] = ptrs[13] = ptrs[11]          # WORKSP = STKBOT = STKEND
            end = ptrs[13]
            place = rng.randrange(lo, max(lo + 1, end))
            bc = rng.randrange(1, 40)
            if name == 'RECLAIM-2':
                bc = rng.randrange(1, max(2, end - place + 1))
            region = bytes(rng.randrange(256) for _ in range(0x500))
            st = []
            for zx, pc in ((pair.rom, addr), (pair.ux, pair.sym[sym])):
                m = zx.mem
                m[0x5C00:0x5CC0] = bytes(0xC0)
                for k, pv in enumerate(ptrs):
                    m[0x5C4B + 2 * k:0x5C4D + 2 * k] = bytes([pv & 255, pv >> 8])
                m[0x5C3A] = 0xFF
                m[0x5C68:0x5C6A] = bytes([0x92, 0x5C])
                m[lo:lo + 0x500] = region
                m[SP - 2:SP] = bytes([TRAP & 255, TRAP >> 8])
                m[0x5C3D:0x5C3F] = bytes([(SP - 2) & 255, (SP - 2) >> 8])
                m[SP - 4:SP - 2] = bytes([TRAP & 255, TRAP >> 8])
                zx.set(iy=0x5C3A, sp=SP - 4, a=0, f=0, bc=bc, de=0, hl=place, pc=pc)
                if not zx.run((TRAP,), zx.t + 30_000_000):
                    raise RuntimeError('%s did not return' % name)
                st.append(dict(hl=zx.hl, de=zx.de, bc=zx.bc, mem=bytes(m[lo:lo + 0x500]),
                               ptrs=bytes(m[0x5C4B:0x5C67]), err=m[0x5C3A]))
            a, b = st
            bad = [k for k in ('err', 'ptrs', 'mem', 'hl', 'de', 'bc') if a[k] != b[k]]
            if bad:
                fails.setdefault(name, []).append('place %04X count %d end %04X: %s' % (
                    place, bc, end, '; '.join('%s ROM %s ours %s' % (
                        k, '%X' % a[k] if isinstance(a[k], int) else '..',
                        '%X' % b[k] if isinstance(b[k], int) else '..') for k in bad)))
        if verbose or name in fails:
            print('%-12s %s' % (name, 'FAIL (%d)' % len(fails[name]) if name in fails else 'ok'))
            for f in fails.get(name, [])[:3]:
                print('    ' + f)
    return count, len(fails)


TEXT = 0xB100                     # a string's text, given by address


def string_tests(pair, rng, n, only, verbose):
    """STR$, CHR$, a$+b$, the fixed-length LET, USR "a", VAL: the string or
    number they leave on the stack (STR$ and VAL: up to the ROM's own error
    in the last digit or bit, against the exact value)."""
    sys.path.insert(0, os.path.join(ROOT, 'test', 'fp'))
    import strtest
    from fptest import value
    fails = {}
    count = 0

    def sdesc(addr, length):
        return bytes([0, addr & 255, addr >> 8, length & 255, length >> 8])

    def top_string(st):
        m, e = st['m'], st['stkend']
        d = m[e - 5:e]
        a, ln = d[1] | d[2] << 8, d[3] | d[4] << 8
        return bytes(m[a:a + ln])

    def rtext(rng):
        k = rng.random()
        if k < 0.6:
            v = rnum(rng)
            t = strtest.model(v)
            return t.encode() if rng.random() < 0.8 else (' ' + t + ' ').encode()
        t = bytes(rng.choice(b'0123456789. eEab') for _ in range(rng.randrange(0, 8)))
        return b'-' * rng.randrange(0, 3) + t       # (no arithmetic: VAL reads a number)

    tests = ('STR$', 'CHR$', 'STRS-ADD', 'L-STRING', 'USR$', 'VAL')
    for name in tests:
        if only and not any(o in name for o in only):
            continue
        count += 1
        for i in range(n):
            regs = {}
            texts = []
            if name == 'STR$':
                nums, addr = [rnum(rng)], 0x361F
            elif name == 'CHR$':
                nums, addr, regs = [], 0x35D0, dict(a=rng.randrange(256))
            elif name == 'STRS-ADD':
                la, lb = rng.randrange(0, 20), rng.randrange(0, 20)
                texts = [(TEXT, bytes(rng.randrange(32, 127) for _ in range(la))),
                         (TEXT + 0x40, bytes(rng.randrange(32, 127) for _ in range(lb)))]
                nums, addr = [sdesc(TEXT, la), sdesc(TEXT + 0x40, lb)], 0x359C
            elif name == 'L-STRING':
                ls, ld = rng.randrange(0, 20), rng.randrange(0, 20)
                texts = [(TEXT, bytes(rng.randrange(32, 127) for _ in range(ls))),
                         (TEXT + 0x40, bytes(rng.randrange(32, 127) for _ in range(ld)))]
                nums, addr, regs = [sdesc(TEXT, ls)], 0x2B7F, dict(hl=TEXT + 0x40, bc=ld)
            elif name == 'USR$':
                c = rng.choice([rng.randrange(0x41, 0x5B), rng.randrange(0x61, 0x7B),
                                rng.randrange(0x90, 0xA8), rng.randrange(256)])
                ln = 1 if rng.random() < 0.9 else rng.randrange(0, 3)
                texts = [(TEXT, bytes([c, c]))]
                nums, addr = [sdesc(TEXT, ln)], 0x34BC
            else:
                t = rtext(rng)
                texts = [(TEXT, t)]
                nums, addr, regs = [sdesc(TEXT, len(t))], 0x35DE, dict(bc=0x1D00)
            pair.setup(nums, regs, boot=True)
            for zx in (pair.rom, pair.ux):
                for a_, t_ in texts:
                    zx.mem[a_:a_ + len(t_)] = t_
                zx.mem[0x5C7B:0x5C7D] = bytes([0x58, 0xFF])        # UDG
                zx.set(**regs)
            sym = '@r%04X' % addr
            a = pair.go('rom', addr)
            b = pair.go('ux', pair.sym[sym])
            bad = []
            if a['errnr'] != b['errnr'] and not (name == 'VAL' and 0xFF not in (a['errnr'], b['errnr'])):
                # (VAL of what is not a number: both stop, the report may differ - the
                # ROM parses it as an expression, 2 for a variable, C for its syntax)
                bad.append('ERR_NR: ROM %02X, ours %02X' % (a['errnr'], b['errnr']))
            elif a['errnr'] == 0xFF:
                if name == 'L-STRING':
                    x, y = bytes(a['m'][TEXT + 0x40:TEXT + 0x60]), bytes(b['m'][TEXT + 0x40:TEXT + 0x60])
                    if x != y:
                        bad.append('the destination: ROM %r, ours %r' % (x, y))
                elif name in ('USR$', 'VAL'):
                    x, y = stack_bytes(a)[-5:], stack_bytes(b)[-5:]
                    if x != y:
                        vx, vy = value(x), value(y)
                        ok = name == 'VAL' and abs(vx - vy) <= abs(vx) * 2 ** -30
                        if not ok:
                            bad.append('result: ROM %s, ours %s' % (x.hex(), y.hex()))
                else:
                    x, y = top_string(a), top_string(b)
                    if x != y and not (name == 'STR$' and y.decode() == strtest.model(nums[0])):
                        bad.append('string: ROM %r, ours %r' % (x, y))
                if (a['stkend'] - a['stkbot'] != b['stkend'] - b['stkbot'] and name != 'STR$'):
                    # (the ROM's STR$ of a number below 1 leaves a number under the string)
                    bad.append('stack size: ROM %d, ours %d' % (a['stkend'] - a['stkbot'],
                                                                 b['stkend'] - b['stkbot']))
            if bad:
                fails.setdefault(name, []).append('%s %s: %s' % (
                    ' '.join(x.hex() for x in nums), texts and texts[0][1], '; '.join(bad)))
        if verbose or name in fails:
            print('%-12s %s' % (name, 'FAIL (%d)' % len(fails[name]) if name in fails else 'ok'))
            for f in fails.get(name, [])[:3]:
                print('    ' + f)
    return count, len(fails)


def key_tests(pair, rng, n, only, verbose):
    """INKEY$ (the runtime's: KEY-SCAN, K-TEST, K-DECODE) and KEYBOARD (as
    rbc's PAUSE reads KSTATE) on every key, every shift, CAPS LOCK on and
    off, and two keys at once, the half-rows given on port FEh alike."""
    if only and not any(o in 'INKEY$ KEYBOARD' for o in only):
        return 0, 0
    sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux', 'rbc'))
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'kb', os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux', 'rbc', 'keyboard.py'))
    kb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kb)
    held = set()

    def port(p):
        if p & 0xFF != kb.PORT:
            return 0xFF
        v = 0x1F
        for r, (hi, keys) in enumerate(kb.ROWS):
            if not (p >> 8) & (1 << r):
                for b, k in enumerate(keys):
                    if k in held:
                        v &= ~(1 << b)
        return v | 0xE0
    machines = [zxcore.Spectrum(read_port=port), zxcore.Spectrum(read_port=port)]
    machines[1].mem[ORG:ORG + len(pair.image)] = pair.image
    sym = pair.sym
    fails = []

    def inkey(zx, rom, caps_lock):
        zx.mem[0x4000:] = booted()
        if not rom:
            zx.mem[ORG:ORG + len(pair.image)] = pair.image
        zx.mem[0x5C6A] = (zx.mem[0x5C6A] & ~8) | (8 if caps_lock else 0)
        a = (lambda n, x: x) if rom else (lambda n, x: sym[n])
        ks, kt, kd, kbd = a('@r028E', 0x028E), a('@r031E', 0x031E), a('@r0333', 0x0333), a('@r02BF', 0x02BF)
        code = [0xCD, ks & 255, ks >> 8, 0x0E, 0, 0x20, 12, 0xCD, kt & 255, kt >> 8, 0x30, 7,
                0x15, 0x5F, 0xCD, kd & 255, kd >> 8, 0x18, 2, 0x3E, 0xFF,  # none: FFh
                0x32, 0x00, 0xD0,                                         # ld (D000h),a
                0xCD, kbd & 255, kbd >> 8, 0xC3, TRAP & 255, TRAP >> 8]
        zx.mem[CODE:CODE + len(code)] = bytes(code)
        zx.mem[SP - 2:SP] = bytes([TRAP & 255, TRAP >> 8])
        zx.mem[0x5C3D:0x5C3F] = bytes([(SP - 2) & 255, (SP - 2) >> 8])
        zx.set(iy=0x5C3A, sp=SP - 2, iff1=False, iff2=False, pc=CODE)
        if not zx.run((TRAP,), zx.t + 20_000_000):
            raise RuntimeError('INKEY$ did not return')
        return zx.mem[0xD000], zx.mem[0x5C00] != 0xFF or zx.mem[0x5C04] != 0xFF
    cases = []
    keys = [k for _, ks in kb.ROWS for k in ks if k not in kb.SHIFTS]
    for k in keys:
        for sh in ((), ('CAPS',), ('SYMBOL',), ('CAPS', 'SYMBOL')):
            for cl in (0, 1):
                cases.append((set((k,) + sh), cl))
    for sh in ((), ('CAPS',), ('SYMBOL',), ('CAPS', 'SYMBOL')):
        cases.append((set(sh), 0))
    for _ in range(n):
        cases.append((set(rng.sample(keys, 2)), 0))
    for keyset, cl in cases:
        held.clear()
        held.update(keyset)
        x = inkey(machines[0], True, cl)
        y = inkey(machines[1], False, cl)
        if x != y:
            fails.append('%s%s: ROM %r, ours %r' % ('+'.join(sorted(keyset)), ' (CAPS LOCK)' if cl else '',
                                                    x, y))
    if verbose or fails:
        print('%-12s %s' % ('INKEY$', 'FAIL (%d of %d)' % (len(fails), len(cases)) if fails else 'ok'))
        for f in fails[:int(os.environ.get("ROMDIFF_SHOW", "8"))]:
            print('    ' + f)
    return 1, 1 if fails else 0


def graphics_tests(pair, rng, n, only, verbose):
    """PLOT, DRAW and SCREEN$ on the booted screen: the display file, COORDS,
    the result (SCREEN$: the string)."""
    fails = {}
    count = 0

    def colours():
        out = []
        for _ in range(rng.randrange(0, 4)):
            c = rng.randrange(0x10, 0x16)
            v = rng.choice([0, 1, 2, 7, 8, 9] if c < 0x12 else [0, 1, 8] if c < 0x14 else [0, 1])
            out.append(('@r2211', 0x2211, c, 0, v << 8))
        return out

    def stack(v):
        ops = [('@r2D2B', 0x2D2B, 0, abs(v), 0)]
        if v < 0:
            ops.append(('@r346E', 0x346E, 0, 0, 0))
        return ops
    for name in ('PLOT', 'DRAW', 'SCREEN$'):
        if only and not any(o in name for o in only):
            continue
        count += 1
        for i in range(n):
            pre, chars, st = [], [], 2
            if name == 'PLOT':
                for _ in range(rng.randrange(1, 6)):
                    pre += colours()
                    pre.append(('@r22DF', 0x22DF, 0, rng.randrange(0, 180) << 8 | rng.randrange(256), 0))
            elif name == 'DRAW':
                x0, y0 = rng.randrange(256), rng.randrange(176)
                pre = colours() + [('@r22E5', 0x22E5, 0, y0 << 8 | x0, 0)]
                for _ in range(rng.randrange(1, 4)):
                    dx = rng.randrange(-255, 256) if rng.random() < 0.3 else rng.randrange(-x0, 256 - x0)
                    dy = rng.randrange(-175, 176) if rng.random() < 0.3 else rng.randrange(-y0, 176 - y0)
                    pre += stack(dx) + stack(dy) + [('@r2477', 0x2477, 0, 0, 0)]
            else:
                chars = stream(rng, rng.randrange(20, 300))
                st = 2
            post = []
            if name == 'SCREEN$':
                post = [('@r2538', 0x2538, 0, rng.randrange(32) << 8 | rng.randrange(0, 22), 0)]
            a, b = print_case(pair, rng, st, chars, pre, post)
            bad = print_compare(a, b)
            for nm, addr, ln in (('COORDS', 0x5C7D, 2),):
                if bytes(a.mem[addr:addr + ln]) != bytes(b.mem[addr:addr + ln]):
                    bad.append('%s: ROM %s, ours %s' % (nm, bytes(a.mem[addr:addr + ln]).hex(),
                                                        bytes(b.mem[addr:addr + ln]).hex()))
            if name == 'SCREEN$' and a.mem[0x5C3A] == 0xFF:
                def top(z):
                    e = z.mem[0x5C65] | z.mem[0x5C66] << 8
                    d = z.mem[e - 5:e]
                    ad, ln = d[1] | d[2] << 8, d[3] | d[4] << 8
                    return bytes(z.mem[ad:ad + ln])
                if top(a) != top(b):
                    bad.append('SCREEN$: ROM %r, ours %r' % (top(a), top(b)))
            if bad:
                fails.setdefault(name, []).append('%s: %s' % (
                    ' '.join('%s(%X,%X)' % (o[0], o[3], o[4]) for o in pre)[:200], '; '.join(bad[:3])))
        if verbose or name in fails:
            print('%-12s %s' % (name, 'FAIL (%d)' % len(fails[name]) if name in fails else 'ok'))
            for f in fails.get(name, [])[:3]:
                print('    ' + f)
    return count, len(fails)


def input_tests(pair, rng, n, only, verbose):
    """ED-COPY, CLEAR-SP and the end of INPUT on random lines typed at INPUT
    (the workspace), cursors and earlier echoes: the screen, the lower
    screen's positions, ECHO_E, DF_SZ, K_CUR, the workspace."""
    fails = {}
    count = 0
    for name, addr in (('ED-COPY', 0x111D), ('CLEAR-SP', 0x1097), ('INPUT-END', 0x20A0)):
        if only and not any(o in name for o in only):
            continue
        count += 1
        for i in range(n):
            text = bytes(rng.choice([rng.randrange(32, 128), rng.randrange(0x80, 0xA5)])
                         for _ in range(rng.choice([0, 1, 5, 20, 40, 70])))
            cur = rng.randrange(0, len(text) + 1)
            prompt = []                 # whole items: characters, graphics, colours
            for _ in range(rng.randrange(0, 25)):
                k = rng.random()
                if k < 0.7:
                    prompt.append(rng.randrange(32, 128))
                elif k < 0.85:
                    prompt.append(rng.randrange(0x80, 0xA5))
                else:
                    c = rng.randrange(0x10, 0x16)
                    prompt += [c, rng.choice([0, 1, 2, 7] if c < 0x12 else [0, 1])]
            sts = []
            for which, zx in (('rom', pair.rom), ('ux', pair.ux)):
                m = zx.mem
                m[0x4000:] = booted()
                if which == 'ux':
                    pair.install(m)
                w = lambda a, v: m.__setitem__(slice(a, a + 2), bytes([v & 255, v >> 8]))  # noqa
                ws = 0xA000
                m[ws:ws + len(text) + 1] = text + b'\r'
                w(0x5C61, ws)
                w(0x5C63, ws + len(text) + 1)
                w(0x5C65, ws + len(text) + 1)
                w(0x5C59, 0x9F00)
                w(0x5C5B, ws + cur)
                m[0x5C71] |= 0x20
                m[0x5C6A] = (m[0x5C6A] & ~8) | random.Random(i).choice([0, 8])
                sym = (lambda nm, a: a) if which == 'rom' else (lambda nm, a: pair.sym[nm])
                k = sym('@r1601', 0x1601)
                code = [0x3E, 0, 0xCD, k & 255, k >> 8]           # channel K: the prompt
                p10 = sym('@r10', 0x10)
                for c in prompt:
                    code += [0x3E, c, 0xCD, p10 & 255, p10 >> 8]
                code += [0x2A, 0x8A, 0x5C, 0x22, 0x82, 0x5C]       # ECHO_E = S_POSNL
                t = sym('@r%04X' % addr, addr)
                code += [0xCD, t & 255, t >> 8]
                if name == "ED-COPY" and random.Random(i).random() < 0.5:
                    code += [0xCD, t & 255, t >> 8]                # twice: the echo's end
                code += [0xC3, TRAP & 255, TRAP >> 8]
                m[CODE:CODE + len(code)] = bytes(code)
                m[SP - 2:SP] = bytes([TRAP & 255, TRAP >> 8])
                m[0x5C3D:0x5C3F] = bytes([(SP - 2) & 255, (SP - 2) >> 8])
                m[0x5C3A] = 0xFF
                zx.set(iy=0x5C3A, sp=SP - 2, iff1=False, iff2=False, a=0, bc=0, de=0, hl=0, pc=CODE)
                if not zx.run((TRAP,), zx.t + 100_000_000):
                    raise RuntimeError('%s: %s did not return' % (which, name))
                sts.append(zx)
            a, b = sts
            bad = print_compare(a, b)
            for nm, ad, ln in (('ECHO_E', 0x5C82, 2), ('K_CUR', 0x5C5B, 2), ('STKBOT', 0x5C63, 2),
                               ('MODE', 0x5C41, 1)):
                if bytes(a.mem[ad:ad + ln]) != bytes(b.mem[ad:ad + ln]):
                    bad.append('%s: ROM %s, ours %s' % (nm, bytes(a.mem[ad:ad + ln]).hex(),
                                                        bytes(b.mem[ad:ad + ln]).hex()))
            if bytes(a.mem[0xA000:0xA060]) != bytes(b.mem[0xA000:0xA060]):
                bad.append('the workspace')
            if bad:
                fails.setdefault(name, []).append('%r cursor %d after the prompt %s: %s' % (
                    text, cur, bytes(prompt).hex(), '; '.join(bad[:3])))
        if verbose or name in fails:
            print('%-12s %s' % (name, 'FAIL (%d)' % len(fails[name]) if name in fails else 'ok'))
            for f in fails.get(name, [])[:3]:
                print('    ' + f)
    return count, len(fails)


def beep_tests(pair, rng, n, only, verbose):
    """BEEP on random durations and pitches (in range and out): the report,
    the speaker's toggles (within 2), the tone's length, first toggle to
    last (within 5%)."""
    if only and not any(o in 'BEEP' for o in only):
        return 0, 0
    toggles = [0]

    span = [None, None]
    machines = []

    def wp(p, v):
        if p & 0xFF == 0xFE:
            toggles[0] += 1
            t = machines[0].t if machines else 0
            span[0] = t if span[0] is None else span[0]
            span[1] = t
    rom = zxcore.Spectrum(write_port=lambda p, v: (machines.__setitem__(slice(None), [rom]), wp(p, v)))
    ux = zxcore.Spectrum(write_port=lambda p, v: (machines.__setitem__(slice(None), [ux]), wp(p, v)))
    fails = []
    cases = [(0.01, 0), (0.01, -60), (0.01, -61), (0.01, 69), (0.01, 70), (-0.01, 0), (0, 0),
             (10.5, 0), (0.1, 12), (0.05, -24)]
    cases += [(round(rng.uniform(0, 0.08), 3), round(rng.uniform(-62, 71), 1)) for _ in range(n // 4)]
    for d, p in cases:
        st = []
        for which, zx in (('rom', rom), ('ux', ux)):
            m = zx.mem
            m[0x4000:] = booted()
            if which == 'ux':
                pair.install(m)
            stk = 0xA000
            for k, v in enumerate((d, p)):
                m[stk + 5 * k:stk + 5 * k + 5] = bytes(five(v))
            m[0x5C63:0x5C65] = bytes([0, 0xA0])
            m[0x5C65:0x5C67] = bytes([(stk + 10) & 255, (stk + 10) >> 8])
            m[SP - 2:SP] = bytes([TRAP & 255, TRAP >> 8])
            m[0x5C3D:0x5C3F] = bytes([(SP - 2) & 255, (SP - 2) >> 8])
            m[0x5C3A] = 0xFF
            m[SP - 4:SP - 2] = bytes([TRAP & 255, TRAP >> 8])
            toggles[0] = 0
            span[:] = [None, None]
            zx.set(iy=0x5C3A, sp=SP - 4, iff1=False, iff2=False,
                   pc=0x03F8 if which == 'rom' else pair.sym['@r03F8'])
            if not zx.run((TRAP,), zx.t + 100_000_000):
                raise RuntimeError('BEEP did not return')
            st.append((m[0x5C3A], toggles[0], (span[1] - span[0]) if span[0] is not None else 0))
        (ea, ta, ca), (eb, tb, cb) = st
        if ea != eb or abs(ta - tb) > 2 or (ta > 20 and abs(ca - cb) > 0.05 * ca):
            fails.append('BEEP %s,%s: ROM %02X %d toggles %d T, ours %02X %d toggles %d T'
                         % (d, p, ea, ta, ca, eb, tb, cb))
    if verbose or fails:
        print('%-12s %s' % ('BEEP', 'FAIL (%d of %d)' % (len(fails), len(cases)) if fails else 'ok'))
        for f in fails[:6]:
            print('    ' + f)
    return 1, 1 if fails else 0


def main():
    args = sys.argv[1:]
    verbose = '-v' in args
    args = [x for x in args if x != '-v']
    n = int(args[0]) if args and args[0].isdigit() else 200
    only = [x.upper() for x in args if not x.isdigit()]
    pair = Pair()
    rng = random.Random(48)
    fails = {}
    tested = 0
    todo = [('%04X' % a, a) for a in CASES] + [('RST28:' + k, k) for k in CALC]
    for name, key in todo:
        if only and not any(o in name for o in only):
            continue
        sym = '@r%04X' % key if isinstance(key, int) else '@r28'
        if sym not in pair.sym:
            continue
        tested += 1
        for i in range(n):
            if isinstance(key, int):
                n_stack, regs, extra, outs, flags = CASES[key]
                nums = [rnum(rng) for _ in range(n_stack)]
                if extra in ('num', 'smallnum'):
                    b = rnum(rng) if extra == 'num' else bytes(five(rng.randint(-65535, 65535)))
                    if extra == 'smallnum' and b[0]:
                        b = bytes(5)
                    for zx in (pair.rom, pair.ux):
                        zx.mem[NUM:NUM + 5] = b
                r = {}
                if extra == 'random':
                    r = dict(a=rng.randrange(256), bc=rng.randrange(65536), de=rng.randrange(65536))
                if extra == 'carry':
                    for zx in (pair.rom, pair.ux):
                        zx.mem[NUM:NUM + 5] = bytes(rng.randrange(256) for _ in range(5))
                    r = dict(f=rng.randrange(2))
                p = pair.setup(nums, r)
                if regs:
                    for zx in (pair.rom, pair.ux):
                        zx.set(**regs(p))
                a = pair.go('rom', key)
                b = pair.go('ux', pair.sym[sym])
                bad = compare(name, outs, flags, a, b)
                what = ' '.join(x.hex() for x in nums)
            else:
                seq = CALC[key] or [rng.randrange(9, 15), 0x38]
                nums = [rnum(rng) for _ in range(2)]
                if key == 'cmp' and rng.random() < 0.3:
                    nums[1] = nums[0]
                if key == 'rnd':
                    nums = [bytes(five(rng.randrange(65536)))]
                for zx, call in ((pair.rom, [0xEF]), (pair.ux, [0xCD, pair.sym['@r28'] & 255,
                                                              pair.sym['@r28'] >> 8])):
                    code = call + seq + [0xC3, TRAP & 255, TRAP >> 8]
                    zx.mem[CODE:CODE + len(code)] = bytes(code)
                pair.setup(nums, dict(bc=rng.randrange(9, 15) << 8))
                a = pair.go('rom', CODE)
                b = pair.go('ux', CODE)
                bad = compare(name, ['stack', 'stkend', 'hl', 'de', 'errnr'], 0, a, b)
                what = '%s on %s' % (' '.join('%02X' % x for x in seq), ' '.join(x.hex() for x in nums))
            if bad:
                fails.setdefault(name, []).append('%s: %s' % (what, '; '.join(bad)))
        status = 'FAIL (%d of %d)' % (len(fails[name]), n) if name in fails else 'ok'
        if verbose or name in fails:
            print('%-12s %s' % (name, status))
            for f in fails.get(name, [])[:3]:
                print('    ' + f)
    pt, pf = print_tests(pair, rng, n, only, verbose)
    rt, rf = room_tests(pair, rng, n, only, verbose)
    st, sf = string_tests(pair, rng, n, only, verbose)
    kt, kf = key_tests(pair, rng, n, only, verbose)
    gt, gf = graphics_tests(pair, rng, n, only, verbose)
    it, if_ = input_tests(pair, rng, n, only, verbose)
    bt, bf = beep_tests(pair, rng, n, only, verbose)
    tested += pt + rt + st + kt + gt + it + bt
    nf = len(fails) + pf + rf + sf + kf + gf + if_ + bf
    print('romdiff: %d routines, %d differ: %s' % (tested, nf, 'FAIL' if nf else 'ok'))
    return 1 if nf else 0


if __name__ == '__main__':
    sys.exit(main())
