#!/usr/bin/env python3
"""ZXFS: the ZX-UX disk file system (file system type 1), on the host.

The reference for fdd3000/src/zfs.asm, and the tool that makes and reads
these file systems in disk images:

    zxdfs.py mkfs  DISK [--base SECTOR] [--blocks N] [--inodes N] [--label L]
    zxdfs.py put   DISK HOSTFILE /path        (creates directories on the way)
    zxdfs.py mkdir DISK /path
    zxdfs.py ls    DISK [/path]
    zxdfs.py get   DISK /path [HOSTFILE]
    zxdfs.py check DISK                       (consistency: fsck)

The format.  A block is 256 bytes, one sector of the FDD3000's disks; a
file system is BLOCKS blocks from sector BASE of a device (/dev/fd0-3).

  block 0          the superblock
        0  "ZXFS"          4  version (1)       5  type (1: ZXFS)
        6  blocks.w        8  inodes.w         10  bitmap block.w
       12  bitmap blocks   13  0               14  inode table block.w
       16  inode table blocks.w                18  first data block.w
       20  free blocks.w  22  free inodes.w    24  time made.l
       28  label (16 bytes, 0-padded)          44  0...
  bitmap           one bit a block, bit 0 of byte 0 = block 0; 1 = in use.
                   The blocks before the first data block are in use.
  inode table      inodes 1 .. INODES, 8 a block (inode n: block
                   itab + (n-1)/8, at 32 * ((n-1) mod 8)).  Inode 1 is the
                   root directory.
  data blocks

  inode (32 bytes: the kernel's in-core i-node, const.inc)
        0 flags.w (IALLOC 8000h, IFDIR 4000h, mode bits)   2 links
        3 uid      4 size.w     6 direct blocks 0-5 (6 words)
       18 single indirect.w    20 double indirect.w (an indirect block
          holds 128 block numbers)          22 ctime.l   26 mtime.l
       30 kernel's (zxpack's time of the last change)
     Block number 0 is a hole (reads as zeros).

  directories      10-byte entries as in the RAM file system: inode.w
                   (local to this file system; 0 = free), name (8 bytes,
                   0-padded).  "." and ".." first; the root's ".." is the
                   root (the kernel sends ".." at a mounted root to the
                   directory it covers).

Where the file system is: a disk whose sector 0 begins "ZXFS" holds one
at BASE 0; a ZX-UX system disk's boot sector says where its own is, in
its last 8 bytes: "ZXFSBASE" is not used - the bytes are "FS", BASE.w,
BLOCKS.w and two 0 at F8h-FFh (fddimage.py writes them).
"""
import argparse
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dsk  # noqa: E402

BS = 256
MAGIC = b'ZXFS'
VERSION = 1
FSTYPE = 1
NDIRECT = 6
NPTR = BS // 2
ROOT = 1
IALLOC, IFDIR = 0x8000, 0x4000
MODE_DIR = 0o16                         # rw- r-- as the RAM dirs (+ o+w for some)
MODE_FILE = 0o16
IEXEC = 0o20                            # executable (SSX1 programs get it)
EPOCH_1982 = 4495 * 86400               # ZX-UX's default clock: 23 April 1982
BOOTPTR = 0xF8                          # in a system disk's boot sector


class FSError(Exception):
    pass


def unix_to_zx(t):
    """ZX-UX's clock counts seconds since 1970 like UNIX."""
    return int(t) & 0xFFFFFFFF


class Device:
    """Sectors of one disk side-by-side as the driver numbers them:
    logical sector n = track n // (16 * heads), head (n // 16) % heads."""

    def __init__(self, disk):
        self.disk = disk

    @property
    def nsectors(self):
        return self.disk.cyls * self.disk.sides * self.disk.spt

    def _chs(self, n):
        t, r = divmod(n, self.disk.spt)
        c, h = divmod(t, self.disk.sides)
        return c, h, r

    def read(self, n):
        return self.disk.sector(*self._chs(n))

    def write(self, n, data):
        self.disk.put(*self._chs(n), bytes(data).ljust(BS, b'\0'))


def find_base(dev):
    """Where a disk's file system is: (base, blocks) or None."""
    s0 = dev.read(0)
    if s0[:4] == MAGIC:
        return 0, struct.unpack_from('<H', s0, 6)[0]
    if s0[BOOTPTR:BOOTPTR + 2] == b'FS':
        base, blocks = struct.unpack_from('<HH', s0, BOOTPTR + 2)
        return base, blocks
    return None


