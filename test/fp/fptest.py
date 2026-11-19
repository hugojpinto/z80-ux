#!/usr/bin/env python3
"""The clean-room float engine (drivers/fp/fp.asm), tested.

    python3 test/fp/fptest.py [-v] [N]

The engine is assembled at 8000h and run on the SDK's Z80 (zxcore).
Accuracy is measured against the true value (Python's double precision,
21 bits beyond the format's 32), in units of the last place (ulp) or,
near zero, absolute; the Spectrum ROM's own error on the same inputs is
shown beside it.  The ROM's calculator (sdk/bin/py/rcc/romfp.py, on the
same emulator) decides which inputs have no result: the same inputs must
fail on both (the ROM is an oracle for behaviour, not a source of code).
N random inputs per operation (default 300), and fixed edge cases.
"""
import math
import os
import random
import subprocess
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
import zxcore  # noqa: E402
from rcc import romfp  # noqa: E402

SJ = os.environ.get('SJASMPLUS', os.path.join(ROOT, 'fdd3000', 'tools', 'bin', 'sjasmplus'))
ORG, WS, X, Y, R, SP, TRAP = 0x8000, 0xC000, 0xC100, 0xC108, 0xC110, 0xF000, 0xFF00
NAMES = {1: 'add', 2: 'sub', 3: 'mul', 4: 'div', 5: 'pow', 6: 'abs', 7: 'neg', 8: 'trunc',
         9: 'exp', 10: 'ln', 11: 'sin', 12: 'cos', 13: 'tan', 14: 'asin', 15: 'acos',
         16: 'atan', 17: 'sqrt'}


def assemble():
    work = os.path.join(ROOT, 'build', 'fptest')
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, 't.asm'), 'w') as f:
        f.write('        DEVICE NOSLOT64K\n        org 0%04Xh\nmodbeg:\n'
                '        include "%s"\nmodend:\n'
                '        SAVEBIN "fp.bin", modbeg, modend-modbeg\n'
                % (ORG, os.path.join(ROOT, 'drivers', 'fp', 'fp.asm')))
    r = subprocess.run([SJ, '--nologo', '--msg=war', '-I' + os.path.join(ROOT, 'drivers', 'fp'),
                        't.asm'], cwd=work, capture_output=True, text=True)
    if r.returncode or 'error' in (r.stdout + r.stderr).lower():
        raise SystemExit(r.stdout + r.stderr)
    return open(os.path.join(work, 'fp.bin'), 'rb').read()


def value(b):
    """Five bytes -> Fraction."""
    if b[0] == 0:
        w = b[2] | b[3] << 8
        return Fraction(w - 65536 if b[1] else w)
    m = (b[1] | 0x80) << 24 | b[2] << 16 | b[3] << 8 | b[4]
    v = Fraction(m, 2 ** 32) * Fraction(2) ** (b[0] - 128)
    return -v if b[1] & 0x80 else v


def five(v):
    """A Python number -> five bytes (to nearest)."""
    v = Fraction(v)
    if v == 0:
        return bytes(5)
    if v.denominator == 1 and abs(v) <= 65535:
        n = int(v)
        w = n & 0xFFFF
        return bytes([0, 0xFF if n < 0 else 0, w & 255, w >> 8, 0])
    s, a = (0x80, -v) if v < 0 else (0, v)
    e = 0
    while a >= 1:
        a /= 2
        e += 1
    while a < Fraction(1, 2):
        a *= 2
        e -= 1
    m = round(a * 2 ** 32)
    if m == 2 ** 32:
        m >>= 1
        e += 1
    return bytes([e + 128, (m >> 24 & 0x7F) | s, m >> 16 & 255, m >> 8 & 255, m & 255])


