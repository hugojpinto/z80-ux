#!/usr/bin/env python3
"""SDK programs (SSX1 files) run from disk, on the emulated FDD3000.

The system disk's ZXFS is mounted on /mnt/a at boot; its /bin holds C48
programs (rcc --ux, the stream and console kinds), so the shell finds
them by name.  Drive B gets a ZXFS with more, built here with rcc --ux,
and the shipped mandel (built for a display file at 4000h), mounted on
/mnt/b and run by path.  Checked:
  - the C48 hello from the disk (the shell's plain hello is resident);
  - fortune, hangman, trek write to the terminal; hangman takes keys;
  - colors and mandel (the bitmap kind) and the shipped mandel are
    refused at load: the FDD3000's console is a terminal, it has no screen
    to draw on (screen.asm, ssx.asm); the machine lives on;
  - bell (test/kinds/bell.c): beep() rings the terminal's bell (hbeep),
    at most one every fifth of a second;
  - float (test/kinds/float.c): system call 42 loads the clean-room float
    engine (/mnt/a/lib/fp, drivers/fp) into the arena; the results are
    the Spectrum ROM's; the engine is freed when float ends;
  - keys (test/kinds/keys.c): kbd_down and kbdmatrix see no key down,
    even with A typed at the terminal: there are no keyboard rows here;
  - an executable file that is no SSX1 program is refused (ENOEXEC).
    python3 fdd3000/test/test_ssx.py
"""
import json
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
    for name, src in (('colors', 'examples/colors.c'), ('mandel', 'demos/mandel.c'),
                      ('bell', '../../test/kinds/bell.c'),
                      ('keys', '../../test/kinds/keys.c'),
                      ('float', '../../test/kinds/float.c')):
        dst = os.path.join(out, name + '.ssx')
        subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'rcc'), '--ux', '-o', dst,
                        os.path.join(ROOT, 'examples', 'c48-src', src)], check=True)
        with open(dst, 'rb') as f:
            fs.put('/' + name, f.read())
    with open(os.path.join(ROOT, 'examples', 'c48-bin', 'ssx', 'mandel.ssx'), 'rb') as f:
        fs.put('/mand0', f.read())
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
    run('/mnt/b/colors\r', name='colors')
    run('/mnt/b/mandel\r', name='mandel')
    bel0 = m.link.out.count(7)
    run('/mnt/b/bell\r', settle=6.0, name='bell')
    bells = m.link.out.count(7) - bel0
    run('/mnt/b/mand0\r', name='old')
    sym = json.load(open(os.path.join(ROOT, 'build', 'fdd3000', 'kernel.json')))['symbols']
    run('/mnt/b/float\r', settle=10.0, name='float')
    if m.m[sym['fpblk']] | m.m[sym['fpblk'] + 1] or m.m[sym['fpown']]:
        fails.append('float: the engine was not given back')
    m.type('/mnt/b/keys\r', settle=1.0)
    m.link.keys.extend(b'aaaa')
    m.run_for(6, quiet=3.0)
    screens['keys'] = fddrun.vt52(m.screen())
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
    expect('colors', 'this program draws: it needs a screen', 'colors was not refused')
    expect('mandel', 'this program draws: it needs a screen', 'mandel was not refused')
    expect('bell', 'bell ok', 'bell did not finish')
    if not 1 <= bells <= 3:
        fails.append('bell: its three beeps rang the bell %d times (1-3)' % bells)
    expect('old', 'this program draws: it needs a screen', 'a program built for 4000h was not refused')
    expect('float', '14142 8414 5403 1218 23025 31415 1024 5463 5235 10471 350 -3',
           'the float engine did not give the ROM\'s results')
    expect('float', '1.4142136 0.33333333 1E+10 -.05 65535 -1250 6.2831853',
           'ftoa/atof did not give the numbers as text')
    expect('float', 'float ok', 'float did not finish')
    expect('keys', 'a:0 m:0', 'a key was seen down behind the terminal')
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
