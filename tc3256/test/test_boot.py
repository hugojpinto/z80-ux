#!/usr/bin/env python3
"""Phase 1 (platform/tc3256.md §7): ZX-UX on the TC3256's own screen.

    python3 tc3256/test/test_boot.py

The system disk (build/tc3256/ZX-UX-TC3256.dsk, build.py tc3256) in Fuse's
TC3256, started from disk (the boot menu's key 4); keys typed on its
keyboard, the screen read back as text (tc3256run.py).  Checked:
  - the banner and the kernel's line, then login (tcboot read BOOT's rest
    through TOS; the kernel started);
  - the keyboard (tc3256/src/kbd.asm): letters, capitals (CAPS SHIFT),
    symbols (SYMBOL SHIFT: / > "), ENTER; the shell runs what is typed;
  - a file written and read back (redirection, the RAM file system);
  - the clock (the frame interrupt, IM 1): sleep 1 ends;
  - BREAK (CAPS SHIFT + SPACE) stops a program and the shell comes back;
  - no tar: there is no cassette here (HAL_SEQDEV 0).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import tc3256run  # noqa: E402

DISK = os.path.join(ROOT, 'build', 'tc3256', 'ZX-UX-TC3256.dsk')
LOGIN = 2000            # frames: the login prompt is up by then
BREAK_AFTER = 100       # frames into the program before BREAK


def session(lines, brk_after=None, more=()):
    """Log in, type LINES; then BREAK BREAK_AFTER frames into the last of
    them and type MORE -> the screen's text."""
    spec, f = tc3256run.keys(['root\r'] + lines, LOGIN)
    parts = [spec]
    if brk_after is not None:
        brk = f - tc3256run.SETTLE + brk_after
        parts.append('%d:CS,%d: ' % (brk, brk))
        spec, f = tc3256run.keys(['~%d' % brk_after] + list(more), f)
        parts.append(spec)
    got = tc3256run.run_disk(DISK, keys=','.join(parts), quit=f + 100)
    return tc3256run.screen_text(got[(0x4000, 0x1800)])


def main():
    a = session(['echo Hello TC3256\r', 'echo "a b" > /tmp/x\r', 'cat /tmp/x\r'])
    b = session(['sleep 1\r', 'echo slept\r', 'tar\r', 'sleep 100\r'], BREAK_AFTER,
                ['echo after\r'])
    print(a)
    print(b)
    fails = []

    def expect(text, what, why):
        if what not in text:
            fails.append(why)
    expect(a, 'Timex TC3256', 'no banner')
    expect(a, 'Hello TC3256', 'echo: the typed capitals')
    expect(a, '# cat /tmp/x\na b', 'redirection: the file written and read back')
    expect(b, '# echo slept\nslept', 'sleep 1 did not end (the clock)')
    expect(b, 'tar: not found', 'tar is here, with no cassette')
    expect(b, '# echo after\nafter', 'BREAK did not stop sleep 100')
    for x in fails:
        print('FAIL:', x)
    print('test_boot: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
