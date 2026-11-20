#!/usr/bin/env python3
"""The screen kinds on the FDD3000 (platform/screen-kinds.md).

The system disk's programs are built with rcc --no-rom.  Checked:
  - hello (/mnt/a/bin's: the shell's own hello is resident) and trek,
    console kind, write to the terminal: their text is there;
  - hello's output redirected to a file holds its text (and the console
    codes that place it);
(Programs that draw are refused: fdd3000/test/test_ssx.py.)

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

    def watch(seconds):
        for _ in range(int(seconds * 4)):
            m.run_for(0.25)

    # console kind: hello, then trek, on the terminal
    r.m.link.keys.extend(b'/mnt/a/bin/hello\r')
    watch(6)
    screen = fddrun.vt52(m.screen())
    check('hello from c48' in screen, 'hello: %r' % screen[-300:])
    r.m.link.keys.extend(b'trek\r')
    watch(10)
    screen = fddrun.vt52(m.screen())
    check('SHORT RANGE SENSOR SCAN' in screen, 'trek: %r' % screen[-400:])
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
    bad = fddrun.arena_ok(m.m, sym)
    check(bad is None, 'the arena after them: %s' % bad)
    out = r.sh('echo still here')
    check('still here' in out and m.stopped is None, 'the machine did not survive')
    for f in fails:
        print('FAIL:', f)
    print('test_kinds: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
