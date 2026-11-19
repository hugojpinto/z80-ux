#!/usr/bin/env python3
"""rbc --ux's clean-room routines against the 48K ROM's, one by one.

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
            for n in ('librbc.ssa', 'libc48.ssa')]
    names = sorted(s for m in libs[0] for s in m.defs() if s.startswith('@r'))
    stub = '        section text\n        global start\nstart:\n' + ''.join(
        '        dw %s\n' % n for n in names + ['@romfp'])
    image, bss, ent, gaddr, chosen = rld.link([rld.Obj(ras.assemble_text(stub, 'stub'), 'stub')],
                                              libs, org=ORG)
    return bytes(image), {n: ORG + a for n, (a, r) in gaddr.items()}


class Pair:
    """The ROM's machine and ours, set up alike."""

    def __init__(self):
        self.image, self.sym = build()
        self.rom = zxcore.Spectrum()
        self.ux = zxcore.Spectrum()
        self.ux.mem[ORG:ORG + len(self.image)] = self.image
        e = self.sym['@romfp']                          # system call 42: libux's ROM adapter
        self.ux.mem[0x6003:0x6008] = bytes([0x21, e & 255, e >> 8, 0xB7, 0xC9])   # ld hl,e / or a / ret

    def setup(self, nums, regs):
        out = []
        for zx in (self.rom, self.ux):
            m = zx.mem
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
    print('romdiff: %d routines, %d differ: %s' % (tested, len(fails), 'FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
