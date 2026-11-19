#!/usr/bin/env python3
"""The screen kinds on the FDD3000 (platform/screen-kinds.md).

The system disk's programs are built with rcc --ux.  Checked:
  - hello (/mnt/a/bin's: the shell's own hello is resident) and trek,
    console kind, write to the terminal: no display file is claimed
    (scrown stays 0), the mirror has nothing to do, their text is there;
  - hello's output redirected to a file holds its text (and the console
    codes that place it) - impossible while it drew into a display file;
  - hanoi (bitmap kind) claims the display file: the kernel puts it in
    the arena, page-aligned, not at 4000h (resident programs are there),
    and takes it back when hanoi ends.

    python3 fdd3000/test/test_kinds.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import fddrun  # noqa: E402
from test_fsmod import Run  # noqa: E402


def main():
    sym = json.load(open(os.path.join(ROOT, 'build', 'fdd3000', 'kernel.json')))['symbols']
    r = Run([fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK)])
    m = r.m
    fails = []

    def check(cond, why):
        if not cond:
            fails.append(why)

    owned = []

    def watch(seconds):
        for _ in range(int(seconds * 4)):
            m.run_for(0.25)
            owned.append(m.m[sym['scrown']])

    # console kind: hello, then trek, on the terminal
    owned.clear()
    r.m.link.keys.extend(b'/mnt/a/bin/hello\r')
    watch(6)
    screen = fddrun.vt52(m.screen())
    check('hello from c48' in screen, 'hello: %r' % screen[-300:])
    check(not any(owned), 'hello claimed the display file')
    owned.clear()
    r.m.link.keys.extend(b'trek\r')
    watch(10)
    screen = fddrun.vt52(m.screen())
    check('SHORT RANGE SENSOR SCAN' in screen, 'trek: %r' % screen[-400:])
    check(not any(owned), 'trek claimed the display file')
    r.m.link.keys.extend(b'q')
    watch(4)
    r.m.link.keys.extend(b'\r')
    watch(2)
    # redirected
    r.sh('/mnt/a/bin/hello > /tmp/h')
    out = r.sh('od /tmp/h')
    r.sh('cat /tmp/h')
    check('hello from c48' in fddrun.vt52(m.screen()), 'cat of the redirected output')
    check('026' in out or '16' in out, 'no AT code in the file: %r' % out[-200:])
    # bitmap kind: hanoi claims it
    owned.clear()
    r.m.link.keys.extend(b'hanoi\r')
    watch(10)
    check(any(owned), 'hanoi did not claim the display file')
    page = m.m[sym['dpage']]
    check(page > 0x5B, 'the display file is at %02X00h, not in the arena' % page)
    r.m.link.keys.extend(b'\x03')
    watch(3)
    check(m.m[sym['dpage']] == 0, 'the display file was not given back')
    bad = fddrun.arena_ok(m.m, sym)
    check(bad is None, 'the arena after hanoi: %s' % bad)
    out = r.sh('echo still here')
    check('still here' in out and m.stopped is None, 'the machine did not survive')
    for f in fails:
        print('FAIL:', f)
    print('test_kinds: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