class Engine:
    def __init__(self, code):
        self.zx = zxcore.Spectrum()
        self.zx.mem[ORG:ORG + len(code)] = code
        self.ticks = 0

    def run(self, op, x, y=None):
        m = self.zx.mem
        m[X:X + 5] = x
        m[Y:Y + 5] = y if y is not None else bytes(5)
        self.zx.set(a=op, hl=X, de=Y, bc=R, ix=WS, iy=0x1234, sp=SP)
        t0 = self.zx.t
        if not self.zx.call(ORG, TRAP, tlimit=20_000_000):
            raise RuntimeError('op %d did not return' % op)
        self.ticks = self.zx.t - t0
        if self.zx.ix != WS or self.zx.iy != 0x1234 or self.zx.sp != SP:
            raise RuntimeError('op %d: IX, IY or SP not kept' % op)
        if self.zx.flags & 1:
            return None
        if op == 18:
            return (self.zx.bc, self.zx.a)
        return bytes(m[R:R + 5])


def rom_run(rom, op, x, y=None):
    try:
        return rom.op(op, x, y)
    except romfp.FPError:
        return None


TRUE = {1: lambda x, y: x + y, 2: lambda x, y: x - y, 3: lambda x, y: x * y,
        4: lambda x, y: x / y, 5: lambda x, y: x ** y, 6: abs, 7: lambda x: -x,
        8: math.trunc, 9: math.exp, 10: math.log, 11: math.sin, 12: math.cos,
        13: math.tan, 14: math.asin, 15: math.acos, 16: math.atan, 17: math.sqrt}


def truth(op, x, y):
    """The exact result for the inputs as given (Fractions for + - * /)."""
    if op in (1, 2, 3, 4, 6, 7, 8):
        return Fraction(TRUE[op](x, y) if op <= 4 else TRUE[op](x))
    xf = float(x)
    return Fraction(TRUE[op](xf, float(y)) if op == 5 else TRUE[op](xf))


TINY = Fraction(1, 2 ** 128)


def ulps(a, b):
    """The distance of a from b, in ulps of b (32-bit mantissa)."""
    if a == b:
        return 0
    big = max(abs(a), abs(b))
    if big == 0:
        return 0
    e = math.floor(math.log2(big))
    return float(abs(a - b) / Fraction(2) ** (e - 31))


def gen(op, rnd):
    def num(lo, hi, frac=True):
        v = rnd.uniform(lo, hi)
        return five(v if frac else round(v))
    if op in (1, 2):
        return num(-1e6, 1e6), num(-1e6, 1e6) if rnd.random() < .7 else num(-1000, 1000, False)
    if op in (3, 4):
        e = rnd.uniform(-30, 30)
        return five(rnd.choice((-1, 1)) * 2 ** e), five(rnd.choice((-1, 1)) * 2 ** rnd.uniform(-30, 30))
    if op == 5:
        return num(0.001, 100), num(-10, 10) if rnd.random() < .6 else num(-12, 12, False)
    if op in (6, 7, 8):
        return num(-1e5, 1e5), None
    if op == 9:
        return num(-80, 80), None
    if op == 10:
        return five(2 ** rnd.uniform(-60, 60)), None
    if op in (11, 12):
        return num(-20, 20), None
    if op == 13:
        return num(-1.5, 1.5), None
    if op in (14, 15):
        return num(-1, 1), None
    if op == 16:
        return five(rnd.choice((-1, 1)) * 2 ** rnd.uniform(-20, 20)), None
    if op == 17:
        return five(2 ** rnd.uniform(-60, 60)), None


EDGE = {
    1: [(0, 0), (1, -1), (65535, 1), (-65535, -1), (0.1, 0.2), (1e30, -1e30), (1e38, 1e38)],
    2: [(5, 5), (0, 3), (-65536, 1), (1, 1e-12)],
    3: [(0, 5), (256, 256), (-3, 7), (1e30, 1e30), (1e-30, 1e-30), (3, 0.5)],
    4: [(1, 0), (0, 3), (6, 3), (1, 3), (-7, 2), (1, 1e-38)],
    5: [(0, 0), (0, 2), (0, -1), (-2, 2), (2, 10), (2, 0.5), (10, -2), (3, 0), (2, 127), (2, 128)],
    6: [(0,), (-5,), (-65536,), (-0.25,)],
    7: [(0,), (65536,), (-65535,), (1.5,)],
    8: [(-3.7,), (3.7,), (0.5,), (-0.5,), (65535.9,), (1e10,), (-1e10,)],
    9: [(0,), (1,), (88,), (89,), (-100,), (-88,), (1e-9,)],
    10: [(0,), (-1,), (1,), (2,), (0.5,), (1e38,), (1e-38,)],
    11: [(0,), (math.pi,), (math.pi / 2,), (1e-6,), (1000,), (-math.pi / 6,)],
    12: [(0,), (math.pi,), (math.pi / 2,), (100,), (-1,)],
    13: [(0,), (math.pi / 4,), (1,), (-1.2,)],
    14: [(0,), (1,), (-1,), (0.5,), (2,), (-1.0000001,), (0.99999,)],
    15: [(0,), (1,), (-1,), (0.5,), (2,)],
    16: [(0,), (1,), (-1,), (1e6,), (-1e-6,), (0.2679,), (0.27,)],
    17: [(0,), (4,), (2,), (-1,), (1e38,), (1e-38,), (65535,), (100,), (0.25,)],
}

