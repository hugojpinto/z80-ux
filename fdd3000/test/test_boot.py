#!/usr/bin/env python3
"""Boot-time mounts: /etc/init mounts the system disk's ZXFS on /mnt/a and
runs /mnt/a/etc/rc, which outlives a reboot (the RAM /etc does not).

First boot: /mnt/a is the system disk's; mkfs the blank disk in drive B and
add "mount it on /mnt/b" to /mnt/a/etc/rc, as the system disk's README says.
Second boot, same disks: B is mounted on /mnt/b before the login, and what
was written to it is there.  A system disk with no ZXFS on it still boots
(the mount fails quietly, no rc).
    python3 fdd3000/test/test_boot.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fddrun  # noqa: E402


def boot(disks, keys):
    m = fddrun.FDDUX(disks)
    m.boot()
    m.run_for(30, quiet=3.0)
    for k in keys:
        m.type(k + '\r', settle=4.0)
    return m.screen().replace('\r', '')


def main():
    a = fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK)
    b = fddrun.fdd.Disk(cyls=40, sides=1)
    fails = []
    out1 = boot([a, b], ['root', '/etc/mkfs /dev/fd1',
                         'echo /etc/mount /dev/fd1 /mnt/b >> /mnt/a/etc/rc',
                         'cat /mnt/a/etc/rc'])
    print(out1[-400:])
    if 'echo /dev/fd0 on /mnt/a\n/etc/mount /dev/fd1 /mnt/b\n' not in out1:
        fails.append('/mnt/a/etc/rc was not extended')
    out2 = boot([a, b], ['root', 'echo kept > /mnt/b/note', 'cat /mnt/b/note'])
    print(out2[-400:])
    head = out2.split('login:')[0]
    if '/dev/fd0 on /mnt/a' not in head:
        fails.append('second boot: rc did not run')
    if 'kept\n' not in out2.split('cat /mnt/b/note')[-1]:
        fails.append('second boot: /mnt/b is not drive B')
    blank = fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK)
    import json
    info = json.load(open(os.path.join(os.path.dirname(fddrun.DEFAULT_DISK), 'kernel.json')))
    first = info['image_track'] + (info['image_sectors'] + 15) // 16
    for t in range(first, 40):                  # wipe the file system (after the image)
        for r in range(16):
            blank.set_sector(t, 0, r, bytes(256))
    out3 = boot([blank], ['root', 'ls /mnt/a'])
    if 'login: root' not in out3 or '/dev/fd0 on /mnt/a' in out3:
        fails.append('a disk without a ZXFS does not boot cleanly')
    for f in fails:
        print('FAIL:', f)
    print('test_boot: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
