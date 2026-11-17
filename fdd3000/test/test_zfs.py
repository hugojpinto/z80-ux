#!/usr/bin/env python3
"""ZXFS mounted under ZX-UX, end to end on the emulated FDD3000.

From the ZX-UX shell, with the system disk's file system mounted on
/usr at boot by /etc/init: read it,
make directories and files in it (echo, cp from RAM, ln, mv, rm), go in
and out of it with cd, find the mount point busy, unmount; mkfs a blank
disk in drive B and use it too.  Then the disks are read on the host
(fdd3000/tools/zxdfs.py): the files hold what was written, and both file
systems are consistent (zxdfs check: links, blocks, bitmap, counts).

    python3 fdd3000/test/test_zfs.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'tools'))
import fddrun  # noqa: E402
import zxdfs  # noqa: E402

SCRIPT = [
    'root',                             # /etc/init mounted fd0 on /usr
    'ls /usr/doc',
    'mkdir /usr/src',
    'echo hello, disk > /usr/src/hello',
    'cat /usr/src/hello',
    'cp /etc/motd /usr/src/motd',
    'ln /usr/src/hello /usr/src/hi',
    'mv /usr/src/motd /usr/src/welcome',
    'echo gone > /usr/src/tmp',
    'rm /usr/src/tmp',
    'cd /usr/src',
    'ls',
    'cd ..',
    'ls',
    'cd /',
    'ln /usr/src/hello /tmp/x',
    'rmdir /usr',
    '/etc/umount /dev/fd0',
    'ls /usr',
    '/etc/mkfs /dev/fd1',
    '/etc/mount /dev/fd1 /mnt',
    'mkdir /mnt/a',
    'cp /mnt/../etc/motd /mnt/a/m',
    'ls -l /mnt/a',
    '/etc/umount /dev/fd1',
]


def main():
    a = fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK)
    b = fddrun.fdd.Disk(cyls=40, sides=1)
    m = fddrun.FDDUX([a, b])
    m.boot()
    m.run_for(20, quiet=2.0)
    for cmd in SCRIPT:
        m.type(cmd + '\r', settle=4.0)
    screen = fddrun.vt52(m.screen())
    out = m.screen().replace('\r', '')
    print(screen)
    fails = []

    def expect(text, why):
        if text not in out:
            fails.append(why)

    expect('# cat /usr/src/hello\nhello, disk\n', 'cat of a new file')
    expect('hello\nhi\nwelcome\n', 'ls of /usr/src (hello, hi, welcome)')
    expect('/tmp/x', 'ln across file systems')          # it must fail (EXDEV)
    if 'tmp\n' in out.split('# cd /usr/src')[1].split('# cd ..')[0]:
        fails.append('rm left /usr/src/tmp')
    expect('# /etc/umount /dev/fd1\n#', 'umount of fd1')

    # the system disk, on the host
    da = zxdfs.Device(fddrun_disk_to_dsk(a))
    fsa = zxdfs.FS(da)
    errs = fsa.check()
    if errs:
        fails.append('fd0 file system: %s' % errs)
    try:
        if fsa.read_file(fsa.lookup('/src/hello')) != b'hello, disk\n':
            fails.append('/src/hello on the disk')
        if fsa.read_file(fsa.lookup('/src/welcome')) != b'\n  Welcome to ZX-UX UNIX v1.\n\n':
            fails.append('/src/welcome on the disk')
        if fsa.lookup('/src/hi') != fsa.lookup('/src/hello'):
            fails.append('/src/hi is not a link to /src/hello')
        if fsa.iget(fsa.lookup('/src/hello')).nlinks != 2:
            fails.append('/src/hello: link count')
    except zxdfs.FSError as e:
        fails.append('fd0: %s' % e)
    # the disk made by mkfs in drive B
    try:
        fsb = zxdfs.FS(zxdfs.Device(fddrun_disk_to_dsk(b)))
        errs = fsb.check()
        if errs:
            fails.append('fd1 file system: %s' % errs)
        if fsb.read_file(fsb.lookup('/a/m')) != b'\n  Welcome to ZX-UX UNIX v1.\n\n':
            fails.append('/a/m on the mkfs disk')
    except zxdfs.FSError as e:
        fails.append('fd1: %s' % e)
    for f in fails:
        print('FAIL:', f)
    print('test_zfs: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


def fddrun_disk_to_dsk(d):
    """The model's disk as a dsk.Disk (same geometry and contents)."""
    import dsk
    out = dsk.Disk(cyls=d.cyls, sides=d.sides, spt=d.spt)
    for c in range(d.cyls):
        for h in range(d.sides):
            for r in range(d.spt):
                out.put(c, h, r, d.sector(c, h, r))
    return out


if __name__ == '__main__':
    sys.exit(main())
