#!/usr/bin/env python3
"""BASIC programs compiled by rbc --no-rom, on the emulated FDD3000.

    python3 fdd3000/test/test_basic.py

rbc --no-rom links the BASIC runtime with libux's clean-room routines in
place of the 48K ROM's (platform/basic.md): no ROM, the system
variables in the program, the display file where system call 41 puts it,
the keys from the terminal, floats from the platform's engine.  Drive B
gets a ZXFS with:
  - simpson (numerical-analysis): Simpson's rule, printed with PRINT's
    numbers (libux's @fstr) from the clean-room float engine;
  - monsters (a game): PRINT, then INPUT typed at the terminal, its
    answer printed;
both of the console kind (no pixels: their text through the kernel's
console, 32 columns - the terminal here); and minelay, which draws (the
bitmap kind): refused, there is no screen here;
mounted on /mnt/b and run by path.  The terminal (the mirror of their
display files) must show their text; the arena is whole after; the
machine lives on.
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
from test_ssx import to_model  # noqa: E402

BASIC = os.path.join(ROOT, 'examples', 'basic-src')
PROGRAMS = {
    'simpson': 'numerical-analysis/16-simpson/SIMPSON.bas',
    'monsters': 'www.thespectrumshow.net/39-compspacegames-SpaceGames-07/MONSTERS.bas',
    'minelay': '60-programs/01-minelay/01-minelay.bas',
}


def main():
    b = dsk.Disk(cyls=40, sides=1)
    fs = zxdfs.mkfs(zxdfs.Device(b))
    out = os.path.join(ROOT, 'build', 'ux')
    os.makedirs(out, exist_ok=True)
    for name, src in PROGRAMS.items():
        dst = os.path.join(out, name + '.ssx')
        r = subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'rbc'), '--no-rom',
                            '-o', dst, os.path.join(BASIC, src)], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit('rbc --no-rom %s: %s' % (name, r.stderr.strip()))
        with open(dst, 'rb') as f:
            fs.put('/' + name, f.read())
    m = fddrun.FDDUX([fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK), to_model(b)])
    m.boot()
    m.run_for(25, quiet=3.0)
    fails = []
    sym0 = json.load(open(os.path.join(ROOT, 'build', 'fdd3000', 'kernel.json')))['symbols']
    screens = {}

    def run(keys, settle=6.0, name=None):
        m.type(keys, settle=settle)
        if name:
            screens[name] = fddrun.vt52(m.screen())

    run('root\r')
    run('/etc/mount /dev/fd1 /mnt/b\r')
    run('/mnt/b/simpson\r', settle=40.0, name='simpson')
    run('\r')
    run('/mnt/b/monsters\r', settle=20.0, name='monsters')
    run('R\r', settle=10.0, name='monsters2')
    m.link.keys.extend(b'\x03')             # BREAK: the rest of its rounds
    m.run_for(4, quiet=2.0)
    run('\r')
    sym = json.load(open(os.path.join(ROOT, 'build', 'fdd3000', 'kernel.json')))['symbols']
    bad = fddrun.arena_ok(m.m, sym)
    if bad:
        fails.append('the arena after them: %s' % bad)
    run('/mnt/b/minelay\r', name='minelay')
    run('echo still alive\r', name='end')

    def expect(name, text, why):
        if text not in screens.get(name, ''):
            fails.append('%s: %s' % (name, why))
    expect('simpson', 'SIMPSON 1 80 0.33333333', 'no first result')
    expect('simpson', 'SIMPSON 2 160 3.141592', 'no second result')
    expect('simpson', 'DONE SIMPSON', 'did not finish')
    expect('monsters', 'MONSTERS OF GALACTICON', 'no title')
    expect('monsters', 'WHICH WEAPON ? (R,S OR T)', 'no question')
    if not any(t in screens.get('monsters2', '') for t in ("NO USE", "KILLED IT")):
        fails.append('monsters: the answer typed got no reply')
    expect('minelay', 'this program draws: it needs a screen', 'minelay (it draws) was not refused')
    expect('end', 'still alive', 'the machine did not survive')
    if m.stopped is not None:
        fails.append('the FDD3000 halted at %04X' % m.stopped)
    for k in ('simpson', 'monsters2'):
        print('--- %s' % k)
        print(screens.get(k, ''))
    for f in fails:
        print('FAIL:', f)
    print('test_basic: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
