#!/usr/bin/env python3
"""SDK programs (SSX1 files) run from disk, on the emulated FDD3000.

The system disk's ZXFS is mounted on /mnt/a at boot; its /bin holds C48
programs from examples/c48-bin, so the shell finds them by name.  Drive B
gets a ZXFS with two more, built here with rcc --ux (colors: border() and
colour; mandel: pixel graphics; both the bitmap kind), mounted on /mnt/b
and run by path.  Checked:
  - the C48 hello from the disk (the shell's plain hello is resident);
  - fortune, hangman, trek draw into the display file and are shown on
    the terminal through the mirror (mirror.asm);
  - hangman takes keys; q quits back to the shell;
  - colors' OUT (FEh) (border, the FDD3000's drive latch) is defused at
    load (ssxfix) and the machine lives on; mandel's pixels show as #,
    from a display file the kernel put in the arena (sys 41);
  - an executable file that is no SSX1 program is refused (ENOEXEC).
    python3 fdd3000/test/test_ssx.py
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


def to_model(d):
    out = fddrun.fdd.Disk(cyls=d.cyls, sides=d.sides)
    for c in range(d.cyls):
        for h in range(d.sides):
            for r in range(d.spt):
                out.set_sector(c, h, r, d.sector(c, h, r))
    return out


def main():
    b = dsk.Disk(cyls=40, sides=1)
    fs = zxdfs.mkfs(zxdfs.Device(b))
    out = os.path.join(ROOT, 'build', 'ux')
    os.makedirs(out, exist_ok=True)
    for name, src in (('colors', 'examples/colors.c'), ('mandel', 'demos/mandel.c')):
        dst = os.path.join(out, name + '.ssx')
        subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'rcc'), '--ux', '-o', dst,
                        os.path.join(ROOT, 'examples', 'c48-src', src)], check=True)
        with open(dst, 'rb') as f:
            fs.put('/' + name, f.read())
    m = fddrun.FDDUX([fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK), to_model(b)])
    m.boot()
    m.run_for(25, quiet=3.0)
    fails = []
    screens = {}

    def run(keys, settle=6.0, name=None):
        m.type(keys, settle=settle)
        if name:
            screens[name] = fddrun.vt52(m.screen())

    run('root\r')
    run('/mnt/a/bin/hello\r', name='hello')     # (hello alone: the resident one)
    run('fortune\r', name='fortune')
    run('q', settle=4.0)
    run('hangman\r', name='hangman0')
    run('e', settle=3.0, name='hangman')
    run('q', settle=4.0)
    run('trek\r', settle=8.0, name='trek')
    run('q', settle=4.0)
    run('\r')
    run('/etc/mount /dev/fd1 /mnt/b\r')
    run('/mnt/b/colors\r', settle=8.0, name='colors')
    m.link.keys.extend(b'q')
    m.run_for(6, quiet=3.0)
    m.link.keys.extend(b'\x03')
    m.run_for(4, quiet=2.0)
    run('\r')
    m.type('/mnt/b/mandel\r', settle=3.0)
    m.run_for(45)                       # it computes before it draws
    screens['mandel'] = fddrun.vt52(m.screen())
    m.link.keys.extend(b'\x03')
    m.run_for(4, quiet=2.0)
    run('\r')
    run('cp /etc/motd /tmp/x\r')
    run('chmod 36 /tmp/x\r')
    run('/tmp/x\r', name='noexec')
    run('echo still alive\r', name='end')

    def expect(name, text, why):
        if text not in screens.get(name, ''):
            fails.append('%s: %s' % (name, why))

    expect('hello', 'portable', 'the C48 hello drew nothing')
    expect('fortune', 'C48 FORTUNE', 'the mirror shows no title')
    expect('hangman', 'Last: e', 'the key did not reach it')
    expect('trek', 'SHORT RANGE SENSOR SCAN', 'no sensor scan')
    expect('colors', 'INK / PAPER / BRIGHT / BORDER', 'colors did not draw')
    expect('mandel', '####', 'no pixels as #')
    expect('noexec', '/tmp/x', 'a non-SSX1 file was not refused')
    expect('end', 'still alive', 'the machine did not survive')
    if m.stopped is not None:
        fails.append('the FDD3000 halted at %04X' % m.stopped)
    print(screens.get('trek', ''))
    for f in fails:
        print('FAIL:', f)
    print('test_ssx: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
