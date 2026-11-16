"""Extended CPC DSK images in the FDD3000's own format.

TOS and TMX CP/M disks are 40 cylinders, one side, 16 sectors of 256 bytes
a track, sector IDs 0-15 in physical order (MFM).  Fuse's Timex FDD and
the FDD3000-MSDOS project's model both load this format.
"""
import struct

CYLS, SIDES, SPT, SECSZ = 40, 1, 16, 256


class Disk:
    def __init__(self, cyls=CYLS, sides=SIDES, spt=SPT, fill=0xE5):
        self.cyls, self.sides, self.spt = cyls, sides, spt
        self.data = bytearray([fill]) * (cyls * sides * spt * SECSZ)

    def offset(self, cyl, side, sec):
        return ((cyl * self.sides + side) * self.spt + sec) * SECSZ

    def sector(self, cyl, side, sec):
        o = self.offset(cyl, side, sec)
        return bytes(self.data[o:o + SECSZ])

    def put(self, cyl, side, sec, data):
        if len(data) > SECSZ:
            raise ValueError('sector overflow')
        o = self.offset(cyl, side, sec)
        self.data[o:o + SECSZ] = data.ljust(SECSZ, b'\0')

    def put_linear(self, first_cyl, data):
        """data from sector 0 of first_cyl onward, one side, ID order."""
        n = 0
        for k in range(0, len(data), SECSZ):
            cyl, sec = divmod(k // SECSZ, self.spt)
            self.put(first_cyl + cyl, 0, sec, data[k:k + SECSZ])
            n += 1
        return n

    def save(self, path):
        tsize = 0x100 + self.spt * SECSZ
        out = bytearray(b'EXTENDED CPC DSK File\r\nDisk-Info\r\n')
        out += b'zx-ux fdd3000'.ljust(14, b' ')
        out += bytes([self.cyls, self.sides, 0, 0])
        out += bytes([tsize >> 8] * (self.cyls * self.sides))
        out = out.ljust(0x100, b'\0')
        for c in range(self.cyls):
            for h in range(self.sides):
                t = bytearray(b'Track-Info\r\n'.ljust(16, b'\0'))
                t += bytes([c, h, 0, 0, 1, self.spt, 0x4E, 0xE5])
                for s in range(self.spt):
                    t += struct.pack('<BBBBBBH', c, h, s, 1, 0, 0, SECSZ)
                t = t.ljust(0x100, b'\0')
                for s in range(self.spt):
                    t += self.sector(c, h, s)
                out += t
        with open(path, 'wb') as f:
            f.write(out)

    @classmethod
    def load(cls, path):
        with open(path, 'rb') as f:
            raw = f.read()
        if not raw.startswith(b'EXTENDED CPC DSK'):
            raise ValueError('not an Extended CPC DSK image')
        cyls, sides = raw[0x30], raw[0x31]
        d = None
        p = 0x100
        for i in range(cyls * sides):
            tsize = raw[0x34 + i] << 8
            if not tsize:
                continue
            t = raw[p:p + tsize]
            c, h, n = t[0x10], t[0x11], t[0x15]
            if d is None:
                d = cls(cyls, sides, n)
            q = 0x100
            for s in range(n):
                sid = t[0x18 + 8 * s + 2]
                ln = struct.unpack_from('<H', t, 0x18 + 8 * s + 6)[0]
                if sid < d.spt:
                    d.put(c, h, sid, t[q:q + SECSZ])
                q += ln
            p += tsize
        return d
