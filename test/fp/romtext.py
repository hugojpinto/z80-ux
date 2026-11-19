"""The 48K ROM's PRINT-FP (2DE3h) as an oracle for the number's text.

The ROM runs on the SDK's Z80 (zxcore); the character output (PRINT-A-2, 15F2h, which RST 10h reaches) is caught and its
character recorded.  Used by test/fp/strtest.py to check the clean-room
formatter's output (the ROM is an oracle for the format, not a source of
code).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
import zxcore  # noqa: E402
from rcc import romfp  # noqa: E402

PRINT_FP, RST10, TRAP = 0x2DE3, 0x15F2, 0x8100   # 15F2h: PRINT-A-2, where RST 10h and the digits go


class RomText:
    def __init__(self):
        self.zx = zxcore.Spectrum()
        romfp.setup_memory(self.zx.mem)

    def text(self, five):
        zx, m = self.zx, self.zx.mem
        cs = romfp.CSTK
        m[cs:cs + 5] = bytes(five)
        for a, v in ((romfp.STKBOT, cs), (romfp.STKEND, cs + 5)):
            m[a], m[a + 1] = v & 255, v >> 8
        sp = 0xA000 - 2
        m[sp], m[sp + 1] = TRAP & 255, TRAP >> 8
        m[romfp.ERR_SP], m[romfp.ERR_SP + 1] = sp & 255, sp >> 8
        m[romfp.ERR_NR] = 0xFF
        zx.set(iy=0x5C3A, sp=sp, iff1=False, iff2=False, pc=PRINT_FP)
        out = []
        while True:
            if not zx.run((RST10, TRAP), zx.t + 50_000_000):
                raise RuntimeError('PRINT-FP did not return')
            if zx.pc == TRAP:
                break
            out.append(chr(zx.a))
            s = zx.sp
            zx.set(pc=m[s] | m[s + 1] << 8, sp=s + 2)
        return ''.join(out)
