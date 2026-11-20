#!/usr/bin/env python3
"""Phase 0 (platform/tc3256.md §7): what a TC3256 started from disk gives.

    python3 tc3256/test/test_probe.py

probe.asm as BOOT - 16 KB, and more after it - on a new TOS system disk,
started with the boot menu's key 4 in Fuse (tc3256run.py).  Checked:
  - Disk start runs it at 0001h, in the all-RAM map (port EEh: FIRMWARE),
    interrupts off; only the file's first 16 KB are loaded (the shadow
    ROM's LOADP is asked for 4000h bytes: what follows is not at C000h);
  - the FDD3000 link in user mode, through tc3256/src/link.asm: TOS's
    version; a sector read (RXSEC: track 0 sector 0, track 4 sector 0)
    equal to the disk image's; a sector written (TXSEC) and read back;
  - the gateway (CALL 0008h with IY = 0, from 4000h up): system mode -
    the shadow ROM at 0000h - and back, the RAM at 0000h as it was.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tc3256run  # noqa: E402

RES = 0xC100
EXTRA = b'XTRA' * 64        # BOOT's bytes past 16 KB: must not be loaded
WTRACK, WSEC = 39, 15       # probe.asm's
FIRMWARE = 0x80             # port EEh, bit 7 (the MMU guide, §11.2)
SHADOW_DI = 0xF3            # the shadow ROM's first byte: DI (0000h)


def main():
    boot = tc3256run.assemble(os.path.join(HERE, 'probe.asm'), 'probe.bin')
    with __import__('tempfile').TemporaryDirectory() as t:
        disk = tc3256run.disk_with(boot + EXTRA, t)
    got, _ = tc3256run.run(boot + EXTRA, [(RES, 0x400)])
    r = got[RES, 0x400]
    fails = []

    def check(ok, why):
        if not ok:
            fails.append(why)
    check(r[0:2] == b'P0', 'the probe did not end: %r' % r[0:2])
    check(r[6] & FIRMWARE, 'EEh %02X: not the all-RAM map' % r[6])
    check(not r[4] & 4, 'interrupts on at the start')
    check(r[8:12] != EXTRA[:4], 'LOADP loaded past 16 KB')
    check(r[0x10] == 0 and r[0x11] == 0 and r[0x20] == 0x80, 'GETVER: %s' % r[0x10:0x2D].hex())
    check(r[0x30:0x33] == bytes(3), 'RXSEC 0/0: %s' % r[0x30:0x33].hex())
    check(r[0x33:0x36] == bytes(3), 'RXSEC 4/0: %s' % r[0x33:0x36].hex())
    check(r[0x100:0x200] == bytes(disk.sector(0, 0, 0)), 'RXSEC 0/0: not the image\'s sector')
    check(r[0x200:0x300] == bytes(disk.sector(4, 0, 0)), 'RXSEC 4/0: not the image\'s sector')
    check(r[0x36:0x38] == bytes(2) and r[0x38:0x3B] == bytes(3), 'TXSEC: %s' % r[0x36:0x3B].hex())
    check(r[0x300:0x400] == bytes(range(256)), 'TXSEC: not read back as written')
    check(r[0x40] & FIRMWARE and r[0x41] == SHADOW_DI and r[0x42] == boot[1] and r[0x43] == 0xAA,
          'the gateway: %s' % r[0x40:0x44].hex())
    print('entry: SP %04X, EEh %02X; TOS: %s' % (r[2] | r[3] << 8, r[6], r[0x20:0x2D].hex()))
    for f in fails:
        print('FAIL:', f)
    print('test_probe: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
