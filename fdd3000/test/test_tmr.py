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
  - idle for more than 5 s, the clock parks (MOTOR ON may fall: drive A
    selected); a command starts it again, and time is kept across.
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
    m.type('date\r', settle=1.0)
    m.run_for(8)                                # idle: the clock parks
    parked = m.m[sym['tmpark']], m.m[sym['tmron']], m.latch
    m.type('date\r', settle=1.0)               # a command: it runs again
    running = m.m[sym['tmpark']], m.m[sym['tmron']]
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
    if parked != (1, 0, 0xDE):
        fails.append('idle: not parked (park %d, on %d, latch %02X)' % parked)
    if running != (0, 1):
        fails.append('after a command the clock does not run (park %d, on %d)' % running)
    t2 = secs(screen.split('echo after break')[-1])
    late = secs(m.screen().replace('\r', '').split('echo after break')[-1])
    if len(late) >= 2 and not 8 <= late[-1] - late[-2] <= 11:
        fails.append('across the park: %d s for ~9 s' % (late[-1] - late[-2]))
    if m.stopped is not None:
        fails.append('the FDD3000 halted at %04X' % m.stopped)
    for f in fails:
        print('FAIL:', f)
    print('test_tmr: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
