"""The TC3256's system disk (build.py tc3256).

A TOS system disk (tomato -new tos40: TOS on tracks 0-3, which the
FDD3000 boots and loads its overlays from) with two files.  ZXFS, put
first so that it starts at a track (allocation unit 4: track 5) and
covers whole tracks: the system volume, a ZXFS written into those tracks
as plain sectors (tosdisk.asm's blkvol finds it; TOS's interleave is
inside them) - /mnt/a once mounted: the SDK's programs, the file system
modules, the float engine, etc/rc.  BOOT, in TOS's CODE form (type 3,
length, start 8000h, the bytes):

    the first 16 KB   0000h-3FFFh: the machine layer (tc3256/src/hal.asm)
                      and the resident programs placed with it - what the
                      boot menu's "4. Disk start" loads and enters at 0001h
    then              LOWK up to the root file system's end: the low
                      kernel, the kernel, the boot code, the root file
                      system - what tcboot (hal.asm) reads into place

build/tc3256/ZX-UX-TC3256.dsk.
"""
import json
import os
import struct
import subprocess
import sys

TOMATO = os.environ.get('TOMATO')
CODE = 3                        # TOS's CODE file (the shadow ROM's LOADP)
BOOT_AT = 0x8000                # where Disk start loads BOOT


def code_file(data, start=BOOT_AT):
    return bytes([CODE]) + struct.pack('<HH', len(data), start) + data


SPT = 16                        # a track's sectors
AUSEC = 4                       # an allocation unit's (TOS: 1 KB)
TOS_PARTS = 4                   # a TOS file's parts at most (an entry's part byte: 0-3)
SYSTEM_RC = b'echo /dev/fd0 on /mnt/a\n'
SYSTEM_README = b'''ZX-UX on the Timex TC3256

This file system is the system disk's ZXFS: a TOS file, ZXFS,
on the disk TOS boots from.  /etc/init mounts it on /mnt/a at
boot and runs its etc/rc.
'''


def build(b):
    import dsk
    import tosfs
    import zxdfs
    import fsmod
    import fddimage
    tomato = TOMATO or os.path.join(os.path.dirname(b.ROOT), 'tomato', 'tomato')
    placed = b.place('tc3256')
    # Twice: the kernel carries the checksum of its own ABI (fsmod.py), which
    # the modules on the system volume are built against.
    top, src, sym, fsimg, free = b.kernel('tc3256', placed=placed)
    vals, stamp = fsmod.abi(sym)
    top, src, sym, fsimg, free = b.kernel('tc3256', defines=['KABI=0%04Xh' % stamp],
                                          placed=placed)
    if fsmod.abi(sym) != (vals, stamp) or sym['kabi'] != stamp:
        raise b.BuildError('the kernel ABI moved between passes')
    fsmod.write_kabi(os.path.join(top, 'kabi.inc'), sym)
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
    boot = code_file(low + bytes(rest))

    out = os.path.join(b.BUILD, 'tc3256')
    path = os.path.join(out, 'ZX-UX-TC3256.dsk')
    if os.path.exists(path):
        os.remove(path)
    r = subprocess.run([tomato, '-new', 'tos40', '-saveas', path], capture_output=True, text=True)
    if r.returncode or not os.path.exists(path):
        raise b.BuildError('tomato: %s%s' % (r.stdout, r.stderr))
    d = dsk.Disk.load(path)
    tos = tosfs.TOS(d)
    first = min(a for a in range(AUSEC, tos.limit) if a not in tos.used_aus())
    if first % AUSEC:
        raise b.BuildError('the first free allocation unit (%d) is not at a track' % first)
    boot_aus = (len(boot) + 1023) // 1024
    most = TOS_PARTS * tosfs.PART // tosfs.AU   # a TOS file: 64 KB at most
    vol_aus = min(tos.limit - first - boot_aus, most) // AUSEC * AUSEC
    tos.put('ZXFS', bytes(vol_aus * 1024))
    aus = sorted(a for p in tos.files()[[i for i in tos.files()
                                          if tos.name(tos.ent(i)) == ('ZXFS', '')][0]]
                 for a in tos.ent(p)[16:32] if a)
    if aus != list(range(first, first + vol_aus)):
        raise b.BuildError('ZXFS is not one run of tracks: %s' % aus)
    tos.put('BOOT', boot)
    vbase = (sym['TD_DIRTRK'] + first // AUSEC) * SPT
    vblocks = vol_aus * AUSEC

    dev = zxdfs.Device(d)
    zfs = zxdfs.mkfs(dev, vbase, vblocks, label='ZX-UX TC3256', when=0x17268310)
    for name in ('README', 'zxpack.doc', 'more.doc'):
        data = SYSTEM_README if name == 'README' else b.read(os.path.join(b.SRC, name))
        zfs.put('/doc/' + name.split('.')[0], data)
    zfs.put('/etc/rc', SYSTEM_RC)
    zfs.mkdir('/etc/fs')
    for name, source in fddimage.FS_MODULES:
        zfs.put('/etc/fs/' + name,
                fsmod.build(b.SJASMPLUS, os.path.join(top, 'kabi.inc'),
                            os.path.join(b.ROOT, source), name, os.path.join(top, 'mod')))
    zfs.mkdir('/lib')
    zfs.put('/lib/fp', fsmod.build(b.SJASMPLUS, os.path.join(top, 'kabi.inc'),
                                   os.path.join(b.ROOT, 'drivers', 'fp', 'fp.asm'), 'fp',
                                   os.path.join(top, 'mod')))
    subprocess.run([sys.executable, os.path.join(b.ROOT, 'sdk', 'bin', 'py', 'libux', 'build.py')],
                   check=True, capture_output=True)
    uxdir = os.path.join(b.BUILD, 'ux')
    os.makedirs(uxdir, exist_ok=True)
    for name in fddimage.SYSTEM_PROGRAMS:
        zfs.put('/bin/' + name, fddimage.ux_program(b, name, uxdir))
    if zfs.check():
        raise b.BuildError('system volume: %s' % zfs.check())
    d.save(path)
    with open(os.path.join(out, 'kernel.json'), 'w') as f:
        json.dump({'format': 'zx-ux-tc3256/1', 'arena_free': free, 'kabi': stamp,
                   'volume': [vbase, vblocks],
                   'symbols': {k: sym[k] for k in sorted(sym)
                               if not k.startswith(('.', '_')) and '.' not in k}},
                  f, indent=1, sort_keys=True)
    print('tc3256:   layer 0000-%04X  text to %04X  kernel %d bytes  BOOT %d bytes'
          % (sym['halend'] - 1, sym['tx0end'] - 1, sym['kend'] - sym['KBASE'], len(boot) - 5))
    for n in sorted(placed):
        print('tc3256:   text TX%d %04X-%04X  %4d bytes left  %s'
              % (n, sym['TX%d' % n], sym['TX%d_LIM' % n] - 1,
                 sym['TX%d_LIM' % n] - sym['tx%dend' % n], ' '.join(placed[n])))
    print('tc3256:   root fs %04X, %d bytes free in the arena' % (sym['ITAB'], free))
    print('tc3256:   ZXFS on the system disk: sectors %d-%d (tracks %d-%d), %d blocks free'
          % (vbase, vbase + vblocks - 1, vbase // SPT, (vbase + vblocks) // SPT - 1, zfs.nfree))
    print('tc3256:   %s' % os.path.relpath(path, b.ROOT))
    return path
