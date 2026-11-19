#!/usr/bin/env python3
"""TOS disks on the host: the reference for drivers/tos/tfs.asm.

    tosfs.py mkfs  DISK [--label L] [--tos4]
    tosfs.py ls    DISK
    tosfs.py get   DISK NAME[.EXT] [HOSTFILE]     (D:NAME for directory id D)
    tosfs.py put   DISK HOSTFILE NAME[.EXT]
    tosfs.py mkdir DISK NAME
    tosfs.py check DISK

The format (tos40, and TOS4's with no system tracks): 16 sectors of 256
bytes a track; logical sector L of a track is the sector with ID SKEW[L]
(TOS's 7:1 interleave, for the directory and the data alike).  The directory is the track after TOS's 4
system tracks (track 0 on a TOS4 disk): 128 entries of 32 bytes.  Space
is in allocation units (AU) of 1K, 4 sectors, numbered from the
directory's track (AUs 0-3 are the directory); a 40-track disk has AUs up
to 144 (160 with no system tracks).

  entry  0 parent: directory id (0 root, 1-15), bit 7 = a directory (its
           own id in AU byte 0); E5h free; FFh entry 0 (the disk's name)
         1 name (8)   9 extension (3): space-padded; bit 7 of ext[0] read
           only, of ext[1] hidden
        12 part (a file has an entry for each 16K)
        13 bytes in the part's last sector (0: 256)
        14 records of 128 bytes, high, low (always even here)
        16 AUs (16; 0: none)
  A part's bytes: records * 128 if the tail is 0, else
  ((records + 1) / 2 - 1) * 256 + tail.

ZX-UX's names for TOS files (tfs.asm): "name.ext" in lower case if it is
8 characters or fewer, else the name's first 5, "~" and the entry number
in hex; ZX-UX writes an orphan (parent 7Fh) for an open file it has
unlinked - check reports them.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dsk  # noqa: E402

FREE, ORPHAN = 0xE5, 0x7F
# TOS's soft interleave: logical sector L of a track is sector ID SKEW[L]
# (7:1; the table is its own inverse)
SKEW = [0, 7, 14, 5, 12, 3, 10, 1, 8, 15, 6, 13, 4, 11, 2, 9]
AU = 1024
PART = 16 * AU


class TOSError(Exception):
    pass


def tbytes(e):
    tail, rec = e[13], e[14] << 8 | e[15]
    if tail == 0:
        return rec * 128
    return ((rec + 1) // 2 - 1) * 256 + tail


def tenc(n):
    """bytes in a part -> (tail, records)"""
    return n & 0xFF, ((n + 255) // 256) * 2


class TOS:
    def __init__(self, disk, base=None):
        self.disk = disk
        if base is None:
            for b in (64, 0):
                e = self._raw(b, 0)
                if e[0] == 0xFF and bytes(x & 0x7F for x in e[9:12]) == b'DIR':
                    base = b
                    break
            else:
                raise TOSError('no TOS directory')
        self.base = base
        self.limit = (disk.cyls * 16 - base) // 4

    def _raw(self, base, i):
        s = base + i // 8
        return bytearray(self.disk.sector(s // 16, 0, SKEW[s % 16])[(i % 8) * 32:(i % 8) * 32 + 32])

    def ent(self, i):
        return self._raw(self.base, i)

    def setent(self, i, e):
        s = self.base + i // 8
        sec = bytearray(self.disk.sector(s // 16, 0, SKEW[s % 16]))
        sec[(i % 8) * 32:(i % 8) * 32 + 32] = e
        self.disk.put(s // 16, 0, SKEW[s % 16], bytes(sec))

    def ausec(self, au, k):
        s = self.base + au * 4 + k
        return s // 16, SKEW[s % 16]

    def read_au(self, au):
        out = b''
        for k in range(4):
            t, r = self.ausec(au, k)
            out += self.disk.sector(t, 0, r)
        return out

    def write_au(self, au, data):
        data = data.ljust(AU, b'\0')
        for k in range(4):
            t, r = self.ausec(au, k)
            self.disk.put(t, 0, r, data[k * 256:k * 256 + 256])

    # ---- the table
    def entries(self):
        return [(i, self.ent(i)) for i in range(1, 128)]

    def files(self):
        """{entry of part 0: [entries of parts 0, 1, ...]} of named files
        and orphans."""
        out = {}
        es = self.entries()
        for i, e in es:
            if e[0] == FREE or (e[0] & 0x80) or e[12] != 0:
                continue
            key = bytes(e[0:9]) + bytes(x & 0x7F for x in e[9:12])
            parts = [i]
            for p in range(1, 4):
                nx = [j for j, f in es if f[0] != FREE and not (f[0] & 0x80) and f[12] == p
                      and bytes(f[0:9]) + bytes(x & 0x7F for x in f[9:12]) == key]
                if not nx:
                    break
                parts.append(nx[0])
            out[i] = parts
        return out

    def dirs(self):
        """{id: entry} of the directories."""
        return {e[16]: i for i, e in self.entries() if e[0] != FREE and e[0] & 0x80}

    @staticmethod
    def name(e):
        n = bytes(x & 0x7F for x in e[1:9]).rstrip(b' ').decode('latin-1')
        x = bytes(x & 0x7F for x in e[9:12]).rstrip(b' ').decode('latin-1')
        return n, x

    def zxname(self, i, e):
        """The name ZX-UX shows (tfs.asm tdisp)."""
        n, x = self.name(e)
        n = n.split(' ')[0].lower().replace('/', '_')
        x = x.split(' ')[0].lower().replace('/', '_')
        if e[0] & 0x80 or not x:
            return n
        if len(n) + 1 + len(x) <= 8:
            return n + '.' + x
        return n[:5] + '~' + '%02x' % i

    def lookup(self, path):
        """'name.ext' or 'D:name.ext' (TOS names) -> entry of part 0."""
        d = 0
        if ':' in path:
            d, path = path.split(':', 1)
            d = int(d)
        n, _, x = path.upper().partition('.')
        for i, e in self.entries():
            if e[0] != FREE and (e[0] & 0x7F) == d and e[12] == 0 and self.name(e) == (n, x):
                return i
        raise TOSError('%s: not found' % path)

    def read_file(self, i):
        out = b''
        for j in self.files()[i]:
            e = self.ent(j)
            n = tbytes(e)
            data = b''.join(self.read_au(a) for a in e[16:32] if a)
            out += data[:n]
            if n < PART:
                break
        return out

    def used_aus(self):
        used = {}
        for i, e in self.entries():
            if e[0] == FREE or e[0] & 0x80:
                continue
            for a in e[16:32]:
                if a:
                    used.setdefault(a, []).append(i)
        return used

    def free_entry(self):
        for i, e in self.entries():
            if e[0] == FREE:
                return i
        raise TOSError('directory full')

    def put(self, name, data, d=0):
        n, _, x = name.upper().partition('.')
        used = self.used_aus()
        free = [a for a in range(4, self.limit) if a not in used]
        if (len(data) + AU - 1) // AU > len(free):
            raise TOSError('disk full')
        for p in range((len(data) + PART - 1) // PART or 1):
            chunk = data[p * PART:(p + 1) * PART]
            e = bytearray(32)
            e[0] = d
            e[1:9] = n.encode().ljust(8)[:8]
            e[9:12] = x.encode().ljust(3)[:3]
            e[12] = p
            e[13], rec = tenc(len(chunk))
            e[14], e[15] = rec >> 8, rec & 0xFF
            for k in range((len(chunk) + AU - 1) // AU):
                a = free.pop(0)
                self.write_au(a, chunk[k * AU:(k + 1) * AU])
                e[16 + k] = a
            self.setent(self.free_entry(), e)

    def mkdir(self, name, d=0):
        ids = set(self.dirs())
        new = min(set(range(1, 16)) - ids)
        e = bytearray(32)
        e[0] = 0x80 | d
        e[1:9] = name.upper().encode().ljust(8)[:8]
        e[9:12] = b'DIR'
        e[16] = new
        self.setent(self.free_entry(), e)
        return new

    def check(self):
        """What is wrong with it: AUs out of range or used twice, parts out
        of order, sizes the AUs do not hold, entries in no directory."""
        errs = []
        for a, owners in sorted(self.used_aus().items()):
            if not 4 <= a < self.limit:
                errs.append('AU %d out of range (entries %s)' % (a, owners))
            if len(owners) > 1:
                errs.append('AU %d in entries %s' % (a, owners))
        dirs = self.dirs()
        seen = set()
        for i, parts in self.files().items():
            e0 = self.ent(i)
            if e0[0] == ORPHAN:
                errs.append('entry %d: an orphan (unlinked, never closed)' % i)
            elif e0[0] and e0[0] not in dirs:
                errs.append('entry %d: in no directory (%d)' % (i, e0[0]))
            for p, j in enumerate(parts):
                seen.add(j)
                e = self.ent(j)
                n = tbytes(e)
                nau = sum(1 for a in e[16:32] if a)
                if (n + AU - 1) // AU != nau:
                    errs.append('entry %d part %d: %d bytes in %d AUs' % (j, p, n, nau))
                if any(e[16 + k] == 0 for k in range(nau)):
                    errs.append('entry %d: a hole in its AUs' % j)
                if p < len(parts) - 1 and n != PART:
                    errs.append('entry %d part %d: not full, yet a part follows' % (j, p))
        for i, e in self.entries():
            if e[0] != FREE and not (e[0] & 0x80) and i not in seen:
                errs.append('entry %d: a part with no first part' % i)
            if e[0] != FREE and e[0] & 0x80 and (e[0] & 0x7F) and (e[0] & 0x7F) not in dirs:
                errs.append('directory entry %d: in no directory' % i)
        return errs


def mkfs(disk, label='ZXUX', tos4=False):
    base = 0 if tos4 else 64
    for t in range(base // 16, disk.cyls):
        for r in range(16):
            disk.put(t, 0, r, b'\xE5' * 256)
    e = bytearray(b'\xE5' * 32)
    e[0] = 0xFF
    e[1:12] = label.upper().encode().ljust(8)[:8] + b'DIR'
    e[12:32] = bytes(20)
    fs = TOS(disk, base)
    fs.setent(0, e)
    return fs


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('mkfs'); p.add_argument('disk'); p.add_argument('--label', default='ZXUX')
    p.add_argument('--tos4', action='store_true')
    p = sub.add_parser('ls'); p.add_argument('disk')
    p = sub.add_parser('get'); p.add_argument('disk'); p.add_argument('name'); p.add_argument('out', nargs='?')
    p = sub.add_parser('put'); p.add_argument('disk'); p.add_argument('host'); p.add_argument('name')
    p = sub.add_parser('mkdir'); p.add_argument('disk'); p.add_argument('name')
    p = sub.add_parser('check'); p.add_argument('disk')
    a = ap.parse_args()
    if a.cmd == 'mkfs':
        d = dsk.Disk(cyls=40, sides=1)
        mkfs(d, a.label, a.tos4)
        d.save(a.disk)
        return 0
    d = dsk.Disk.load(a.disk)
    fs = TOS(d)
    if a.cmd == 'ls':
        for i, parts in sorted(fs.files().items()):
            e = fs.ent(i)
            print('%3d  %d:%-12s %-8s %6d' % (i, e[0], '.'.join(x for x in fs.name(e) if x),
                                             fs.zxname(i, e), len(fs.read_file(i))))
        for did, i in sorted(fs.dirs().items()):
            print('%3d  dir %d in %d: %s' % (i, did, fs.ent(i)[0] & 0x7F, fs.name(fs.ent(i))[0]))
    elif a.cmd == 'get':
        data = fs.read_file(fs.lookup(a.name))
        if a.out:
            open(a.out, 'wb').write(data)
        else:
            sys.stdout.buffer.write(data)
    elif a.cmd in ('put', 'mkdir'):
        if a.cmd == 'put':
            fs.put(a.name, open(a.host, 'rb').read())
        else:
            fs.mkdir(a.name)
        d.save(a.disk)
    elif a.cmd == 'check':
        errs = fs.check()
        for e in errs:
            print(e)
        return 1 if errs else 0
    return 0


if __name__ == '__main__':
    sys.exit(main())
