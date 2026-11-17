#!/usr/bin/env python3
"""Boundary tests for the FDD3000 port, after the checklist of The Design of
the ZX-UX Operating System (ch. 34 "Tests that exercise real boundaries",
ch. 35 "What should be examined before changing the kernel"): the failure
cases a demonstration never meets, on the disk side of the system.

  1 unlink while open   the name goes, the i-node stays until the last
                        close, then it is freed and counted
  2 full disk           a write that does not fit stops short with an
                        error; the file system stays consistent; rm gives
                        every block back
  3 long seek, holes    dd seek= writes far into a file; the gap reads as
                        zeros and takes no blocks
  4 paths and mounts    .. out of a mounted root; /mnt/b/../..; umount
                        refused while the current directory is inside;
                        rmdir refused on a mount point
  5 BREAK during I/O    ^C stops a disk copy; the machine lives on; the
                        disk is consistent
  6 packed files        a zxpack'ed RAM file copied to disk is the same;
                        a packed SSX1 program in RAM still runs
  7 memory pressure     the arena filled: disk work, an SSX1 program from
                        disk; RAM files come back byte for byte (packing,
                        compaction, unpacking under the VFS)

Each case is checked on the screen and, after it, by zxdfs check on the
host (links, block ownership, bitmap, free counts) - "a beautiful
screenshot does not show that a failed write is safe" (ch. 34).
    python3 fdd3000/test/test_bound.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'fdd3000', 'tools'))
import fddrun  # noqa: E402
import zxdfs  # noqa: E402
import dsk  # noqa: E402


def host(d):
    """The model's disk as a ZXFS on the host."""
    out = dsk.Disk(cyls=d.cyls, sides=d.sides, spt=d.spt)
    for c in range(d.cyls):
        for h in range(d.sides):
            for r in range(d.spt):
                out.put(c, h, r, d.sector(c, h, r))
    return zxdfs.FS(zxdfs.Device(out))


def look(fs, path):
    try:
        return fs.read_file(fs.lookup(path))
    except zxdfs.FSError:
        return None


class Run:
    def __init__(self):
        self.a = fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK)
        self.b = fddrun.fdd.Disk(cyls=40, sides=1)
        self.m = fddrun.FDDUX([self.a, self.b])
        self.m.boot()
        self.m.run_for(25, quiet=3.0)
        self.fails = []
        self.sh('root')

    def sh(self, cmd, settle=None, limit=120):
        """Type a command and wait, as a person does, for the shell's
        prompt to come back (typing ahead of it is discarded by design:
        the shell flushes the keys typed while its child ran).  Returns
        what the command printed."""
        n = len(self.m.link.out)
        self.m.link.keys.extend((cmd + '\r').encode())
        t0 = self.m.tstates
        while self.m.tstates - t0 < limit * 4e6:
            self.m.run_for(0.5)
            out = self.m.link.out[n:]
            if not self.m.link.keys and out.endswith(b'# ') and out.count(b'# ') >= 1:
                self.m.run_for(0.5)
                if self.m.link.out[n:] == out:
                    break
        return self.m.link.out[n:].decode('latin-1').replace('\r', '')

    def check(self, case, cond, why):
        if not cond:
            self.fails.append('%s: %s' % (case, why))

    def fsck(self, case, which='b'):
        try:
            fs = host(self.b if which == 'b' else self.a)
            errs = fs.check()
        except zxdfs.FSError as e:
            errs = [str(e)]
        self.check(case, not errs, 'fsck: %s' % errs[:3])
        return fs if not errs else None


