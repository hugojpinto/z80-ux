#!/usr/bin/env python3
"""Boot and drive ZX-UX on an emulated FDD3000 (no Fuse needed).

The machine is the FDD3000-MSDOS project's model (its Z80, WD177x, drive
latch and boot-ROM paging: cpm80ds/machine.py) with its model of the
terminal's end of the 2Fh link (fdd86.Link, the CBIOS A1.1 protocol byte
by byte).  Nothing of ZX-UX is trapped: the FDD3000 boot ROM loads our
boot sector, which loads the system, which talks to the terminal.

    python3 fdd3000/test/fddrun.py [DISK] --keys 'root\\rls /bin\\r'

FDD3000_MSDOS   the FDD3000-MSDOS checkout (default: ../FDD3000-MSDOS
                next to this repository)
FDD_BOOT_ROM    the FDD3000 boot ROM (default: timex-romdis's fdd3000b.rom)
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LOADZX = os.path.dirname(ROOT)
MSDOS = os.environ.get('FDD3000_MSDOS', os.path.join(LOADZX, 'FDD3000-MSDOS'))
os.environ.setdefault('FDD_BOOT_ROM', os.path.join(
    LOADZX, 'timex-romdis', 'ROMS', 'FDD3000', 'fdd3000b.rom'))
sys.path.insert(0, os.path.join(MSDOS, 'project', 'cpm80ds'))
sys.path.insert(0, os.path.join(MSDOS, 'project', 'MSDOS', 'poc'))
import machine  # noqa: E402
import fdd  # noqa: E402
from fdd86 import Link  # noqa: E402
from cpmemu import _tstates  # noqa: E402

DEFAULT_DISK = os.path.join(ROOT, 'build', 'fdd3000', 'ZX-UX-FDD3000.dsk')
HZ = 4_000_000


class FDC(machine.FDC):
    """The model's WD177x, with Read Address (C0h): the next ID field of
    the track under the head (C, H, R, N and a CRC), which the ZX-UX
    driver's geometry probe uses."""

    RATES_MS = (6, 12, 20, 30)          # WD1770 step rates

    def command(self, c):
        self.t_end = None
        if c & 0x80 == 0 and self.drive() is None:
            # A type I command on a drive that is not there (the ZX-UX
            # clock steps drive D): it ends one step time later, as on the
            # WD1770 - here in T-states, not the model's instruction count.
            super().command(c)
            self.t_end = self.m.tstates + self.RATES_MS[c & 3] * 4000
            self.busy_until = self.m.icount + (1 << 40)
            self.done_status = self.status & ~1
            return
        if c & 0xF0 != 0xC0:
            return super().command(c)
        self.intrq = False
        d = self.drive()
        side = self.m.side()
        if d is None or d.disk is None or d.cyl >= d.disk.cyls \
                or side >= d.disk.sides or side >= d.heads or self.m.latch & 0x80:
            self.status = 0x01
            self.finish(0x10, self.T_FIND * 4)
            return
        self.status = 0x01
        self.buf = bytes([d.cyl, side, 0, 1, 0, 0]) + bytes(250)
        self.pos = 0
        self.rda = 6
        self.writing = None
        self.done_status = -1
        self.busy_until = self.m.icount + self.T_FIND

    def tick(self):
        if getattr(self, 't_end', None) is not None:
            if self.m.tstates >= self.t_end:
                self.t_end = None
                self.busy_until = None
                self.status = self.done_status
                self.intrq = True
            return
        super().tick()

    def read_data(self):
        if getattr(self, 'rda', 0) and self.buf is not None and self.drq:
            v = self.buf[self.pos]
            self.pos += 1
            self.last_io = self.m.icount
            if self.pos == self.rda:
                self.rda = 0
                self.drq = False
                self.buf = None
                self.finish(0, 20)
            return v
        return super().read_data()


