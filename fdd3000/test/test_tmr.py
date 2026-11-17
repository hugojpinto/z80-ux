#!/usr/bin/env python3
"""The WD1770 clock (tmr.asm): a program that never makes a system call
does not starve the rest.

"spin" is an SSX1 program of one instruction, JR $: no system call, ever.
On the soft clock alone it would hold the CPU for good.  With the WD1770
ticking at 50 Hz:
  - spin in the background, the shell still answers and the clock moves;
  - the shell's kill stops it;
  - spin in the foreground, ^C (BREAK) stops it;
  - date keeps time: 20 s of the FDD3000's own time are 20 s of ZX-UX's;
  - with four drives (a drive D on its select line) the clock is not
    used: /dev/fd3 is a disk, the soft clock keeps time.
    python3 fdd3000/test/test_tmr.py
"""
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'fdd3000', 'tools'))
sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
import fddrun  # noqa: E402
import zxdfs  # noqa: E402
import dsk  # noqa: E402
import rld  # noqa: E402


def spin_ssx():
    image = b'\x18\xfe'                         # JR $
    hdr = b'SSX1' + struct.pack('<BBHHHHHH', 0, rld.SSX_HDR, len(image), 0, 64, 0, 0, 0)
    ck = rld.fletcher16(hdr + image)
    return hdr + struct.pack('<H', ck) + image


def secs(screen):
    return [int(h) * 3600 + int(m) * 60 + int(s)
            for h, m, s in re.findall(r'(\d\d):(\d\d):(\d\d) 1982', screen)]


def main():
    b = dsk.Disk(cyls=40, sides=1)
    zxdfs.mkfs(zxdfs.Device(b)).put('/spin', spin_ssx())
    mb = fddrun.fdd.Disk(cyls=40, sides=1)
    for c in range(40):
        for r in range(16):
            mb.set_sector(c, 0, r, b.sector(c, 0, r))
    m = fddrun.FDDUX([fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK), mb])
    m.boot()
    m.run_for(25, quiet=3.0)
    fails = []
    m.type('root\r')
    m.type('/etc/mount /dev/fd1 /mnt/b\r')
    m.type('/mnt/b/spin&\r', settle=4.0)
    out = m.screen()
    pid = re.findall(r'spin&\r\n(\d+)', out)
    m.type('date\r', settle=3.0)
    t0 = m.tstates
    m.run_for(20)                               # spin has the CPU meanwhile
    m.type('date\r', settle=3.0)
    m.type('echo the shell answers\r', settle=3.0)
    m.type('ps\r', settle=3.0)
    if pid:
        m.type('kill %s\r' % pid[0], settle=3.0)
    m.type('ps\r', settle=3.0)
    m.type('/mnt/b/spin\r', settle=3.0)          # in the foreground
    m.run_for(3)
    m.link.keys.extend(b'\x03')                 # BREAK
    m.run_for(3, quiet=2.0)
    m.type('echo after break\r', settle=3.0)
    import json
    sym = json.load(open(os.path.join(ROOT, 'build', 'fdd3000', 'kernel.json')))['symbols']
    timer_on = m.m[sym['tmuse']], m.m[sym['tmron']]
    screen = m.screen().replace('\r', '')
    print(fddrun.vt52(m.screen()))
    if not pid:
        fails.append('spin& gave no pid')
    if 'the shell answers' not in screen.split('echo the shell answers')[-1]:
        fails.append('the shell did not answer while spin ran')
    t = secs(screen.split('/mnt/b/spin&')[-1])
    if len(t) < 2:
        fails.append('no dates')
    else:
        el = (m.tstates - t0) / 4e6
        d = t[1] - t[0]
        if not 20 <= d <= el + 1:
            fails.append('the clock: %d s in %.1f s' % (d, el))
    ps2 = screen.split('# ps')[-1].split('#')[0]
    if 'spin' in ps2:
        fails.append('kill did not stop spin')
    if 'after break' not in screen.split('echo after break')[-1]:
        fails.append('^C did not stop the foreground spin')
    if timer_on != (1, 1):
        fails.append('three drives: the clock is not running (use %d, on %d)' % timer_on)
    # four drives: drive D is there, the soft clock is used
    m4 = fddrun.FDDUX([fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK), fddrun.fdd.Disk(cyls=40, sides=1),
                       fddrun.fdd.Disk(cyls=40, sides=1), fddrun.fdd.Disk(cyls=40, sides=1)])
    m4.boot()
    m4.run_for(25, quiet=3.0)
    m4.type('root\r')
    m4.type('date\r', settle=1.0)
    m4.run_for(10)
    m4.type('date\r', settle=1.0)
    m4.type('dd if=/dev/fd3 of=/tmp/d count=1\r', settle=6.0)
    s4 = m4.screen().replace('\r', '')
    if m4.m[sym['tmuse']] or m4.m[sym['tmron']]:
        fails.append('four drives: the clock took drive D')
    if '1 blocks' not in s4:
        fails.append('four drives: /dev/fd3 is not a disk')
    t4 = secs(s4)
    if len(t4) < 2 or not 9 <= t4[-1] - t4[-2] <= 13:
        fails.append('four drives, soft clock: %s' % t4)
    if m.stopped is not None:
        fails.append('the FDD3000 halted at %04X' % m.stopped)
    for f in fails:
        print('FAIL:', f)
    print('test_tmr: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
