"""The ZX-UX root file system image: the i-node table (ITAB) and the arena.

The kernel's boot code finds both in RAM, already in place (unix.asm boot:
"the loader put the i-node table and the arena in place").  This module
builds that image.  The layout was read back from the shipped ZX-UX.tzx
(its "fs" block, B64Ah) and is reproduced byte for byte by build.py's
Spectrum gate, so the same code makes the FDD3000 root file system.

  i-node (32 bytes, const.inc):  0 flags.w  2 nlinks.b  3 uid.b  4 size.w
      6 dskp.w (payload address in the arena)  8..21 0  22 ctime.l
      26 mtime.l  30 packed length.w (I_RSVD: IFPACK files only, else 0)
  directory entry (10 bytes):    i-number.w, name (8 bytes, 0-padded)
  arena block:                   size.w (even, header included), kind.b,
      0.b, payload.  aalloc: size = (payload + 5) & ~1.  The last block is
      free (kind 0) and runs up to WINDOW.
"""
import struct

ROOTINO = 41
INOSZ = 32
TXINO = 128

IALLOC, IFDIR = 0x8000, 0x4000
IFPACK = 0x0400                  # zx.asm: the payload is zxpack'ed
IROWN, IWOWN, IROTH, IWOTH = 0o10, 0o4, 0o2, 0o1
K_FREE, K_FILE = 0, 1

# The shipped image stamps every node 4495 days after the epoch (00:00 on
# 23 April 1982), both times.  The clock itself starts at 09:00 that day.
STAMP = 4495 * 86400


class Node:
    def __init__(self, ino, flags, payload=b'', size=None, nlinks=1):
        self.ino, self.flags, self.payload = ino, flags, bytes(payload)
        self.size = len(self.payload) if size is None else size
        self.nlinks = nlinks
        self.entries = None              # directories: [(ino, name)]


def dirent(ino, name):
    raw = name.encode('ascii')
    if not 0 < len(raw) <= 8:
        raise ValueError('bad file name %r' % name)
    return struct.pack('<H', ino) + raw.ljust(8, b'\0')


class FileSystem:
    """Directories and files numbered as they are added (from ROOTINO up),
    laid out in the arena in i-number order, as the shipped image is."""

    def __init__(self, ninode=24):
        self.ninode = ninode
        self.nodes = {}
        self.next = ROOTINO
        root = self._new(IALLOC | IFDIR | IROWN | IWOWN | IROTH)
        root.entries = [(ROOTINO, '.'), (ROOTINO, '..')]
        root.nlinks = 2

    def _new(self, flags, payload=b'', size=None):
        if self.next >= ROOTINO + self.ninode:
            raise ValueError('out of i-nodes')
        n = Node(self.next, flags, payload, size)
        self.nodes[n.ino] = n
        self.next += 1
        return n

    def mkdir(self, parent, name, mode=IROWN | IWOWN | IROTH):
        p = self.nodes[parent]
        d = self._new(IALLOC | IFDIR | mode)
        d.entries = [(d.ino, '.'), (parent, '..')]
        d.nlinks = 2
        p.entries.append((d.ino, name))
        p.nlinks += 1
        return d.ino

    def link(self, parent, name, ino):
        """A name for an existing node: a special file (1..NSPEC) or a
        resident program (TXINO + its PTAB index) has no i-node here."""
        self.nodes[parent].entries.append((ino, name))
        if ino in self.nodes:
            self.nodes[ino].nlinks += 1

    def create(self, parent, name, data, mode=IROWN | IWOWN | IROTH,
               packed=None):
        """packed = (raw zxpack payload, unpacked size) for a file stored
        packed, as the shipped /usr/doc files are."""
        if packed:
            payload, size = packed
            n = self._new(IALLOC | IFPACK | mode, payload, size)
        else:
            n = self._new(IALLOC | mode, data)
        n.nlinks = 0
        self.link(parent, name, n.ino)
        return n.ino

    def image(self, itab, window):
        """Bytes from ITAB to the end of the free block's header, and the
        number of free arena bytes (the free block's size)."""
        ar0 = itab + self.ninode * INOSZ
        itab_b = bytearray(self.ninode * INOSZ)
        arena = bytearray()
        for ino in sorted(self.nodes):
            n = self.nodes[ino]
            if n.entries is not None:
                n.payload = b''.join(dirent(i, s) for i, s in n.entries)
                n.size = len(n.payload)
            blk = (len(n.payload) + 5) & ~1
            addr = ar0 + len(arena)
            arena += struct.pack('<HBB', blk, K_FILE, 0) + n.payload
            arena += bytes(blk - 4 - len(n.payload))
            plen = len(n.payload) if n.flags & IFPACK else 0
            ino_b = struct.pack('<HBBHH14xLLH', n.flags, n.nlinks, 0, n.size,
                                addr + 4, STAMP, STAMP, plen)
            o = (ino - ROOTINO) * INOSZ
            itab_b[o:o + INOSZ] = ino_b
        free_at = ar0 + len(arena)
        free = window - free_at
        if free < 0 or free & 1:
            raise ValueError('arena overflow: %d' % free)
        arena += struct.pack('<HBB', free, K_FREE, 0)
        return bytes(itab_b + arena), free


def read_image(img, itab, ninode=24):
    """Decode an image back into {path: (ino, flags, size, payload)} - for
    tests and for lifting the packed documents out of the shipped tape."""
    out = {}

    def o_(ino):
        return (ino - ROOTINO) * INOSZ

    def node(ino):
        o = o_(ino)
        flags, nl, _uid, size, dskp = struct.unpack_from('<HBBHH', img, o)
        return flags, nl, size, dskp

    def walk(ino, path):
        flags, nl, size, dskp = node(ino)
        off = dskp - itab
        if flags & IFPACK:
            plen = struct.unpack_from('<H', img, o_(ino) + 30)[0]
            payload = img[off:off + plen]
        else:
            payload = img[off:off + size]
        out[path or '/'] = (ino, flags, size, payload, nl)
        if flags & IFDIR:
            for j in range(0, size, 10):
                i = struct.unpack_from('<H', payload, j)[0]
                name = payload[j + 2:j + 10].rstrip(b'\0').decode()
                if name in ('.', '..'):
                    continue
                if ROOTINO <= i < ROOTINO + ninode:
                    walk(i, path + '/' + name)
                else:
                    out[path + '/' + name] = (i, None, None, None, None)
    walk(ROOTINO, '')
    return out
