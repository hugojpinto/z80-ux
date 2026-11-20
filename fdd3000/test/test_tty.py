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
    there, is refused: its terminal has no screen.
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
    print(bytes(ser.out).decode('latin-1')[-600:])
    if m.stopped is not None:
        fails.append('the FDD3000 halted at %04X' % m.stopped)
    for f in fails:
        print('FAIL:', f)
    print('test_tty: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
