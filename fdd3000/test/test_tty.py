#!/usr/bin/env python3
"""Two terminals on the emulated FDD3000 (platform/terminals.md, step 2):
the console on the link, and /dev/tty1 on the WD2123's channel A
(fdd3000/src/serial.asm; fddrun.WD2123, the far end a terminal at 9600
baud honouring RTS).

    python3 fdd3000/test/test_tty.py

Checked:
  - init starts a getty on each terminal: login on both;
  - what is typed on one is answered on that one only;
  - ps, on the serial terminal, sees both sessions;
  - ^C on the serial terminal stops its own program (sleep), not the
    console's (a sleep there still running, as ps shows);
  - an SDK program (hello, from /mnt/a/bin) runs on the serial terminal;
  - a program that draws (mandel, the bitmap kind, from drive B), started
    there, is refused: its terminal has no screen;
  - the serial terminal speaks VT52 (drivers/vt52, step 3): top's clear
    screen and AT 0,0 arrive as ESC H ESC J and ESC Y, no Spectrum codes
    (0Ch, 16h) on the line, and its table is where AT put it;
  - each terminal keeps its own column: a line typed on the serial
    terminal with the console typing in the middle of it wraps at column
    64 of its own, and the console's line is whole.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'fdd3000', 'tools'))
import fddrun  # noqa: E402
import zxdfs  # noqa: E402
import dsk  # noqa: E402
from test_ssx import to_model  # noqa: E402

SER = 0                 # the WD2123 channel of /dev/tty1


def main():
    b = dsk.Disk(cyls=40, sides=1)
    fs = zxdfs.mkfs(zxdfs.Device(b))
    out = os.path.join(ROOT, 'build', 'ux')
    os.makedirs(out, exist_ok=True)
    dst = os.path.join(out, 'mandel.ssx')
    subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'rcc'), '--no-rom', '-o', dst,
                    os.path.join(ROOT, 'examples', 'c48-src', 'demos', 'mandel.c')], check=True)
    fs.put('/mandel', open(dst, 'rb').read())
    m = fddrun.FDDUX([fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK), to_model(b)])
    m.boot()
    m.run_for(25, quiet=3.0)
    ser = m.uart[SER]

    def serial(s, settle=3.0):
        """Typed at the serial terminal, a key at a time; what it showed."""
        n = len(ser.out)
        for ch in s:
            ser.keys.append(ord(ch))
            m.run_for(0.05)
        m.run_for(20, quiet=settle)
        return bytes(ser.out[n:]).decode('latin-1')

    fails = []

    def check(ok, why):
        if not ok:
            fails.append(why)

    m.type('root\r')
    console = fddrun.vt52(m.screen())
    check('login: root' in console and '#' in console, 'no login on the console')
    log = bytes(ser.out).decode('latin-1')
    check('login: ' in log, 'no getty on the serial terminal')
    t = serial('root\r')
    check('Welcome' in t and '# ' in t, 'no login on the serial terminal: %r' % t)
    t = serial('echo on the serial line\r')
    check('on the serial line' in t, 'echo on the serial terminal: %r' % t)
    m.type('echo on the console\r')
    check('on the console' in fddrun.vt52(m.screen()), 'echo on the console')
    check('on the console' not in bytes(ser.out).decode('latin-1'),
          'the console\'s output went to the serial terminal')
    m.type('sleep 200\r', settle=1.0)            # the console: busy
    t = serial('sleep 200\r', settle=1.0)        # the serial terminal: busy too
    t = serial('\x03', settle=2.0)               # its ^C: its own sleep only
    t = serial('ps\r')
    print(t)
    check(t.count('sleep') == 1, 'ps on the serial terminal: one sleep left (the console\'s): %r' % t)
    check(t.count('sh') >= 2, 'ps: both shells: %r' % t)
    t = serial('hello\r')
    check('Hello World!' in t, 'hello on the serial terminal: %r' % t)
    t = serial('/etc/mount /dev/fd1 /mnt/b\r')
    t = serial('/mnt/b/mandel\r')
    check('needs the screen, not a terminal' in t or 'needs a screen' in t,
          'mandel from the serial terminal was not refused: %r' % t)
    n = len(ser.out)                             # top: VT52, not Spectrum codes
    serial('top\r', settle=6.0)
    serial('\x03', settle=2.0)
    raw = bytes(ser.out[n:])
    check(b'\x1bH\x1bJ' in raw, 'top on the serial terminal: no ESC H ESC J (clear): %r' % raw[:80])
    check(b'\x1bY  ' in raw, 'top on the serial terminal: no ESC Y for AT 0,0: %r' % raw[:80])
    check(not any(c in raw for c in b'\x0c\x16\x14'), 'Spectrum codes on the serial line: %r' % raw[:80])
    shown = fddrun.vt52(raw.decode('latin-1')).split('\n')
    check(any('PID' in line for line in shown[:4]), 'top\'s table not at the top: %r' % shown[:6])
    serial('\r', settle=1.0)
    m.type('\x03', settle=2.0)                   # the console's sleep: its own ^C
    n = len(ser.out)                             # each terminal its own column
    long = 'y' * 70
    serial('echo ' + long[:30], settle=0.5)
    m.type('echo half', settle=0.5)
    serial(long[30:] + '\r', settle=2.0)
    m.type('way\r')
    lines = fddrun.vt52(bytes(ser.out[n:]).decode('latin-1')).split('\n')
    check('y' * 64 in lines and 'y' * 6 in lines,
          'the serial terminal did not wrap its 70 y at its own column 64: %r' % lines)
    shown = fddrun.vt52(m.screen()).split('\n')
    check('# echo halfway' in shown and 'halfway' in shown,
          'the console\'s line was broken by the serial terminal\'s: %r' % shown[-4:])
    print(bytes(ser.out).decode('latin-1')[-600:])
    if m.stopped is not None:
        fails.append('the FDD3000 halted at %04X' % m.stopped)
    for f in fails:
        print('FAIL:', f)
    print('test_tty: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