def main():
    r = Run()
    r.sh('/etc/mkfs /dev/fd1 48', settle=6.0)       # a small disk: easy to fill
    r.sh('/etc/mount /dev/fd1 /mnt/b')

    # 1 unlink while open
    r.sh('echo kept open > /mnt/b/f')
    r.sh('sleep 30 < /mnt/b/f &')
    out = r.sh('rm /mnt/b/f')
    out += r.sh('ls /mnt/b')
    r.check('1 unlink', 'f\n' not in out.split('ls /mnt/b')[-1], 'the name stayed')
    fs = host(r.b)
    held = [n for n in range(1, fs.ninodes + 1)
            if fs.iget(n).flags & zxdfs.IALLOC and fs.iget(n).nlinks == 0]
    r.check('1 unlink', len(held) == 1, 'no i-node held open (%s)' % held)
    r.m.run_for(32)                                 # sleep ends, closes
    r.sh('ls /mnt/b')
    r.fsck('1 unlink')

    # 2 full disk
    out = r.sh('dd if=/dev/fd0 of=/mnt/b/big count=60', settle=8.0)
    r.check('2 full', 'error' in out.lower() or 'blocks' in out, 'no answer: %r' % out[-80:])
    fs = r.fsck('2 full')
    if fs:
        r.check('2 full', fs.nfree == 0, '%d blocks left on a full disk' % fs.nfree)
        try:
            size = fs.iget(fs.lookup('/big')).size
            r.check('2 full', 0 < size < 60 * 256, 'big is %d bytes' % size)
        except zxdfs.FSError as e:
            r.check('2 full', False, str(e))
    r.sh('rm /mnt/b/big')
    fs = r.fsck('2 full')
    if fs:
        r.check('2 full', fs.nfree == fs.nblocks - fs.data - 1,
                'rm gave back %d of %d blocks' % (fs.nfree, fs.nblocks - fs.data - 1))

    # 3 long seek, holes
    r.sh('echo far > /tmp/far')
    r.sh('dd if=/tmp/far of=/mnt/b/sparse seek=100')
    out = r.sh('ls -l /mnt/b')
    fs = r.fsck('3 seek')
    if fs:
        n = fs.lookup('/sparse')
        ino = fs.iget(n)
        data = fs.read_file(n)
        r.check('3 seek', ino.size == 100 * 256 + 4, 'size %d' % ino.size)
        r.check('3 seek', data[:100 * 256] == bytes(100 * 256), 'the hole is not zeros')
        r.check('3 seek', data[100 * 256:] == b'far\n', 'the data: %r' % data[100 * 256:])
        r.check('3 seek', len(fs.blocks_of(ino)) <= 3,
                'the hole took blocks: %d' % len(fs.blocks_of(ino)))
    r.sh('rm /mnt/b/sparse')

    # 4 paths and mounts
    r.sh('mkdir /mnt/b/sub')
    out = r.sh('ls /mnt/b/..')
    r.check('4 paths', 'a\nb\nc\nd\n' in out, '.. out of the mounted root: %r' % out[-60:])
    out = r.sh('ls /mnt/b/../..')
    r.check('4 paths', 'bin\n' in out and 'etc\n' in out, '/mnt/b/../..: %r' % out[-80:])
    out = r.sh('ls /mnt/b/sub/../../b')
    r.check('4 paths', 'sub\n' in out, 'back in through the mount point: %r' % out[-60:])
    r.sh('cd /mnt/b/sub')
    out = r.sh('/etc/umount /dev/fd1')
    r.check('4 paths', 'busy' in out, 'umount with the cwd inside: %r' % out[-60:])
    r.sh('cd /')
    out = r.sh('rmdir /mnt/b')
    out += r.sh('ls /mnt/b')
    r.check('4 paths', 'sub\n' in out.split('ls /mnt/b')[-1], 'rmdir took the mount point')

    # 5 BREAK during I/O
    r.m.link.keys.extend(b'dd if=/dev/fd0 of=/mnt/b/copy count=40\r')
    r.m.run_for(1.5)                                # mid-copy
    r.m.link.keys.extend(b'\x03')
    r.m.run_for(4, quiet=2.0)
    out = r.sh('echo alive after break')
    r.check('5 break', 'alive after break' in out, 'the shell did not come back')
    r.fsck('5 break')
    r.sh('rm /mnt/b/copy')

    # 6 packed files
    r.sh('cp /mnt/a/doc/tar /tmp/doc')
    r.sh('zxpack /tmp/doc')
    r.sh('cp /tmp/doc /mnt/b/doc')
    fs = r.fsck('6 packed')
    want = open(os.path.join(ROOT, 'zx-ux', 'src', 'tar.doc'), 'rb').read()
    if fs:
        r.check('6 packed', look(fs, '/doc') == want, 'the copy differs or is missing')
    r.sh('cp /mnt/a/bin/hello /tmp/hello')
    r.sh('zxpack /tmp/hello')
    out = r.sh('/tmp/hello')
    r.check('6 packed', 'portable' in out, 'a packed program: %r' % out[-80:])
    r.sh('rm /tmp/doc /tmp/hello /mnt/b/doc')

    # 7 memory pressure
    r.sh('dd if=/dev/fd0 of=/tmp/m1 count=24', settle=6.0)
    r.sh('dd if=/dev/fd0 of=/tmp/m2 skip=24 count=24', settle=6.0)
    r.sh('dd if=/dev/fd0 of=/tmp/m3 skip=48 count=24', settle=6.0)
    out = r.sh('df')
    r.sh('dd if=/dev/fd0 of=/mnt/b/ref1 count=24', settle=6.0)
    r.sh('cp /mnt/a/doc/zxpack /mnt/b/z', settle=6.0)
    out = r.sh('/mnt/a/bin/hello')
    r.check('7 pressure', 'portable' in out or 'memory' in out,
            'an SSX1 program from disk: %r' % out[-80:])
    out = r.sh('cmp /tmp/m1 /mnt/b/ref1', settle=6.0)
    # the arena is full: m1 may be short (ENOSPC), but what it holds must be
    # the disk's bytes - "EOF on /tmp/m1" is a prefix, "differ" a corruption
    r.check('7 pressure', 'differ' not in out, 'm1 changed: %r' % out[-80:])
    r.check('7 pressure', 'EOF on /mnt/b/ref1' not in out, 'm1 longer than written')
    fs = r.fsck('7 pressure')
    a = host(r.a)
    errs = a.check()
    r.check('7 pressure', not errs, 'the system disk: %s' % errs[:3])
    if fs:
        r.check('7 pressure', look(fs, '/z') ==
                open(os.path.join(ROOT, 'zx-ux', 'src', 'zxpack.doc'), 'rb').read(),
                'disk to disk copy differs or is missing')

    out = r.sh('echo the end')
    r.check('end', 'the end' in out, 'the machine did not survive')
    r.check('end', r.m.stopped is None, 'the FDD3000 halted')
    log = os.path.join(ROOT, 'build', 'test_bound.log')
    with open(log, 'w') as f:
        f.write(r.m.screen().replace('\r', ''))
    print('transcript: %s' % os.path.relpath(log, ROOT))
    for f in r.fails:
        print('FAIL:', f)
    print('test_bound: %s' % ('FAIL' if r.fails else 'ok'))
    return 1 if r.fails else 0


if __name__ == '__main__':
    sys.exit(main())
