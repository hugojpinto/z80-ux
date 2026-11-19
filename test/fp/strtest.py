#!/usr/bin/env python3
"""Numbers to text and back (sdk/bin/py/libux/fstr.asm), tested.

    python3 test/fp/strtest.py [-v] [N]

@fstr and @fval are linked from libux's libc48.ssa at 8000h and run on
the SDK's Z80 (zxcore):
  - @fstr against the exact value rounded to 8 significant digits in the
    Spectrum's format (which test/fp/romtext.py's oracle, the 48K ROM's own
    PRINT-FP, must agree with wherever the ROM's digits are right: it gets
    the eighth digit wrong now and then; those are counted, not failed);
  - @fval: the exact value of the text, rounded to the format: at most
    one unit in the last place (it reads up to 9 significant digits), and
    whole numbers below 65536 exactly, in the small-integer form;
  - the round trip: @fval of @fstr's text gives the number back to 8
    digits.
N random numbers (default 2000), and fixed edge cases.
"""
import math
import os
import random
import subprocess
import sys
from decimal import Decimal, ROUND_HALF_UP, getcontext
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
import zxcore  # noqa: E402
import ras  # noqa: E402
import rld  # noqa: E402
import romtext  # noqa: E402
from fptest import value, five  # noqa: E402

getcontext().prec = 80
ORG, X, BUF, TRAP, SP = 0x8000, 0xC000, 0xC010, 0xFF00, 0xF000
STUB = '''        section text
        global start
start:  call @fstr
        call @fval
        ret
'''


def build():
    subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux', 'build.py')],
                   check=True, capture_output=True)
    lib = os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux', 'libc48.ssa')
    arch = rld.read_archive(open(lib, 'rb').read(), lib)
    image, bss, ent, gaddr, chosen = rld.link([rld.Obj(ras.assemble_text(STUB, 'stub'), 'stub')], [arch], org=ORG)
    size = len(image) - 7 + bss       # less the stub
    return bytes(image), {n: ORG + a for n, (a, r) in gaddr.items()}, size


def model(b):
    """The Spectrum's PRINT of the exact value, 8 digits rounded half up."""
    v = value(b)
    if v == 0:
        return '0'
    s = '-' if v < 0 else ''
    d = Decimal(abs(v).numerator) / Decimal(abs(v).denominator)
    e = d.adjusted() + 1
    q = d.scaleb(-e).quantize(Decimal('1e-8'), ROUND_HALF_UP)
    if q >= 1:
        q, e = q / 10, e + 1
    digs = str(q)[2:].rstrip('0')
    if e > 8 or e < -4:
        m = digs[0] + ('.' + digs[1:] if len(digs) > 1 else '')
        return s + m + 'E' + ('+' if e - 1 >= 0 else '-') + str(abs(e - 1))
    if e <= 0:
        return s + ('0' if e == 0 else '') + '.' + '0' * -e + digs
    if len(digs) <= e:
        return s + digs + '0' * (e - len(digs))
    return s + digs[:e] + '.' + digs[e:]


class Lib:
    def __init__(self):
        self.image, self.sym, self.size = build()
        self.zx = zxcore.Spectrum()
        self.zx.mem[ORG:ORG + len(self.image)] = self.image
        self.cycles = 0

    def _call(self, name, **regs):
        zx = self.zx
        t = zx.t
        zx.set(sp=SP, **regs)
        if not zx.call(self.sym[name], TRAP, tlimit=20_000_000):
            raise RuntimeError('%s did not return' % name)
        self.cycles = max(self.cycles, zx.t - t)

    def fstr(self, b):
        m = self.zx.mem
        m[X:X + 5] = bytes(b)
        m[BUF:BUF + 20] = b'\xAA' * 20
        self._call('@fstr', hl=X, de=BUF)
        end = m.index(0, BUF)
        if self.zx.hl != end:
            raise RuntimeError('@fstr: HL is not the NUL')
        return bytes(m[BUF:end]).decode('ascii')

    def fval(self, text):
        m = self.zx.mem
        t = text.encode('ascii') + b'\0'
        m[BUF:BUF + len(t)] = t
        m[X:X + 5] = b'\xAA' * 5
        self._call('@fval', hl=BUF, de=X)
        cf = self.zx.flags & 1
        return (None if cf else bytes(m[X:X + 5])), self.zx.hl - BUF


def exact_five(v):
    """Fraction -> the nearest five-byte number (half up), small form if whole."""
    if v == 0:
        return bytes(5)
    if v.denominator == 1 and abs(v) < 65536:
        n = int(v)
        w = n & 0xFFFF
        return bytes([0, 0xFF if n < 0 else 0, w & 255, w >> 8, 0])
    s = 0x80 if v < 0 else 0
    a = abs(v)
    e = a.numerator.bit_length() - a.denominator.bit_length()
    while Fraction(2) ** e > a:
        e -= 1
    while Fraction(2) ** (e + 1) <= a:
        e += 1
    m = a / Fraction(2) ** (e - 31)
    mi = int(m)
    if m - mi >= Fraction(1, 2):
        mi += 1
    if mi == 1 << 32:
        mi, e = 1 << 31, e + 1
    E = e + 129
    if E > 255:
        return None
    if E < 1:
        return bytes(5)
    return bytes([E, (mi >> 24 & 0x7F) | s, mi >> 16 & 255, mi >> 8 & 255, mi & 255])