class Inode:
    FMT = '<HBBH6HHHLLH'

    def __init__(self, raw=None):
        raw = raw or bytes(32)
        (self.flags, self.nlinks, self.uid, self.size, *rest) = struct.unpack(self.FMT, raw)
        self.direct = list(rest[:NDIRECT])
        self.ind, self.dind, self.ctime, self.mtime, self.rsvd = rest[NDIRECT:]

    def pack(self):
        return struct.pack(self.FMT, self.flags, self.nlinks, self.uid, self.size,
                           *self.direct, self.ind, self.dind, self.ctime,
                           self.mtime, self.rsvd)

    @property
    def isdir(self):
        return bool(self.flags & IFDIR)


class FS:
    def __init__(self, dev, base=None):
        self.dev = dev
        if base is None:
            fb = find_base(dev)
            if fb is None:
                raise FSError('no ZXFS file system on this disk')
            base = fb[0]
        self.base = base
        sb = self.bread(0)
        if sb[:4] != MAGIC or sb[4] != VERSION or sb[5] != FSTYPE:
            raise FSError('bad superblock at sector %d' % base)
        (self.nblocks, self.ninodes, self.bitmap, self.nbmap, _z, self.itab,
         self.nitab, self.data, self.nfree, self.nifree, self.made) = \
            struct.unpack_from('<HHHBBHHHHHL', sb, 6)
        self.label = sb[28:44].rstrip(b'\0').decode('latin-1')

    # ---- blocks ----
    def bread(self, b):
        return self.dev.read(self.base + b)

    def bwrite(self, b, data):
        self.dev.write(self.base + b, data)

    def _bit(self, b):
        blk, bit = divmod(b, BS * 8)
        return self.bitmap + blk, bit // 8, 1 << (bit % 8)

    def used(self, b):
        blk, i, m = self._bit(b)
        return bool(self.bread(blk)[i] & m)

    def mark(self, b, on):
        blk, i, m = self._bit(b)
        d = bytearray(self.bread(blk))
        d[i] = d[i] | m if on else d[i] & ~m
        self.bwrite(blk, d)

    def balloc(self):
        for b in range(self.data, self.nblocks):
            if not self.used(b):
                self.mark(b, True)
                self.bwrite(b, bytes(BS))
                self.nfree -= 1
                self.write_super()
                return b
        raise FSError('no free blocks')

    def write_super(self):
        sb = bytearray(BS)
        sb[:6] = MAGIC + bytes([VERSION, FSTYPE])
        struct.pack_into('<HHHBBHHHHHL', sb, 6, self.nblocks, self.ninodes, self.bitmap,
                         self.nbmap, 0, self.itab, self.nitab, self.data, self.nfree,
                         self.nifree, self.made)
        sb[28:44] = self.label.encode('latin-1')[:16].ljust(16, b'\0')
        self.bwrite(0, sb)

    # ---- inodes ----
    def _iloc(self, n):
        if not 1 <= n <= self.ninodes:
            raise FSError('inode %d out of range' % n)
        blk, k = divmod(n - 1, 8)
        return self.itab + blk, 32 * k

    def iget(self, n):
        blk, o = self._iloc(n)
        return Inode(self.bread(blk)[o:o + 32])

    def iput(self, n, ino):
        blk, o = self._iloc(n)
        d = bytearray(self.bread(blk))
        d[o:o + 32] = ino.pack()
        self.bwrite(blk, d)

    def ialloc(self):
        for n in range(1, self.ninodes + 1):
            if not self.iget(n).flags & IALLOC:
                self.nifree -= 1
                self.write_super()
                return n
        raise FSError('no free inodes')

    # ---- file contents ----
    def bmap(self, ino, k, alloc=False):
        """Block number of the k-th block of a file (0: a hole)."""
        def ptr(blk, i):
            return struct.unpack_from('<H', self.bread(blk), 2 * i)[0]

        def setptr(blk, i, v):
            d = bytearray(self.bread(blk))
            struct.pack_into('<H', d, 2 * i, v)
            self.bwrite(blk, d)

        if k < NDIRECT:
            if not ino.direct[k] and alloc:
                ino.direct[k] = self.balloc()
            return ino.direct[k]
        k -= NDIRECT
        if k < NPTR:
            if not ino.ind:
                if not alloc:
                    return 0
                ino.ind = self.balloc()
            b = ptr(ino.ind, k)
            if not b and alloc:
                b = self.balloc()
                setptr(ino.ind, k, b)
            return b
        k -= NPTR
        if k >= NPTR * NPTR:
            raise FSError('file too big')
        if not ino.dind:
            if not alloc:
                return 0
            ino.dind = self.balloc()
        i1, i2 = divmod(k, NPTR)
        mid = ptr(ino.dind, i1)
        if not mid:
            if not alloc:
                return 0
            mid = self.balloc()
            setptr(ino.dind, i1, mid)
        b = ptr(mid, i2)
        if not b and alloc:
            b = self.balloc()
            setptr(mid, i2, b)
        return b

    def read_file(self, n):
        ino = self.iget(n)
        out = bytearray()
        for k in range((ino.size + BS - 1) // BS):
            b = self.bmap(ino, k)
            out += self.bread(b) if b else bytes(BS)
        return bytes(out[:ino.size])

    def write_file(self, n, data):
        ino = self.iget(n)
        if len(data) > 0xFFFF:
            raise FSError('ZX-UX files are at most 65535 bytes')
        for k in range(0, len(data), BS):
            b = self.bmap(ino, k // BS, alloc=True)
            self.bwrite(b, data[k:k + BS].ljust(BS, b'\0'))
        ino.size = len(data)
        ino.mtime = unix_to_zx(time.time())
        self.iput(n, ino)

    def blocks_of(self, ino):
        """Every block the inode owns, the indirect ones included."""
        out = [b for b in ino.direct if b]
        if ino.ind:
            out.append(ino.ind)
            out += [x for x in struct.unpack('<128H', self.bread(ino.ind)) if x]
        if ino.dind:
            out.append(ino.dind)
            for mid in struct.unpack('<128H', self.bread(ino.dind)):
                if mid:
                    out.append(mid)
                    out += [x for x in struct.unpack('<128H', self.bread(mid)) if x]
        return out

    # ---- directories ----
    def entries(self, n):
        d = self.read_file(n)
        for o in range(0, len(d) - 9, 10):
            i = struct.unpack_from('<H', d, o)[0]
            if i:
                yield i, d[o + 2:o + 10].rstrip(b'\0').decode('latin-1'), o

    def lookup(self, path):
        n = ROOT
        for part in [p for p in path.split('/') if p]:
            ino = self.iget(n)
            if not ino.isdir:
                raise FSError('%s: not a directory' % path)
            for i, name, _ in self.entries(n):
                if name == part[:8]:
                    n = i
                    break
            else:
                raise FSError('%s: not found' % path)
        return n

    def link(self, dirn, name, n):
        raw = name.encode('latin-1')
        if not 0 < len(raw) <= 8:
            raise FSError('bad name %r' % name)
        d = bytearray(self.read_file(dirn))
        ent = struct.pack('<H', n) + raw.ljust(8, b'\0')
        for o in range(0, len(d), 10):
            if struct.unpack_from('<H', d, o)[0] == 0:
                d[o:o + 10] = ent
                break
        else:
            d += ent
        self.write_file(dirn, bytes(d))
        ino = self.iget(n)
        ino.nlinks += 1
        self.iput(n, ino)

    def mknode(self, dirn, name, flags):
        n = self.ialloc()
        ino = Inode()
        ino.flags = IALLOC | flags
        ino.ctime = ino.mtime = unix_to_zx(time.time())
        self.iput(n, ino)
        if dirn:
            self.link(dirn, name, n)
        if flags & IFDIR:
            self.link(n, '.', n)
            self.link(n, '..', dirn or n)
        return n

    def mkdir(self, path):
        parent, name = path.rstrip('/').rsplit('/', 1)
        return self.mknode(self.lookup(parent or '/'), name, IFDIR | MODE_DIR)

    def makedirs(self, path):
        n = ROOT
        cur = ''
        for part in [p for p in path.split('/') if p]:
            cur += '/' + part
            try:
                n = self.lookup(cur)
            except FSError:
                n = self.mkdir(cur)
        return n

    def put(self, path, data):
        parent, name = path.rsplit('/', 1)
        dirn = self.makedirs(parent)
        try:
            n = self.lookup(path)
        except FSError:
            mode = MODE_FILE | (IEXEC if data[:4] == b'SSX1' else 0)
            n = self.mknode(dirn, name, mode)
        self.write_file(n, data)
        return n

    # ---- consistency ----
    def check(self):
        """fsck: every allocated inode reachable with the right link count,
        every block owned once and marked, the free counts right."""
        errs = []
        links, owner, seen = {}, {}, set()

        def walk(n, path):
            if n in seen:
                return
            seen.add(n)
            for i, name, _ in self.entries(n):
                links[i] = links.get(i, 0) + 1
                if name in ('.', '..'):
                    continue
                if not self.iget(i).flags & IALLOC:
                    errs.append('%s/%s: entry for free inode %d' % (path, name, i))
                    continue
                if self.iget(i).isdir:
                    walk(i, path + '/' + name)
        links[ROOT] = links.get(ROOT, 0)
        walk(ROOT, '')
        nalloc = 0
        for n in range(1, self.ninodes + 1):
            ino = self.iget(n)
            if not ino.flags & IALLOC:
                continue
            nalloc += 1
            if links.get(n, 0) != ino.nlinks:
                errs.append('inode %d: %d links, %d names' % (n, ino.nlinks, links.get(n, 0)))
            for b in self.blocks_of(ino):
                if b < self.data or b >= self.nblocks:
                    errs.append('inode %d: block %d out of range' % (n, b))
                elif b in owner:
                    errs.append('block %d: inodes %d and %d' % (b, owner[b], n))
                else:
                    owner[b] = n
        for b in range(self.nblocks):
            want = b < self.data or b in owner
            if self.used(b) != want:
                errs.append('block %d: bitmap says %s' % (b, 'used' if self.used(b) else 'free'))
        free = sum(1 for b in range(self.data, self.nblocks) if not self.used(b))
        if free != self.nfree:
            errs.append('superblock: %d free blocks, counted %d' % (self.nfree, free))
        if self.ninodes - nalloc != self.nifree:
            errs.append('superblock: %d free inodes, counted %d'
                        % (self.nifree, self.ninodes - nalloc))
        return errs


def mkfs(dev, base=0, blocks=None, inodes=None, label='', when=None):
    """A new, empty ZXFS of BLOCKS blocks from sector BASE."""
    if blocks is None:
        blocks = dev.nsectors - base
    if inodes is None:
        inodes = max(16, min(1024, (blocks // 10 + 7) // 8 * 8))
    if blocks > dev.nsectors - base or blocks < 16:
        raise FSError('bad size: %d blocks' % blocks)
    nbmap = (blocks + BS * 8 - 1) // (BS * 8)
    nitab = (inodes + 7) // 8
    bmap, itab = 1, 1 + nbmap
    data = itab + nitab
    if data + 2 > blocks:
        raise FSError('no room for data')
    for b in range(data):
        dev.write(base + b, bytes(BS))
    sb = bytearray(BS)
    sb[:6] = MAGIC + bytes([VERSION, FSTYPE])
    struct.pack_into('<HHHBBHHHHHL', sb, 6, blocks, inodes, bmap, nbmap, 0, itab,
                     nitab, data, blocks - data, inodes,
                     unix_to_zx(when if when is not None else time.time()))
    sb[28:44] = label.encode('latin-1')[:16].ljust(16, b'\0')
    dev.write(base, sb)
    fs = FS(dev, base)
    for b in range(data):
        fs.mark(b, True)
    root = fs.mknode(0, '', IFDIR | MODE_DIR | 1)      # the root: o+w too
    assert root == ROOT
    return FS(dev, base)


def main():
    ap = argparse.ArgumentParser(description='ZXFS on FDD3000 disk images')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('mkfs')
    p.add_argument('disk')
    p.add_argument('--base', type=int, default=0)
    p.add_argument('--blocks', type=int)
    p.add_argument('--inodes', type=int)
    p.add_argument('--label', default='')
    p.add_argument('--new', metavar='CYLSxSIDES', help='make a blank disk first, e.g. 40x1')
    for name in ('put', 'get'):
        p = sub.add_parser(name)
        p.add_argument('disk')
        p.add_argument('a')
        p.add_argument('b', nargs='?')
    for name in ('ls', 'mkdir', 'check'):
        p = sub.add_parser(name)
        p.add_argument('disk')
        p.add_argument('path', nargs='?', default='/')
    a = ap.parse_args()
    if a.cmd == 'mkfs' and a.new:
        c, s = (int(x) for x in a.new.lower().split('x'))
        disk = dsk.Disk(cyls=c, sides=s)
    else:
        disk = dsk.Disk.load(a.disk)
    dev = Device(disk)
    try:
        if a.cmd == 'mkfs':
            fs = mkfs(dev, a.base, a.blocks, a.inodes, a.label)
            print('%d blocks, %d inodes, data from block %d' % (fs.nblocks, fs.ninodes, fs.data))
        else:
            fs = FS(dev)
            if a.cmd == 'put':
                with open(a.a, 'rb') as f:
                    fs.put(a.b, f.read())
            elif a.cmd == 'get':
                data = fs.read_file(fs.lookup(a.a))
                if a.b:
                    with open(a.b, 'wb') as f:
                        f.write(data)
                else:
                    sys.stdout.buffer.write(data)
                return 0
            elif a.cmd == 'mkdir':
                fs.mkdir(a.path)
            elif a.cmd == 'ls':
                for i, name, _ in fs.entries(fs.lookup(a.path)):
                    ino = fs.iget(i)
                    print('%5d %s %2d %6d %s' % (i, 'd' if ino.isdir else '-',
                                                 ino.nlinks, ino.size, name))
                return 0
            elif a.cmd == 'check':
                errs = fs.check()
                for e in errs:
                    print(e)
                print('%s: %d blocks (%d free), %d inodes (%d free): %s'
                      % (a.disk, fs.nblocks, fs.nfree, fs.ninodes, fs.nifree,
                         'clean' if not errs else '%d problems' % len(errs)))
                return 1 if errs else 0
    except FSError as e:
        print('zxdfs: %s' % e, file=sys.stderr)
        return 1
    disk.save(a.disk)
    return 0


if __name__ == '__main__':
    sys.exit(main())