class FDDUX(machine.Machine):
    """The FDD3000 with a terminal on its link."""

    def __init__(self, disks):
        drives = [machine.Drive(cyls=d.cyls, heads=d.sides, disk=d) for d in disks]
        super().__init__(drives, max_instr=1 << 62)
        self.fdc = FDC(self)
        self.link = Link()
        self.tstates = 0
        self.stopped = None

    def port_in(self, port):
        if port & 0xE0 == 0x20:
            return (0x80 if self.fdc.drq else 0) | self.link.read()
        return super().port_in(port)

    def port_out(self, port, v):
        if port & 0xFF == 0x2F:
            self.link.write(v)
        else:
            super().port_out(port, v)

    def run_for(self, seconds, quiet=None):
        """Run for so many emulated seconds; with quiet, stop early once
        nothing was sent to the terminal for that long and no key waits."""
        c, m, fdc, link = self.cpu, self.m, self.fdc, self.link
        ops = c.ops
        end = self.tstates + int(seconds * HZ)
        last_out, nout = self.tstates, len(link.out)
        while self.tstates < end:
            for _ in range(2000):
                self.icount += 1
                if fdc.busy_until is not None or fdc.drq:
                    fdc.tick()
                if fdc.intrq and c.iff1:            # IM 1
                    if m[c.pc] == 0x76:             # out of a HALT
                        c.pc = (c.pc + 1) & 0xFFFF
                    c.iff1 = c.iff2 = 0
                    c.sp = (c.sp - 2) & 0xFFFF
                    m[c.sp] = c.pc & 0xFF
                    m[(c.sp + 1) & 0xFFFF] = c.pc >> 8
                    c.pc = 0x38
                    self.tstates += 13
                    continue
                pc = c.pc
                op = m[pc]
                if op == 0x76:
                    if not c.iff1:
                        self.stopped = pc
                        return
                    self.tstates += 4               # HALT: wait for INTRQ
                    continue
                c.pc = (pc + 1) & 0xFFFF
                if op == 0xED and m[(pc + 1) & 0xFFFF] >= 0xB0 and m[(pc + 1) & 0xFFFF] & 2 == 0:
                    n0 = (c.r[0] << 8) | c.r[1]
                    ops[op]()
                    k = ((n0 - ((c.r[0] << 8) | c.r[1])) & 0xFFFF) or 0x10000
                    self.tstates += 21 * k - 5
                else:
                    sp0 = c.sp
                    ops[op]()
                    self.tstates += _tstates(m, pc, op, c.pc, c, sp0)
            if len(link.out) != nout:
                nout, last_out = len(link.out), self.tstates
            elif quiet and not link.keys and self.tstates - last_out > quiet * HZ:
                return

    def type(self, s, settle=3.0):
        for ch in s:
            self.link.keys.append(ord(ch))
            self.run_for(0.3, quiet=0.1)
        self.run_for(30, quiet=settle)

    def screen(self):
        return self.link.out.decode('latin-1')


def vt52(raw):
    """A rough rendering of what the terminal shows: 24 x 80, VT52 codes."""
    rows = [[' '] * 80 for _ in range(24)]
    r = c = 0
    i = 0
    while i < len(raw):
        ch = raw[i]
        i += 1
        if ch == '\x1b' and i < len(raw):
            k = raw[i]
            i += 1
            if k == 'Y' and i + 1 < len(raw):
                r, c = min(23, ord(raw[i]) - 32), min(79, ord(raw[i + 1]) - 32)
                i += 2
            elif k == 'H':
                r = c = 0
            elif k == 'J':
                for rr in range(r, 24):
                    for cc in range(c if rr == r else 0, 80):
                        rows[rr][cc] = ' '
            elif k == 'K':
                for cc in range(c, 80):
                    rows[r][cc] = ' '
            elif k == 'A':
                r = max(0, r - 1)
            elif k == 'B':
                r = min(23, r + 1)
            continue
        if ch == '\r':
            c = 0
        elif ch == '\n':
            if r == 23:
                rows = rows[1:] + [[' '] * 80]
            else:
                r += 1
        elif ch == '\b':
            c = max(0, c - 1)
        elif ch >= ' ':
            if c < 80:
                rows[r][c] = ch
            c = min(c + 1, 79)
    return '\n'.join(''.join(x).rstrip() for x in rows).rstrip('\n')


def boot(disk_path=DEFAULT_DISK, seconds=20):
    m = FDDUX([fdd.Disk.load(disk_path)])
    m.boot()
    m.run_for(seconds, quiet=2.0)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('disk', nargs='?', default=DEFAULT_DISK)
    ap.add_argument('--keys', default='', help='typed after boot; \\r = Enter')
    ap.add_argument('--raw', action='store_true', help='print the raw link output')
    a = ap.parse_args()
    m = boot(a.disk)
    if a.keys:
        m.type(a.keys.encode().decode('unicode_escape'))
    print(repr(m.screen()) if a.raw else vt52(m.screen()))
    print('[%.2f s at 4 MHz, PC=%04X%s]' % (m.tstates / HZ, m.cpu.pc,
          ', stopped (HALT, DI)' if m.stopped is not None else ''), file=sys.stderr)


if __name__ == '__main__':
    main()