def randoms(n, rng):
    out = []
    for i in range(n):
        k = rng.random()
        if k < 0.25:
            v = rng.uniform(-1e5, 1e5)
        elif k < 0.5:
            v = math.copysign(10 ** rng.uniform(-38, 38), rng.random() - .5)
        elif k < 0.7:
            v = rng.randint(-65535, 65535)
        elif k < 0.85:
            v = math.copysign(2 ** rng.uniform(-127, 126.9), rng.random() - .5)
        else:
            v = round(rng.uniform(-1000, 1000), rng.randint(0, 6))
        out.append(five(v))
    return out


EDGES = [0, 1, -1, 0.5, -0.5, 0.1, 0.05, 1e-5, 9.99999e-6, 1e-6, 1.5e-7, 99999999, 99999999.5,
         1e8, 12345678, 123456789, 65535, -65535, 65536, -65536, 1e38, 1.7e38, 3e-39, 1 / 3,
         math.pi, 2 / 3 * 1e-3, 1234567.89]
TEXTS = ['0', '1', '65535', '65536', '0.5', '.5', '5.', '1E3', '1e-3', '1.5E+7', '3.14159265',
         '123456789012', '0.000001', '1E38', '1.7E38', '1E-38', '1E-50', '00012', '0.000',
         '2.5e', '7E+', '12abc', '1.2.3', '1E39', '4294967295', '0.1', '100000000']


def main():
    args = [a for a in sys.argv[1:] if a != '-v']
    verbose = '-v' in sys.argv
    n = int(args[0]) if args else 2000
    lib = Lib()
    rom = romtext.RomText()
    rng = random.Random(2026)
    fails, romdiff = [], 0
    nums = [five(v) for v in EDGES] + [five(-v) for v in EDGES if v] + randoms(n, rng)
    nums.append(bytes([0, 0xFF, 0, 0, 0]))            # -65536 in the small form
    for b in nums:
        got, want = lib.fstr(b), model(b)
        if got != want:
            fails.append('fstr %s (%r): %r, not %r' % (b.hex(), float(value(b)), got, want))
            continue
        r = rom.text(b)
        if r != got:
            romdiff += 1
            if verbose:
                print('the ROM: %s %r, ours %r' % (b.hex(), r, got))
        back, used = lib.fval(got.lstrip('-'))
        if back is None or used != len(got.lstrip('-')):
            fails.append('fval %r: no number (%s)' % (got, used))
            continue
        if model(back) != got.lstrip('-'):
            fails.append('round trip %r -> %s -> %r' % (got, back.hex(), model(back)))
    for t in TEXTS + ['%.*g' % (rng.randint(1, 9), 10 ** rng.uniform(-40, 40)) for _ in range(n // 4)]:
        got, used = lib.fval(t)
        # what a number reader would take: the longest valid prefix
        j = 0
        while j < len(t) and t[j].isdigit():
            j += 1
        if j < len(t) and t[j] == '.':
            j += 1
            while j < len(t) and t[j].isdigit():
                j += 1
        if j < len(t) and t[j] in 'eE':
            k = j + 1
            if k < len(t) and t[k] in '+-':
                k += 1
            if k < len(t) and t[k].isdigit():
                while k < len(t) and t[k].isdigit():
                    k += 1
                j = k
        lit = t[:j]
        if lit in ('', '.'):
            if got is not None:
                fails.append('fval %r: a number from nothing' % t)
            continue
        mant, _, ex = lit.lower().partition('e')
        ip, _, fp = mant.partition('.')
        digits = (ip + fp).lstrip('0')
        q = int(ex or 0) - len(fp)
        if len(digits) > 9:                  # it reads 9 significant digits
            q += len(digits) - 9
            digits = digits[:9]
        v = Fraction(int(digits or '0')) * Fraction(10) ** q
        want = exact_five(v)
        if used != j:
            fails.append('fval %r: read %d characters, not %d' % (t, used, j))
        elif want is None:
            if got is not None:
                fails.append('fval %r: %s, not too big' % (t, got.hex()))
        elif got is None:
            fails.append('fval %r: no number, not %s' % (t, want.hex()))
        elif got != want:
            # one unit in the last place, only for the decimal scaling's ties
            if not (got[0] == want[0] and got[0] and
                    abs(int.from_bytes(got[1:], 'big') - int.from_bytes(want[1:], 'big')) <= 1):
                fails.append('fval %r: %s, not %s' % (t, got.hex(), want.hex()))
    for f in fails[:30]:
        print('FAIL:', f)
    print('strtest: %d numbers, %d texts; the ROM differs on %d (its own eighth digit); '
          'members %d bytes; slowest call %d T-states: %s'
          % (len(nums), len(TEXTS) + n // 4, romdiff, lib.size, lib.cycles,
             'FAIL (%d)' % len(fails) if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