# accepted error: ulps of the result, or (near zero, for the periodic and
# inverse functions) absolute
LIMIT = {1: 1, 2: 1, 3: 1, 4: 1, 6: 0, 7: 0, 8: 0, 17: 1,
         5: 64, 9: 4, 10: 4, 11: 4, 12: 4, 13: 8, 14: 8, 15: 8, 16: 4}
ABS = {11: 1e-9, 12: 1e-9, 13: 1e-9, 14: 1e-9, 15: 1e-9, 16: 1e-9, 10: 1e-9}


def main():
    args = [a for a in sys.argv[1:] if a != '-v']
    verbose = '-v' in sys.argv
    n = int(args[0]) if args else 300
    eng = Engine(assemble())
    rom = romfp.RomFP()
    rnd = random.Random(1982)
    fails = []
    for op in range(1, 18):
        cases = [tuple(five(v) for v in c) for c in EDGE[op]]
        cases += [gen(op, rnd) for _ in range(n)]
        worst, wcase, slow, romw = 0.0, None, 0, 0.0
        for c in cases:
            x, y = c[0], (c[1] if len(c) > 1 else None)
            if op > 5:
                y = None
            want = rom_run(rom, op, x, y)
            got = eng.run(op, x, y)
            slow = max(slow, eng.ticks)
            if (want is None) != (got is None):
                fails.append('%s(%s): engine %s, ROM %s' % (
                    NAMES[op], ', '.join(str(float(value(v))) for v in c if v is not None),
                    'error' if got is None else float(value(got)),
                    'error' if want is None else float(value(want))))
                continue
            if want is None:
                continue
            t = truth(op, value(x), value(y) if y is not None else None)
            a, b = value(got), value(want)
            err, rerr = ulps(a, t), ulps(b, t)
            if op in ABS and abs(a - t) <= ABS[op]:
                err = 0
            if op in ABS and abs(b - t) <= ABS[op]:
                rerr = 0
            if abs(t) < TINY and a == 0:    # below the smallest number: 0
                err = 0
            if abs(t) < TINY and b == 0:
                rerr = 0
            romw = max(romw, rerr)
            if err > worst:
                worst, wcase = err, (c, a, t)
        ok = worst <= LIMIT[op]
        line = '%-6s worst %6.1f ulp (limit %2d; ROM %7.1f)  slowest %7d T' % (
            NAMES[op], worst, LIMIT[op], romw, slow)
        if wcase and (verbose or not ok):
            c, a, b = wcase
            line += '   at %s: %r, true %r' % (
                ', '.join('%.10g' % float(value(v)) for v in c if v is not None), float(a), float(b))
        print(line)
        if not ok:
            fails.append('%s: %.1f ulp' % (NAMES[op], worst))
    # to integer
    for v in (0, 3.7, -3.7, 65535, 65535.5, 65536, -65535, 0.5, -1):
        got = eng.run(18, five(v))
        if got is None:
            if abs(math.trunc(v)) <= 65535:
                fails.append('toint(%s): error' % v)
            continue
        bc, a = got
        t = math.trunc(v)
        if bc != abs(t) or (a != 0) != (t < 0):
            fails.append('toint(%s): %d sign %02X' % (v, bc, a))
    for f in fails[:40]:
        print('FAIL:', f)
    print('fptest: %s (%d failures)' % ('FAIL' if fails else 'ok', len(fails)))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
