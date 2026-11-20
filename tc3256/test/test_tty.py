#!/usr/bin/env python3
"""The TC3256's second terminal (platform/terminals.md, step 4): /dev/tty1
on its RS-232 port, bit-banged (tc3256/src/rs232.asm), at 1200 baud.

    python3 tc3256/test/test_tty.py

Fuse's TC3256 started from disk, a terminal on the port (the fork's
FUSE_RS232_*: tc3256run.run_serial - each line sent once the prompt has
come out).  Checked:
  - init's getty on the port: login there;
  - the shell answers on the line (echo); an SDK program (hello) runs;
  - ^C on the line stops its program (sleep 100) and the prompt is back;
  - VT52 on the line (drivers/vt52): top's clear and AT 0,0 as ESC H
    ESC J and ESC Y, no Spectrum codes (0Ch, 16h, 14h);
  - the clock keeps time while the line is busy (the bytes are sent in
    the frame interrupt, a whole frame's worth at most): top's own clock,
    its first refresh's against its last, with the frames Fuse counted
    between them (top is resident: no disk read, which runs with
    interrupts off, in the stretch);
  - the console's screen still has its own login, and none of the line's
    text.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import tc3256run  # noqa: E402

DISK = os.path.join(ROOT, 'build', 'tc3256', 'ZX-UX-TC3256.dsk')
HZ = 50                 # frames a second (platform.inc HAL_HZ)
QUIT = 15000            # frames: the whole session, with room to spare
REFRESH = 6             # top's refreshes timed (2 s each)
SLACK = 1               # seconds the clock may differ by (date's own rounding)
PROMPT = '# '


def main():
    script = [
        ('login: ', 'root\r'),
        (PROMPT, 'echo on the serial line\r'),
        (PROMPT, 'hello\r'),
        (PROMPT, 'sleep 100\r'),
        ('sleep 100\r\n', '\x03'),
        (PROMPT, 'top\r'),
    ] + [('\x1bY', '')] * REFRESH + [               # its refreshes ...
        ('\x1bY', '\x03'),                          # ... then ^C
        (PROMPT, ''),
    ]
    got, line, trace, missed = tc3256run.run_serial(DISK, script, QUIT)
    print(line[-1500:])
    fails = []

    def check(ok, why):
        if not ok:
            fails.append(why)
    for m in missed:
        fails.append('never came out on the line: %r' % m)
    check('Welcome' in line or PROMPT in line, 'no login on the line')
    check('\r\non the serial line\r\n' in line, 'echo on the line')
    check('Hello World!' in line, 'hello on the line')
    k = line.find('sleep 100')
    check(k >= 0 and PROMPT in line[k:k + 40], '^C did not stop sleep 100')
    k = line.find('top\r\n')
    top = line[k:].encode('latin-1') if k >= 0 else b''
    check(b'\x1bH\x1bJ' in top, 'top: no ESC H ESC J')
    check(b'\x1bY  ' in top, 'top: no ESC Y for AT 0,0')
    check(not any(c in line.encode('latin-1') for c in b'\x0c\x16\x14'), 'Spectrum codes on the line')

    outs = [f for f, what, _ in trace if what == 'OUT']   # the frame of each byte out
    sec = lambda t: sum(int(x) * m for x, m in zip(t.split(':'), (3600, 60, 1)))
    heads = [(m.end(), m.group(1)) for m in re.finditer(r'top  (\d\d:\d\d:\d\d)', line)]
    if len(heads) >= REFRESH and len(outs) == len(line):
        (i0, t0), (i1, t1) = heads[0], heads[-1]
        kernel = sec(t1) - sec(t0)
        frames = (outs[i1 - 1] - outs[i0 - 1]) / HZ
        print('clock over %d refreshes: the kernel %d s, Fuse %.1f s' % (len(heads), kernel, frames))
        check(abs(kernel - frames) <= SLACK, 'the clock lost time: %d s against %.1f' % (kernel, frames))
    else:
        fails.append('top: %d refreshes timed (%d bytes, %d traced)' % (len(heads), len(line), len(outs)))

    screen = got.get((0x4000, 0x1800))
    if screen is None:
        fails.append('no screen dump')
    else:
        con = tc3256run.screen_text(screen)
        print(con)
        check('login:' in con, 'no login on the console')
        check('serial line' not in con, 'the line\'s text on the console')
    for f in fails:
        print('FAIL:', f)
    print('test_tty: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
