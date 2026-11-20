"""The TC3256's system disk (build.py tc3256).

A TOS system disk (tomato -new tos40: TOS on tracks 0-3, which the
FDD3000 boots and loads its overlays from) with one file, BOOT, in TOS's
CODE form (type 3, length, start 8000h, the bytes):

    the first 16 KB   0000h-3FFFh: the machine layer (tc3256/src/hal.asm)
                      and the resident programs placed with it - what the
                      boot menu's "4. Disk start" loads and enters at 0001h
    then              LOWK up to the root file system's end: the low
                      kernel, the kernel, the boot code, the root file
                      system - what tcboot (hal.asm) reads into place

build/tc3256/ZX-UX-TC3256.dsk.
"""
import os
import struct
import subprocess
import sys

TOMATO = os.environ.get('TOMATO')
CODE = 3                        # TOS's CODE file (the shadow ROM's LOADP)
BOOT_AT = 0x8000                # where Disk start loads BOOT


def code_file(data, start=BOOT_AT):
    return bytes([CODE]) + struct.pack('<HH', len(data), start) + data


def build(b):
    import dsk
    import tosfs
    tomato = TOMATO or os.path.join(os.path.dirname(b.ROOT), 'tomato', 'tomato')
    placed = b.place('tc3256')
    top, src, sym, fsimg, free = b.kernel('tc3256', placed=placed)
    low = b.read(os.path.join(src, 'low.bin'))
    size = sym['TX0_LIM']
    if len(low) > size:
        raise b.BuildError('the low image is %d bytes, more than %d' % (len(low), size))
    low += bytes(size - len(low))
    base = sym['LOWK']
    parts = [('lowk', sym['LOWK'], b.read(os.path.join(src, 'lowk.bin'))),
             ('unix', sym['KBASE'], b.read(os.path.join(src, 'unix.bin'))),
             ('fs', sym['ITAB'], fsimg)]
    end = max(a + len(d) for _, a, d in parts)
    rest = bytearray(end - base)
    for name, a, d in parts:
        rest[a - base:a - base + len(d)] = d
    boot = low + bytes(rest)
    out = os.path.join(b.BUILD, 'tc3256')
    path = os.path.join(out, 'ZX-UX-TC3256.dsk')
    if os.path.exists(path):
        os.remove(path)
    r = subprocess.run([tomato, '-new', 'tos40', '-saveas', path], capture_output=True, text=True)
    if r.returncode or not os.path.exists(path):
        raise b.BuildError('tomato: %s%s' % (r.stdout, r.stderr))
    d = dsk.Disk.load(path)
    tosfs.TOS(d).put('BOOT', code_file(boot))
    d.save(path)
    print('tc3256:   layer 0000-%04X  text to %04X  kernel %d bytes  BOOT %d bytes'
          % (sym['halend'] - 1, sym['tx0end'] - 1, sym['kend'] - sym['KBASE'], len(boot)))
    for n in sorted(placed):
        print('tc3256:   text TX%d %04X-%04X  %4d bytes left  %s'
              % (n, sym['TX%d' % n], sym['TX%d_LIM' % n] - 1,
                 sym['TX%d_LIM' % n] - sym['tx%dend' % n], ' '.join(placed[n])))
    print('tc3256:   root fs %04X, %d bytes free in the arena' % (sym['ITAB'], free))
    print('tc3256:   %s' % os.path.relpath(path, b.ROOT))
    return path
