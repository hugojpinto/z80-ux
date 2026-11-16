#!/usr/bin/env python3
"""The floppy disk driver (/dev/fd0-3), end to end on the emulated FDD3000.

Drive A holds the system disk, drive B a blank formatted one (40 tracks,
one side), drive C a blank 80-track two-sided one, D nothing.  From the ZX-UX shell, with dd and cmp:
  - the boot sector read from /dev/fd0 is the one on the disk;
  - written to /dev/fd1 at sector 300 (76800: past 64K, the driver's third
    offset byte) it lands on track 18, sector 12 of disk B, and nowhere else;
  - read back from there it compares equal;
  - on the two-sided 80-track disk in C, sector 700 is track 21, head 1,
    sector 12 (the probe found both sides and all 80 tracks);
  - /dev/fd3 (no drive) cannot be opened.
    python3 fdd3000/test/test_fd.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fddrun  # noqa: E402

E5 = bytes([0xE5]) * 256


def main():
    a = fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK)
    b = fddrun.fdd.Disk(cyls=40, sides=1)
    c = fddrun.fdd.Disk(cyls=80, sides=2)
    m = fddrun.FDDUX([a, b, c])
    m.boot()
    m.run_for(20, quiet=2.0)
    m.type('root\r')
    m.type('dd if=/dev/fd0 of=/tmp/boot count=1\r')
    m.type('dd if=/tmp/boot of=/dev/fd1 seek=300\r')
    m.type('dd if=/dev/fd1 of=/tmp/back skip=300 count=1\r')
    m.type('cmp /tmp/boot /tmp/back\r')
    m.type('dd if=/tmp/boot of=/dev/fd2 seek=700\r')
    m.type('dd if=/dev/fd3 count=1\r', settle=8.0)
    screen = fddrun.vt52(m.screen())
    print(screen)
    boot = a.sector(0, 0, 0)
    fails = []
    if '1 blocks' not in screen:
        fails.append('dd did not report its blocks')
    if b.sector(18, 0, 12) != boot:
        fails.append('sector 300 of disk B is not the boot sector')
    others = [(t, s) for t in range(40) for s in range(16)
              if (t, s) != (18, 12) and b.sector(t, 0, s) != E5]
    if others:
        fails.append('other sectors of disk B changed: %s' % others[:5])
    if 'differ' in screen:
        fails.append('cmp: the sector read back differs')
    if c.sector(21, 1, 12) != boot:
        fails.append('sector 700 of the two-sided disk is not on track 21, head 1')
    changed = [(t, h, r) for t in range(80) for h in range(2) for r in range(16)
               if (t, h, r) != (21, 1, 12) and c.sector(t, h, r) != E5]
    if changed:
        fails.append('other sectors of disk C changed: %s' % changed[:5])
    if '/dev/fd3: I/O error' not in screen:
        fails.append('/dev/fd3 (no drive) did not fail')
    for f in fails:
        print('FAIL:', f)
    print('test_fd: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
