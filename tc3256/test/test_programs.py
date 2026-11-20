#!/usr/bin/env python3
"""Phase 4 (platform/tc3256.md §7): SDK programs on the TC3256's screen.

    python3 tc3256/test/test_programs.py

Programs built here (rcc and rbc --no-rom; one --rom48k; the shipped
mandel) are put on a copy of the system volume (tc3256run.with_files) and
run in Fuse's TC3256, started from disk:
  1. colour (console: INK and PAPER reach the attribute bytes), lines
     (stream: redirected to a file, read back), float (system call 42: the
     engine loaded from /mnt/a/lib/fp; its numbers and text), bell (the
     speaker, beep() with no ROM: it ends), hello built --rom48k and the
     shipped mandel (built for the ROM): both refused, "needs the 48K ROM";
  2. keys: kbd_down sees A held - the keyboard rows (this is a computer,
     not a terminal);
  3. BASIC: simpson (no pixels: the 32-column console, floats from the
     engine); plot (the bitmap kind: PRINT, PLOT, DRAW, CIRCLE on its own
     screen - the pixels checked while it waits in PAUSE 0);
  4. mandel (C, the bitmap kind): it draws.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'test', 'spectrum'))
import tc3256run  # noqa: E402
from kinds import FLOATS, FTEXT  # noqa: E402  (float.c's numbers, as the ROM gives them)

DISK = os.path.join(ROOT, 'build', 'tc3256', 'ZX-UX-TC3256.dsk')
OUT = os.path.join(ROOT, 'build', 'tc3256', 'progs')
LOGIN = 2600
C = {'colour': 'test/kinds/colour.c', 'lines': 'test/kinds/lines.c',
     'float': 'test/kinds/float.c', 'bell': 'test/kinds/bell.c',
     'keys': 'test/kinds/keys.c', 'mandel': 'examples/c48-src/demos/mandel.c'}
ROM48K = {'hello48': 'examples/c48-src/examples/hello.c'}
BASIC = {'simpson': 'examples/basic-src/numerical-analysis/16-simpson/SIMPSON.bas',
         'plot': 'test/kinds/plot.bas'}
OLD = {'mand0': 'examples/c48-bin/ssx/mandel.ssx'}
RED_ON_CYAN = 5 << 3 | 2        # colour.c's row 5: PAPER 5, INK 2
SCREEN = (0x4000, 0x1B00)       # the display file and its attributes
KEYS_PRESSES = 12               # A typed this many times (KEYGAP frames apart)


def build():
    os.makedirs(OUT, exist_ok=True)
    progs = {}
    for name, src, tool, opt in ([(n, s, 'rcc', '--no-rom') for n, s in C.items()]
                                 + [(n, s, 'rcc', '--rom48k') for n, s in ROM48K.items()]
                                 + [(n, s, 'rbc', '--no-rom') for n, s in BASIC.items()]):
        dst = os.path.join(OUT, name + '.ssx')
        r = subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', tool), opt,
                            '-o', dst, os.path.join(ROOT, src)], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit('%s %s: %s%s' % (tool, name, r.stdout, r.stderr))
        progs[name] = open(dst, 'rb').read()
    for name, path in OLD.items():
        progs[name] = open(os.path.join(ROOT, path), 'rb').read()
    return progs


def session(progs, names, script, keys=(), extra=0):
    """Log in; run SCRIPT (lines, from a file on the volume) with the
    programs NAMES there as /mnt/a/NAME; type KEYS after; let EXTRA more
    frames go -> the display file (and attributes)."""
    files = {'/' + n: progs[n] for n in names}
    files['/t'] = ''.join(l + '\n' for l in script).encode()
    with tempfile.TemporaryDirectory() as t:
        disk = tc3256run.with_files(DISK, files, os.path.join(t, 'p.dsk'))
        spec, f = tc3256run.keys(['root\r', 'sh /mnt/a/t\r'] + list(keys) + ['~%d' % extra], LOGIN)
        got = tc3256run.run_disk(disk, keys=spec, quit=f, dumps=(SCREEN,))
    return got[SCREEN]


def main():
    progs = build()
    fails = []

    def check(ok, why):
        if not ok:
            fails.append(why)

    d = session(progs, ['colour', 'lines', 'float', 'bell', 'hello48', 'mand0'],
                ['/mnt/a/colour', '/mnt/a/lines > /tmp/o', 'cat /tmp/o', '/mnt/a/float',
                 '/mnt/a/bell', '/mnt/a/hello48', '/mnt/a/mand0'], extra=2500)
    text = tc3256run.screen_text(d)
    print(text)
    check('red on cyan' in text, 'colour: no text')
    check(RED_ON_CYAN in d[0x1800:0x1B00], 'colour: no red-on-cyan attribute')
    check('1 line\n2 line\n3 line' in text, 'lines: redirected and read back')
    check(FLOATS in text and FTEXT in text and 'float ok' in text, 'float: the engine')
    check('bell ok' in text, 'bell: beep() did not end')
    check(text.count('needs the 48K ROM') == 2, 'the ROM\'s programs not both refused')

    # A, pressed again and again across the time keys watches (150 ticks,
    # from when it is loaded: that time varies)
    d = session(progs, ['keys'], ['/mnt/a/keys'], keys=['a' * KEYS_PRESSES], extra=200)
    text = tc3256run.screen_text(d)
    print(text)
    check('a:1' in text, 'keys: A held was not seen (the keyboard rows)')

    d = session(progs, ['simpson'], ['/mnt/a/simpson'], extra=3000)
    text = tc3256run.screen_text8(d)
    print(text)
    for want in ('SIMPSON 1 80 0.33333333', 'SIMPSON 2 160 3.141592', 'DONE SIMPSON'):
        check(want in text, 'simpson: %s' % want)

    d = session(progs, ['plot'], ['/mnt/a/plot'], extra=600)
    check(tc3256run.pixel(d, 0, 175) and tc3256run.pixel(d, 255, 0),
          'plot: the DRAW from 0,0 to 255,175 is not there')
    check(any(d[r << 8 | c] for r in range(8) for c in range(12)), 'plot: no PRINT at 0,0')

    d = session(progs, ['mandel'], ['/mnt/a/mandel'], extra=2500)
    text = tc3256run.screen_text(d)
    print(text)
    check('MANDELBROT' in text and text.count('????????????????????????????????') >= 2,
          'mandel: its screen is not there (its title, rows drawn)')

    for x in fails:
        print('FAIL:', x)
    print('test_programs: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
